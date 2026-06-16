import Foundation

struct UninstallPreview: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let items: [UninstallCleanupItem]
    let unavailableReason: String?

    var candidates: [String] {
        if let unavailableReason {
            return ["unavailable: \(unavailableReason)"]
        }
        return items.map(\.path)
    }
}

enum UninstallCleanupKind: String, Hashable {
    case appBundle = "应用本体"
    case applicationSupport = "支持文件"
    case caches = "缓存"
    case preferences = "偏好设置"
    case logs = "日志"
    case container = "沙盒容器"
    case savedState = "窗口状态"
    case httpStorage = "网络缓存"
    case webKit = "WebKit 数据"
}

struct UninstallCleanupItem: Identifiable, Hashable {
    var id: String { path }
    let kind: UninstallCleanupKind
    let path: String
}

struct UninstallCleanupFailure: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let reason: String
}

struct UninstallCleanupResult: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let removedItems: [UninstallCleanupItem]
    let failedItems: [UninstallCleanupFailure]
    let skippedMessage: String?

    var removedPaths: [String] {
        removedItems.map(\.path)
    }

    var succeeded: Bool {
        skippedMessage == nil && !removedItems.isEmpty && failedItems.isEmpty
    }

    var summary: String {
        if let skippedMessage {
            return skippedMessage
        }

        let removed = removedItems.count
        let failed = failedItems.count
        if failed == 0 {
            return "已将 \(removed) 个项目移入废纸篓。"
        }
        return "已移入废纸篓 \(removed) 个项目，\(failed) 个项目失败。"
    }
}

struct UpdateSuggestion: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let status: String
    let sourceHint: String
}

struct UninstallService {
    private let policy: CapabilityPolicy
    private let fileManager: UninstallFileManaging
    private let shell: any ShellExecuting

    init(
        policy: CapabilityPolicy = .current,
        fileManager: UninstallFileManaging = FileManager.default,
        shell: any ShellExecuting = ShellExecutor()
    ) {
        self.policy = policy
        self.fileManager = fileManager
        self.shell = shell
    }

    func preview(app: AppRecord) -> UninstallPreview {
        guard policy.isEnabled(.uninstallDelete) else {
            return UninstallPreview(
                appName: app.name,
                items: [],
                unavailableReason: "当前构建禁用卸载清理"
            )
        }

        let existing = candidateItems(for: app).filter { fileManager.fileExists(atPath: $0.path) }
        return UninstallPreview(appName: app.name, items: existing, unavailableReason: nil)
    }

    func uninstallAndClean(app: AppRecord) async -> UninstallCleanupResult {
        let preview = preview(app: app)
        if let unavailableReason = preview.unavailableReason {
            return UninstallCleanupResult(
                appName: app.name,
                removedItems: [],
                failedItems: [],
                skippedMessage: unavailableReason
            )
        }

        guard !preview.items.isEmpty else {
            return UninstallCleanupResult(
                appName: app.name,
                removedItems: [],
                failedItems: [],
                skippedMessage: "未发现可清理项目。"
            )
        }

        var removed: [UninstallCleanupItem] = []
        var failed: [UninstallCleanupFailure] = []
        for item in preview.items {
            do {
                var trashedURL: NSURL?
                try fileManager.trashItem(
                    at: URL(fileURLWithPath: item.path),
                    resultingItemURL: &trashedURL
                )
                removed.append(item)
            } catch {
                failed.append(UninstallCleanupFailure(path: item.path, reason: error.localizedDescription))
            }
        }

        if !failed.isEmpty {
            let elevatedResult = await moveToUserTrashWithAdministratorPrivileges(
                failed.compactMap { failure in
                    preview.items.first { $0.path == failure.path }
                }
            )
            removed.append(contentsOf: elevatedResult.removedItems)
            failed = failed.filter { failure in
                !elevatedResult.removedItems.contains { $0.path == failure.path }
            }
            for elevatedFailure in elevatedResult.failedItems {
                if let index = failed.firstIndex(where: { $0.path == elevatedFailure.path }) {
                    failed[index] = elevatedFailure
                } else {
                    failed.append(elevatedFailure)
                }
            }
        }

        return UninstallCleanupResult(
            appName: app.name,
            removedItems: removed,
            failedItems: failed,
            skippedMessage: nil
        )
    }

    private func moveToUserTrashWithAdministratorPrivileges(_ items: [UninstallCleanupItem]) async -> UninstallCleanupResult {
        guard !items.isEmpty else {
            return UninstallCleanupResult(appName: "", removedItems: [], failedItems: [], skippedMessage: nil)
        }

        let script = elevatedTrashShellScript(for: items)
        let appleScript = "do shell script \(appleScriptStringLiteral(script)) with administrator privileges"
        let output = await shell.run("/usr/bin/osascript", ["-e", appleScript])
        let parsed = parseElevatedTrashOutput(output, items: items)

        return UninstallCleanupResult(
            appName: "",
            removedItems: parsed.removed,
            failedItems: parsed.failed,
            skippedMessage: nil
        )
    }

