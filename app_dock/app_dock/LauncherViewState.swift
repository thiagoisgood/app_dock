import Foundation
import SwiftUI

enum LauncherFilter: Hashable {
    case aiRecommended
    case recent
    case autoOrganized
    case category(String)
    case all

    var title: String {
        switch self {
        case .aiRecommended: return "AI 推荐"
        case .recent: return "最近使用"
        case .autoOrganized: return "自动整理新应用"
        case .category(let category): return category
        case .all: return "全部应用"
        }
    }
}

enum LauncherTint: Hashable {
    case teal
    case purple
    case green
    case blue
    case orange
    case pink

    var color: Color {
        switch self {
        case .teal: return .teal
        case .purple: return .purple
        case .green: return .green
        case .blue: return .blue
        case .orange: return .orange
        case .pink: return .pink
        }
    }
}

struct LauncherStatItem: Hashable, Identifiable {
    var id: String { title }
    let systemImage: String
    let title: String
    let value: String
    let tint: LauncherTint
    var detail: String? = nil
}

struct LauncherSidebarRow: Hashable, Identifiable {
    var id: LauncherFilter { filter }
    let filter: LauncherFilter
    let count: Int
    let systemImage: String
}

struct LauncherRiskBadgeState: Hashable {
    let score: Int
    let level: AuditRiskLevel?
}

struct LauncherAppItem: Hashable, Identifiable {
    var id: AppRecord.ID { app.id }
    let app: AppRecord
    let category: String
    let tags: [String]
    let hints: [SearchMatchHint]
    let isRecommended: Bool
    let isSelected: Bool
    let riskBadge: LauncherRiskBadgeState
    let confidencePercent: Int?
    let statusLabel: String
    let statusTint: LauncherTint

    var displayHint: String {
        hints.first?.displayText ?? category
    }

    var confidenceLabel: String {
        if let p = confidencePercent { return "\(p)%" }
        if isRecommended { return "AI" }
        if riskBadge.level != nil { return "提示" }
        return ""
    }

    /// 右上角角标文案（仅对有意义的状态展示）
    var cornerBadgeText: String {
        switch statusLabel {
        case "AI 推荐", "自然语言": return "AI"
        case "安全提示": return "提示"
        default: return ""
        }
    }
}

struct LauncherAIStatusState: Hashable {
    let title: String
    let subtitle: String
    let recommendedName: String
    let recommendedConfidenceLabel: String
    let organizedValue: String
    let workflowValue: String
    let naturalLanguageValue: String
    let taggedCount: Int
}

struct LauncherViewState: Hashable {
    let filter: LauncherFilter
    let title: String
    let subtitle: String
    let hasActiveSearch: Bool
    let items: [LauncherAppItem]
    let smartRows: [LauncherSidebarRow]
    let categoryRows: [LauncherSidebarRow]
    let summaryItems: [LauncherStatItem]
    let aiStatus: LauncherAIStatusState
    let suggestedGroups: [String]
    let selectedItem: LauncherAppItem?
    let totalAppCount: Int
    let organizedCount: Int
    let attentionCount: Int

    static let empty = LauncherViewState(
        filter: .aiRecommended,
        title: "AI 推荐",
        subtitle: "按 AI 分类、标签和使用信号推荐",
        hasActiveSearch: false,
        items: [],
        smartRows: [],
        categoryRows: [],
        summaryItems: [
            LauncherStatItem(systemImage: "sparkles", title: "推荐打开", value: "等待扫描", tint: .teal),
            LauncherStatItem(systemImage: "wand.and.stars", title: "AI 分类", value: "0 个", tint: .purple),
            LauncherStatItem(systemImage: "shield.lefthalf.filled", title: "轻量提示", value: "0 个", tint: .green)
        ],
        aiStatus: LauncherAIStatusState(
            title: "智能整理完成",
            subtitle: "0 个应用 · 0 个带 AI 标签",
            recommendedName: "等待扫描",
            recommendedConfidenceLabel: "—",
            organizedValue: "0 新",
            workflowValue: "—",
            naturalLanguageValue: "AI",
            taggedCount: 0
        ),
        suggestedGroups: [],
        selectedItem: nil,
        totalAppCount: 0,
        organizedCount: 0,
        attentionCount: 0
    )

