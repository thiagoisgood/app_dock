//
//  app_dockTests.swift
//  app_dockTests
//
//  Created by thiago on 2026/4/30.
//

import Foundation
import Testing
@testable import app_dock

struct app_dockTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func searchFindsHeuristicCategoryWithoutAICache() async throws {
        let apps = [
            makeApp(
                name: "Xcode",
                bundleID: "com.apple.dt.Xcode",
                path: "/Applications/Xcode.app"
            )
        ]
        let search = AINaturalLanguageSearch(aiCategories: [:])

        let results = search.matchAppsWithHints(query: "开发工具", tags: [:], apps: apps)

        #expect(results.map(\.app.name).contains("Xcode"))
    }

    @Test func searchCanonicalizesLegacyMappingCategoryNames() async throws {
        let apps = [
            makeApp(
                name: "Xcode",
                bundleID: "com.apple.dt.Xcode",
                path: "/Applications/Xcode.app"
            )
        ]
        let search = AINaturalLanguageSearch(aiCategories: [:])

        let results = search.matchAppsWithHints(query: "编程", tags: [:], apps: apps)

        #expect(results.map(\.app.name).contains("Xcode"))
    }

    @Test func riskySearchFindsNonUnsignedRiskSignals() async throws {
        let apps = [
            makeApp(
                name: "Meeting Helper",
                bundleID: "com.example.meeting-helper",
                path: "/Applications/Meeting Helper.app",
                permissions: [.camera, .microphone],
                backgroundResident: true,
                trustLevel: .trusted
            )
        ]
        let search = AINaturalLanguageSearch(aiCategories: [:])

        let results = search.matchAppsWithHints(query: "风险应用", tags: [:], apps: apps)

        #expect(results.map(\.app.name).contains("Meeting Helper"))
    }

    @Test func chineseNameFindsEnglishDisplayedApp() async throws {
        let apps = [
            makeApp(
                name: "WeChat",
                bundleID: "com.tencent.xinWeChat",
                path: "/Applications/WeChat.app"
            )
        ]
        let search = AINaturalLanguageSearch(aiCategories: [:])

        let results = search.matchAppsWithHints(query: "微信", tags: [:], apps: apps)

        #expect(results.first?.app.name == "WeChat")
        #expect(results.first?.hints.contains(where: { $0.id == "aliasExact" || $0.id == "aliasBundleExact" }) == true)
    }

    @Test func chineseNameFindsAppByKnownBundleIDAlias() async throws {
        let apps = [
            makeApp(
                name: "Tencent Chat",
                bundleID: "com.tencent.xinWeChat",
                path: "/Applications/WeChat.app"
            )
        ]
        let search = AINaturalLanguageSearch(aiCategories: [:])

        let results = search.matchAppsWithHints(query: "微信", tags: [:], apps: apps)

        #expect(results.first?.app.name == "Tencent Chat")
        #expect(results.first?.hints.contains(where: { $0.id == "aliasBundleExact" }) == true)
    }

    @Test func uninstallPreviewIncludesAppBundleAndExistingResiduals() async throws {
        let home = URL(fileURLWithPath: "/tmp/appdock-home")
        let app = makeApp(
            name: "Sample",
            bundleID: "com.example.sample",
            path: "/Applications/Sample.app"
        )
        let cachePath = "\(home.path)/Library/Caches/com.example.sample"
        let preferencesPath = "\(home.path)/Library/Preferences/com.example.sample.plist"
        let fileManager = FakeUninstallFileManager(
            home: home,
            existingPaths: [app.path, cachePath, preferencesPath]
        )
        let service = UninstallService(policy: uninstallPolicy(enabled: true), fileManager: fileManager)

        let preview = service.preview(app: app)

        #expect(preview.unavailableReason == nil)
        #expect(preview.items.map(\.path).contains(app.path))
        #expect(preview.items.map(\.path).contains(cachePath))
        #expect(preview.items.map(\.path).contains(preferencesPath))
        #expect(preview.items.map(\.kind).contains(.appBundle))
    }

    @Test func uninstallCleanupMovesExistingItemsToTrash() async throws {
        let home = URL(fileURLWithPath: "/tmp/appdock-home")
        let app = makeApp(
            name: "Sample",
            bundleID: "com.example.sample",
            path: "/Applications/Sample.app"
        )
        let supportPath = "\(home.path)/Library/Application Support/Sample"
        let fileManager = FakeUninstallFileManager(
            home: home,
            existingPaths: [app.path, supportPath]
        )
        let service = UninstallService(policy: uninstallPolicy(enabled: true), fileManager: fileManager)

        let result = await service.uninstallAndClean(app: app)

        #expect(result.removedPaths == [app.path, supportPath])
        #expect(result.failedItems.isEmpty)
        #expect(fileManager.trashedPaths == [app.path, supportPath])
    }

    @Test func uninstallCleanupHonorsDisabledPolicy() async throws {
        let app = makeApp(
            name: "Sample",
            bundleID: "com.example.sample",
            path: "/Applications/Sample.app"
        )
        let fileManager = FakeUninstallFileManager(
            home: URL(fileURLWithPath: "/tmp/appdock-home"),
            existingPaths: [app.path]
        )
        let service = UninstallService(policy: uninstallPolicy(enabled: false), fileManager: fileManager)

        let result = await service.uninstallAndClean(app: app)

        #expect(result.removedItems.isEmpty)
        #expect(result.skippedMessage == "当前构建禁用卸载清理")
        #expect(fileManager.trashedPaths.isEmpty)
    }

    @Test func uninstallCleanupRequestsAdministratorPrivilegesForPermissionFailures() async throws {
        let home = URL(fileURLWithPath: "/tmp/appdock-home")
        let app = makeApp(
            name: "Sample",
            bundleID: "com.example.sample",
            path: "/Applications/Sample.app"
        )
        let containerPath = "\(home.path)/Library/Containers/com.example.sample"
        let fileManager = FakeUninstallFileManager(
            home: home,
            existingPaths: [app.path, containerPath],
            permissionDeniedPaths: [app.path, containerPath]
        )
        let shell = FakeShellExecutor(
            output: """
            APPDOCK_TRASHED\t\(app.path)
            APPDOCK_TRASHED\t\(containerPath)
            """
        )
        let service = UninstallService(
            policy: uninstallPolicy(enabled: true),
            fileManager: fileManager,
            shell: shell
        )

        let result = await service.uninstallAndClean(app: app)

        #expect(result.removedPaths == [app.path, containerPath])
        #expect(result.failedItems.isEmpty)
        #expect(shell.calls.count == 1)
        #expect(shell.calls.first?.launchPath == "/usr/bin/osascript")
        #expect(shell.calls.first?.arguments.joined(separator: " ").contains("with administrator privileges") == true)
    }

    @Test func directBuildEnablesUninstallCleanup() async throws {
        let policy = CapabilityPolicy.current

        #expect(policy.flavor == .direct)
        #expect(policy.isEnabled(.uninstallDelete))
    }

    private func uninstallPolicy(enabled: Bool) -> CapabilityPolicy {
        CapabilityPolicy(
            flavor: enabled ? .direct : .mas,
            featureAvailability: [.uninstallDelete: enabled]
        )
    }

    private func makeApp(
        name: String,
        bundleID: String?,
        path: String,
        permissions: Set<PermissionKind> = [],
        backgroundResident: Bool = false,
        trustLevel: SignatureTrustLevel = .trusted
    ) -> AppRecord {
        AppRecord(
            id: UUID(),
            bundleID: bundleID,
            name: name,
            version: "1.0",
            path: path,
            sizeBytes: 10_000_000,
            source: .thirdParty,
            signature: SignatureInfo(
                teamID: trustLevel == .trusted ? "TESTTEAMID" : nil,
                commonName: "Test Developer",
                signingAuthority: [],
                trustLevel: trustLevel
            ),
            permissions: PermissionAudit(
                requested: permissions,
                backgroundResident: backgroundResident,
                evidence: PermissionKind.allCases.map {
                    PermissionEvidence(
                        kind: $0,
                        declaredInInfoPlist: permissions.contains($0),
                        tccState: .notDetermined,
                        checkedAt: Date(),
                        note: nil
                    )
                }
            ),
            metrics: RuntimeMetrics(cpuPercent: 0, memoryMB: 0)
        )
    }

}

private final class FakeUninstallFileManager: UninstallFileManaging {
    let homeDirectoryForCurrentUser: URL
    private let existingPaths: Set<String>
    private let permissionDeniedPaths: Set<String>
    private(set) var trashedPaths: [String] = []

    init(home: URL, existingPaths: Set<String>, permissionDeniedPaths: Set<String> = []) {
        self.homeDirectoryForCurrentUser = home
        self.existingPaths = existingPaths
        self.permissionDeniedPaths = permissionDeniedPaths
    }

    func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }

    func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        if permissionDeniedPaths.contains(url.path) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "permission denied"]
            )
        }
        trashedPaths.append(url.path)
    }
}

private final class FakeShellExecutor: ShellExecuting {
    struct Call {
        let launchPath: String
        let arguments: [String]
    }

    let output: String
    private(set) var calls: [Call] = []

    init(output: String) {
        self.output = output
    }

    func run(_ launchPath: String, _ arguments: [String]) async -> String {
        calls.append(Call(launchPath: launchPath, arguments: arguments))
        return output
    }
}
