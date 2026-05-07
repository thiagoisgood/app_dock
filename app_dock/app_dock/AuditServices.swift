import Foundation

struct AppScanner {
    func discoverApplications() async -> [URL] {
        let searchPaths: [String] = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
        ]

        let fm = FileManager.default
        var foundApps: [URL] = []

        for path in searchPaths {
            guard let contents = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let appURL = URL(fileURLWithPath: path + "/" + item)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    foundApps.append(appURL)
                }
            }
        }

        var seen = Set<String>()
        var uniqueApps: [URL] = []
        for app in foundApps {
            if !seen.contains(app.path) {
                seen.insert(app.path)
                uniqueApps.append(app)
            }
        }

        return uniqueApps.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }
}

struct SourceAuditService {
    func source(for appURL: URL) -> AppSource {
        let path = appURL.path
        // macOS system apps live under /System/Applications
        if path.hasPrefix("/System/Applications") || path.hasPrefix("/System/Library") {
            return .system
        }
        let receiptPath = appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
        if FileManager.default.fileExists(atPath: receiptPath) {
            return .appStore
        }
        return .thirdParty
    }
}

struct SignatureAuditService {
    private let shell = ShellExecutor()
    private let policy = CapabilityPolicy.current

    func inspect(appURL: URL) async -> SignatureInfo {
        guard policy.isEnabled(.signatureDeepAudit) else {
            return SignatureInfo(
                teamID: nil,
                commonName: nil,
                signingAuthority: [],
                trustLevel: .signedUnknown
            )
        }
        let output = await shell.run("/usr/bin/codesign", ["-dv", "--verbose=4", appURL.path])
        let isSigned = !output.isEmpty && !output.localizedCaseInsensitiveContains("code object is not signed")
        let team = output.capture(group: "TeamIdentifier=(.+)")
        let commonName = output.capture(group: "Authority=(.+)")
        let authorities = output.captures(group: "Authority=(.+)")
        let trust: SignatureTrustLevel = isSigned
            ? (team != nil ? .trusted : .signedUnknown)
            : .unsignedHighRisk

        return SignatureInfo(
            teamID: team,
            commonName: commonName,
            signingAuthority: authorities,
            trustLevel: trust
        )
    }
}

struct PermissionAuditService {
    func inspect(appURL: URL, tccStates: [PermissionKind: PermissionGrantState]) -> PermissionAudit {
        let infoPlistPath = appURL.appendingPathComponent("Contents/Info.plist")
        let plist = NSDictionary(contentsOf: infoPlistPath) as? [String: Any] ?? [:]

        var permissions = Set<PermissionKind>()
        var evidence: [PermissionEvidence] = []

        let cameraDeclared = plist["NSCameraUsageDescription"] != nil
        let micDeclared = plist["NSMicrophoneUsageDescription"] != nil
        let locationDeclared = plist["NSLocationWhenInUseUsageDescription"] != nil || plist["NSLocationAlwaysAndWhenInUseUsageDescription"] != nil
        let accessibilityDeclared = plist["NSAppleEventsUsageDescription"] != nil
        let screenDeclared = plist["NSScreenCaptureDescription"] != nil

        if cameraDeclared { permissions.insert(.camera) }
        if micDeclared { permissions.insert(.microphone) }
        if locationDeclared { permissions.insert(.location) }
        if accessibilityDeclared { permissions.insert(.accessibility) }
        if screenDeclared { permissions.insert(.screenRecording) }

        for kind in PermissionKind.allCases {
            let declared = permissions.contains(kind)
            let tcc = tccStates[kind] ?? .unavailable
            evidence.append(
                PermissionEvidence(
                    kind: kind,
                    declaredInInfoPlist: declared,
                    tccState: tcc,
                    checkedAt: Date(),
                    note: declared ? "来自 Info.plist 权限声明" : nil
                )
            )
        }

        let backgroundResident = (plist["LSUIElement"] as? Bool) == true || (plist["NSSupportsAutomaticGraphicsSwitching"] != nil)
        return PermissionAudit(requested: permissions, backgroundResident: backgroundResident, evidence: evidence)
    }
}

struct TCCPermissionReader {
    private let shell = ShellExecutor()
    private let policy: CapabilityPolicy

    init(policy: CapabilityPolicy) {
        self.policy = policy
    }

    func states(bundleID: String?) async -> [PermissionKind: PermissionGrantState] {
        guard policy.isEnabled(.tccRead) else {
            return Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .unavailable) })
        }
        guard let bundleID, !bundleID.isEmpty else {
            return Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .notDetermined) })
        }

        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let serviceMap: [PermissionKind: String] = [
            .camera: "kTCCServiceCamera",
            .microphone: "kTCCServiceMicrophone",
            .location: "kTCCServiceLocation",
            .accessibility: "kTCCServiceAccessibility",
            .screenRecording: "kTCCServiceScreenCapture",
            .fullDiskAccess: "kTCCServiceSystemPolicyAllFiles"
        ]

        var result: [PermissionKind: PermissionGrantState] = [:]
        for (kind, service) in serviceMap {
            let sql = "SELECT auth_value FROM access WHERE client='\(bundleID)' AND service='\(service)' ORDER BY last_modified DESC LIMIT 1;"
            let cmd = "sqlite3 \"\(dbPath)\" \"\(sql)\" 2>/dev/null"
            let output = await shell.run("/bin/zsh", ["-lc", cmd]).trimmingCharacters(in: .whitespacesAndNewlines)
            result[kind] = mapAuthValue(output)
        }
        return result
    }

    private func mapAuthValue(_ value: String) -> PermissionGrantState {
        switch value {
        case "0": return .denied
        case "2": return .authorized
        case "3": return .restricted
        case "1": return .notDetermined
        case "": return .notDetermined
        default: return .unavailable
        }
    }
}