    private func elevatedTrashShellScript(for items: [UninstallCleanupItem]) -> String {
        let trashPath = "\(fileManager.homeDirectoryForCurrentUser.path)/.Trash"
        var commands = [
            "trash_dir=\(shellQuoted(trashPath))",
            "/bin/mkdir -p \"$trash_dir\""
        ]

        for item in items {
            commands.append("""
            src=\(shellQuoted(item.path)); if [ -e "$src" ]; then name=$(/usr/bin/basename "$src"); dest="$trash_dir/$name"; if [ -e "$dest" ]; then stamp=$(/bin/date +%Y%m%d%H%M%S); n=0; while [ -e "$trash_dir/$name $stamp-$n" ]; do n=$((n + 1)); done; dest="$trash_dir/$name $stamp-$n"; fi; if /bin/mv "$src" "$dest"; then /usr/bin/printf 'APPDOCK_TRASHED\\t%s\\n' "$src"; else /usr/bin/printf 'APPDOCK_FAILED\\t%s\\t%s\\n' "$src" "move failed"; fi; else /usr/bin/printf 'APPDOCK_FAILED\\t%s\\t%s\\n' "$src" "not found"; fi
            """)
        }

        return commands.joined(separator: "; ")
    }

    private func parseElevatedTrashOutput(
        _ output: String,
        items: [UninstallCleanupItem]
    ) -> (removed: [UninstallCleanupItem], failed: [UninstallCleanupFailure]) {
        var removed: [UninstallCleanupItem] = []
        var failuresByPath: [String: String] = [:]
        let itemsByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "APPDOCK_TRASHED":
                if let item = itemsByPath[parts[1]] {
                    removed.append(item)
                }
            case "APPDOCK_FAILED":
                failuresByPath[parts[1]] = parts.count >= 3 ? parts[2] : "管理员权限移动失败"
            default:
                continue
            }
        }

        let removedPaths = Set(removed.map(\.path))
        let fallbackReason = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "管理员授权已取消或失败"
            : output.trimmingCharacters(in: .whitespacesAndNewlines)
        let failed = items
            .filter { !removedPaths.contains($0.path) }
            .map { item in
                UninstallCleanupFailure(
                    path: item.path,
                    reason: failuresByPath[item.path] ?? fallbackReason
                )
            }

        return (removed, failed)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func candidateItems(for app: AppRecord) -> [UninstallCleanupItem] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let bundleKey = app.bundleID ?? app.name

        let targets: [UninstallCleanupItem] = [
            UninstallCleanupItem(kind: .appBundle, path: app.path),
            UninstallCleanupItem(kind: .applicationSupport, path: "\(home)/Library/Application Support/\(app.name)"),
            UninstallCleanupItem(kind: .caches, path: "\(home)/Library/Caches/\(bundleKey)"),
            UninstallCleanupItem(kind: .caches, path: "\(home)/Library/Caches/\(app.name)"),
            UninstallCleanupItem(kind: .preferences, path: "\(home)/Library/Preferences/\(bundleKey).plist"),
            UninstallCleanupItem(kind: .logs, path: "\(home)/Library/Logs/\(app.name)"),
            UninstallCleanupItem(kind: .container, path: "\(home)/Library/Containers/\(bundleKey)"),
            UninstallCleanupItem(kind: .savedState, path: "\(home)/Library/Saved Application State/\(bundleKey).savedState"),
            UninstallCleanupItem(kind: .httpStorage, path: "\(home)/Library/HTTPStorages/\(bundleKey)"),
            UninstallCleanupItem(kind: .webKit, path: "\(home)/Library/WebKit/\(bundleKey)")
        ]

        var seen = Set<String>()
        return targets.filter { item in
            guard item.kind != .appBundle || URL(fileURLWithPath: item.path).pathExtension == "app" else {
                return false
            }
            return seen.insert(item.path).inserted
        }
    }
}

protocol UninstallFileManaging {
    var homeDirectoryForCurrentUser: URL { get }
    func fileExists(atPath path: String) -> Bool
    func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws
}

extension FileManager: UninstallFileManaging {}

struct UpdateAdvisorService {
    private let shell = ShellExecutor()
    private let policy = CapabilityPolicy.current

    func suggest(for apps: [AppRecord]) async -> [UpdateSuggestion] {
        guard policy.isEnabled(.updateProbe) else {
            return [UpdateSuggestion(appName: "系统策略", status: "不可用", sourceHint: "当前构建禁用更新探测")]
        }
        let thirdParty = apps.filter { $0.source == .thirdParty }
        let casksOutput = await shell.run("/bin/zsh", ["-lc", "brew list --cask 2>/dev/null || true"])
        let casks = Set(casksOutput.split(separator: "\n").map { String($0).lowercased() })

        return thirdParty.prefix(30).map { app in
            let token = app.name.lowercased().replacingOccurrences(of: " ", with: "")
            if casks.contains(token) {
                return UpdateSuggestion(appName: app.name, status: "可更新", sourceHint: "Homebrew Cask")
            }
            return UpdateSuggestion(appName: app.name, status: "需手动检查", sourceHint: "官网")
        }
    }
}
