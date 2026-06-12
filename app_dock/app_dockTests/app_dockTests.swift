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