struct PermissionHeuristicsEngine {
    func evaluate(app: AppRecord) -> [RiskSignal] {
        var signals: [RiskSignal] = []
        let lower = app.name.lowercased()
        let sensitive = Set([PermissionKind.camera, .microphone, .screenRecording, .fullDiskAccess, .accessibility])
        let requestedSensitive = app.permissions.requested.intersection(sensitive)

        if app.signature.trustLevel == .unsignedHighRisk {
            signals.append(.init(code: "SIGNATURE_UNSIGNED", level: .high, reason: "应用未签名"))
        }
        if app.signature.trustLevel == .signedUnknown {
            signals.append(.init(code: "SIGNATURE_UNKNOWN", level: .medium, reason: "签名主体未知"))
        }
        if !requestedSensitive.isEmpty && app.permissions.backgroundResident {
            signals.append(.init(code: "BG_WITH_SENSITIVE", level: .high, reason: "后台驻留且申请高敏权限"))
        }
        if app.permissions.requested.contains(.location) && (lower.contains("calculator") || lower.contains("calc")) {
            signals.append(.init(code: "MISMATCH_LOCATION", level: .medium, reason: "计算器类应用请求定位"))
        }
        if app.permissions.requested.contains(.camera) && lower.contains("terminal") {
            signals.append(.init(code: "MISMATCH_CAMERA", level: .medium, reason: "终端类应用请求摄像头"))
        }
        if app.permissions.requested.contains(.microphone) && lower.contains("archive") {
            signals.append(.init(code: "MISMATCH_MIC", level: .medium, reason: "压缩类应用请求麦克风"))
        }
        let deniedSensitive = app.permissions.evidence.filter { sensitive.contains($0.kind) && $0.tccState == .denied }
        if deniedSensitive.count >= 2 {
            signals.append(.init(code: "MULTI_DENIED_SENSITIVE", level: .low, reason: "多个高敏权限被系统拒绝，行为需持续关注"))
        }
        if app.metrics.cpuPercent > 45 && app.permissions.backgroundResident {
            signals.append(.init(code: "HIGH_CPU_BG", level: .medium, reason: "后台常驻且 CPU 占用异常"))
        }
        if app.metrics.memoryMB > 1024 && app.source == .thirdParty {
            signals.append(.init(code: "HIGH_MEM_THIRDPARTY", level: .low, reason: "第三方应用内存占用偏高"))
        }
        if app.permissions.requested.contains(.screenRecording) && app.source == .thirdParty {
            signals.append(.init(code: "SCREEN_CAPTURE_TP", level: .medium, reason: "第三方应用请求屏幕录制"))
        }
        if app.permissions.requested.contains(.accessibility) && app.source == .thirdParty {
            signals.append(.init(code: "ACCESSIBILITY_TP", level: .medium, reason: "第三方应用请求辅助功能控制"))
        }
        return signals
    }
}

struct RuntimeMetricsCollector {
    private let shell = ShellExecutor()

    func collect(for appName: String) async -> RuntimeMetrics {
        let escaped = appName.replacingOccurrences(of: "\"", with: "")
        let output = await shell.run("/bin/zsh", ["-lc", "ps -axo %cpu,rss,comm | rg -i \"\(escaped)\" | head -n 1"])
        let values = output.split(separator: " ").filter { !$0.isEmpty }
        if values.count >= 2, let cpu = Double(values[0]), let rssKB = Double(values[1]) {
            return RuntimeMetrics(cpuPercent: cpu, memoryMB: rssKB / 1024.0)
        }
        return RuntimeMetrics(cpuPercent: 0, memoryMB: 0)
    }
}

struct AuditPipeline {
    private let scanner = AppScanner()
    private let sourceAudit = SourceAuditService()
    private let signatureAudit = SignatureAuditService()
    private let permissionAudit = PermissionAuditService()
    private let metricsCollector = RuntimeMetricsCollector()
    private let policy = CapabilityPolicy.current

    func run() async -> ([AppRecord], [CapabilityStatus]) {
        let urls = await scanner.discoverApplications()
        let tccReader = TCCPermissionReader(policy: policy)
        var records: [AppRecord] = []
        records.reserveCapacity(urls.count)

        for appURL in urls {
            let bundle = Bundle(url: appURL)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? appURL.deletingPathExtension().lastPathComponent
            let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
            let bundleID = bundle?.bundleIdentifier
            let source = sourceAudit.source(for: appURL)
            let signature = await signatureAudit.inspect(appURL: appURL)
            let tccStates = await tccReader.states(bundleID: bundleID)
            let permissions = permissionAudit.inspect(appURL: appURL, tccStates: tccStates)
            let metrics = await metricsCollector.collect(for: name)
            let size = appURL.directorySize()

            records.append(
                AppRecord(
                    id: UUID(),
                    bundleID: bundleID,
                    name: name,
                    version: version,
                    path: appURL.path,
                    sizeBytes: size,
                    source: source,
                    signature: signature,
                    permissions: permissions,
                    metrics: metrics
                )
            )
        }
        let statuses = CapabilityFeature.allCases.map { policy.status(for: $0) }
        return (records, statuses)
    }
}

extension String {
    func capture(group pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = self as NSString
        guard let match = regex.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func captures(group pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension URL {
    func directorySize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: self,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