    static func build(
        apps: [AppRecord],
        displayedApps: [AppRecord],
        filter: LauncherFilter,
        hasActiveSearch: Bool,
        selectedAppID: AppRecord.ID?,
        aiCategories: [String: String],
        aiConfidences: [String: Double],
        appTags: [String: [String]],
        searchHints: [AppRecord.ID: [SearchMatchHint]],
        recentAppNames: [String],
        isAIProcessing: Bool,
        workflowPeriod: String,
        suggestedGroups: [String],
        resolveCategory: (AppRecord) -> String,
        riskLevel: (AppRecord) -> AuditRiskLevel?,
        riskScore: (AppRecord) -> Int,
        hasUpdateSuggestion: (AppRecord) -> Bool
    ) -> LauncherViewState {
        let categoryCounts = Dictionary(grouping: apps, by: resolveCategory)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let appKeys = Set(apps.flatMap { app -> [String] in
            var keys = [app.name]
            if let bundleID = app.bundleID { keys.append(bundleID) }
            return keys
        })
        let organizedCount = aiCategories.keys.filter { appKeys.contains($0) }.count
        let attentionCount = apps.filter {
            riskLevel($0) == .high || $0.signature.trustLevel == .unsignedHighRisk
        }.count

        func recommendationScore(for app: AppRecord) -> Int {
            var score = 0
            if aiCategories[app.name] != nil { score += 40 }
            if let bundleID = app.bundleID, aiCategories[bundleID] != nil { score += 40 }
            score += min(20, (appTags[app.name] ?? []).count * 6)
            if hasUpdateSuggestion(app) { score += 5 }
            if riskLevel(app) == .high { score -= 15 }
            return score
        }

        let scoreByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, recommendationScore(for: $0)) })

        func normalizedRecommendationPercent(_ score: Int) -> Int {
            let clamped = min(max(score, 0), 60)
            return 50 + Int((Double(clamped) / 60.0) * 49.0)
        }

        func confidencePercent(for app: AppRecord, recommended: Bool, score: Int) -> Int? {
            if let bid = app.bundleID, let c = aiConfidences[bid] {
                return Int((c * 100).rounded())
            }
            if let c = aiConfidences[app.name] {
                return Int((c * 100).rounded())
            }
            if recommended { return normalizedRecommendationPercent(score) }
            return nil
        }

        func status(for app: AppRecord, recommended: Bool, hasHints: Bool, isRecent: Bool, riskHigh: Bool) -> (String, LauncherTint) {
            if hasHints { return ("自然语言", .blue) }
            if recommended { return ("AI 推荐", .teal) }
            if isRecent { return ("最近常用", .purple) }
            if riskHigh { return ("安全提示", .orange) }
            if app.source == .system { return ("系统应用", .green) }
            return ("", .teal)
        }

        let aiRecommendedApps = apps.sorted { lhs, rhs in
            let lhsScore = scoreByID[lhs.id] ?? 0
            let rhsScore = scoreByID[rhs.id] ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let visibleApps: [AppRecord]
        if hasActiveSearch {
            visibleApps = displayedApps
        } else {
            switch filter {
            case .aiRecommended:
                visibleApps = aiRecommendedApps
            case .recent:
                let recentApps = recentAppNames.compactMap { recentName in
                    apps.first { $0.name == recentName }
                }
                visibleApps = recentApps.isEmpty ? aiRecommendedApps : recentApps
            case .autoOrganized:
                visibleApps = apps.filter { app in
                    if let bundleID = app.bundleID, aiCategories[bundleID] != nil { return true }
                    return aiCategories[app.name] != nil
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .category(let category):
                visibleApps = apps.filter { resolveCategory($0) == category }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .all:
                visibleApps = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }

        let recentSet = Set(recentAppNames)

        let items = visibleApps.map { app in
            let tags = appTags[app.name] ?? []
            let recommended = aiCategories[app.name] != nil
                || (app.bundleID.flatMap { aiCategories[$0] } != nil)
                || !tags.isEmpty
            let hasHints = !(searchHints[app.id] ?? []).isEmpty
            let isRecent = recentSet.contains(app.name)
            let riskHigh = riskLevel(app) == .high
            let score = scoreByID[app.id] ?? 0
            let (statusLabel, statusTint) = status(
                for: app,
                recommended: recommended,
                hasHints: hasHints,
                isRecent: isRecent,
                riskHigh: riskHigh
            )

            return LauncherAppItem(
                app: app,
                category: resolveCategory(app),
                tags: tags,
                hints: searchHints[app.id] ?? [],
                isRecommended: recommended,
                isSelected: selectedAppID == app.id,
                riskBadge: LauncherRiskBadgeState(score: riskScore(app), level: riskLevel(app)),
                confidencePercent: confidencePercent(for: app, recommended: recommended, score: score),
                statusLabel: statusLabel,
                statusTint: statusTint
            )
        }

        let recommendedName = items.first?.app.name ?? apps.first?.name ?? "等待扫描"
        let recommendedConfidence = items.first?.confidencePercent.map { "\($0)%" } ?? "AI"
        let taggedCount = appTags.values.filter { !$0.isEmpty }.count
        let smartRows = [
            LauncherSidebarRow(filter: .aiRecommended, count: min(apps.count, 12), systemImage: "sparkles"),
            LauncherSidebarRow(filter: .recent, count: min(max(recentAppNames.count, apps.isEmpty ? 0 : 8), apps.count), systemImage: "clock"),
            LauncherSidebarRow(filter: .autoOrganized, count: organizedCount, systemImage: "wand.and.stars")
        ]
        let categoryRows = categoryCounts.prefix(6).map { row in
            LauncherSidebarRow(filter: .category(row.name), count: row.count, systemImage: categoryIcon(for: row.name))
        } + [
            LauncherSidebarRow(filter: .all, count: apps.count, systemImage: "square.grid.3x3")
        ]

        return LauncherViewState(
            filter: filter,
            title: hasActiveSearch ? "搜索结果" : filter.title,
            subtitle: subtitle(for: filter, hasActiveSearch: hasActiveSearch),
            hasActiveSearch: hasActiveSearch,
            items: items,
            smartRows: smartRows,
            categoryRows: categoryRows,
            summaryItems: [
                LauncherStatItem(systemImage: "sparkles", title: "推荐打开", value: recommendedName, tint: .teal, detail: "结合\(workflowPeriod)使用习惯与分类置信度推荐"),
                LauncherStatItem(systemImage: "wand.and.stars", title: "AI 分类", value: "\(organizedCount) 个", tint: .purple, detail: "新安装应用已加入对应分类分组"),
                LauncherStatItem(systemImage: "shield.lefthalf.filled", title: "轻量提示", value: "\(attentionCount) 个", tint: .green, detail: "仅在详情中展示，不影响启动器主流程")
            ],
            aiStatus: LauncherAIStatusState(
                title: isAIProcessing ? "智能整理中" : "智能整理完成",
                subtitle: "\(apps.count) 个应用 · \(taggedCount) 个带 AI 标签",
                recommendedName: recommendedName,
                recommendedConfidenceLabel: recommendedConfidence,
                organizedValue: "\(organizedCount) 新",
                workflowValue: workflowPeriod,
                naturalLanguageValue: hasActiveSearch ? "命中" : "AI",
                taggedCount: taggedCount
            ),
            suggestedGroups: suggestedGroups,
            selectedItem: items.first(where: \.isSelected) ?? items.first,
            totalAppCount: apps.count,
            organizedCount: organizedCount,
            attentionCount: attentionCount
        )
    }

    private static func subtitle(for filter: LauncherFilter, hasActiveSearch: Bool) -> String {
        if hasActiveSearch {
            return "按名称、AI 标签、类别和使用反馈排序"
        }
        switch filter {
        case .aiRecommended:
            return "按 AI 分类、标签和使用信号推荐"
        case .recent:
            return "最近打开过的应用"
        case .autoOrganized:
            return "已被 AI 分类或打标签的应用"
        case .category:
            return "同类应用集中启动"
        case .all:
            return "按名称浏览所有已安装应用"
        }
    }

    private static func categoryIcon(for category: String) -> String {
        switch category {
        case "开发工具": return "hammer"
        case "设计创作": return "paintpalette"
        case "沟通协作": return "bubble.left.and.bubble.right"
        case "办公效率": return "doc.text"
        case "网络浏览": return "safari"
        case "系统工具": return "gearshape.2"
        case "安全隐私": return "lock.shield"
        case "影音娱乐": return "play.rectangle"
        default: return "app"
        }
    }
}
