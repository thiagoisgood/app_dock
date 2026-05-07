import Foundation
import SwiftUI
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var apps: [AppRecord] = []
    @Published var searchText: String = ""
    @Published var groupingMode: ListGroupingMode = .bySource
    @Published var listSections: [AppListSection] = []
    @Published var findings: [AppRiskFinding] = []
    @Published var aiDigest: String = ""
    @Published var updateSuggestions: [UpdateSuggestion] = []
    @Published var isLoading = false
    @Published var showSettings = false
    @Published var apiKey: String = UserDefaults.standard.string(forKey: "ai.apiKey") ?? ""
    @Published var baseURL: String = UserDefaults.standard.string(forKey: "ai.baseURL") ?? "https://api.openai.com/v1"
    @Published var model: String = UserDefaults.standard.string(forKey: "ai.model") ?? "gpt-4o-mini"
    @Published var capabilityStatuses: [CapabilityStatus] = []
    @Published var flavor: AppFlavor = CapabilityPolicy.current.flavor
    @Published var aiCategories: [String: String] = [:]
    @Published var aiCategoryDescriptions: [String: String] = [:]
    @Published var isOrganizing = false
    @Published var aiOrganizationProgress: String = ""
    @Published var aiReport: String = ""
    @Published var isGeneratingReport = false
    @Published var showAIReport = false
    @Published var appTags: [String: [String]] = [:]
    @Published var aiAssistantText: String = ""
    @Published var isAIProcessing = false
    @Published var aiProcessingProgress: String = ""

    private let pipeline = AuditPipeline()
    private let aiRouter = AIProviderRouter()
    private let updateService = UpdateAdvisorService()
    private let riskEngine = PermissionHeuristicsEngine()
    private let categoryClassifier = AppCategoryClassifier()
    private let cacheStore = AppCacheStore()
    private let tagStore = AppTagStore()
    private var recentUsageStore = RecentUsageStore()
    private let taggingService = AITaggingService()
    private let nlSearch = AINaturalLanguageSearch()
    private var lastGoodAIExplanation: String = ""

    func saveAPISettings() {
        UserDefaults.standard.set(apiKey, forKey: "ai.apiKey")
        UserDefaults.standard.set(baseURL, forKey: "ai.baseURL")
        UserDefaults.standard.set(model, forKey: "ai.model")
    }

    func bootstrap() async {
        isLoading = true
        appTags = tagStore.load()

        // 1. Load cache for instant display
        if let cached = cacheStore.load(), !cached.isEmpty {
            apps = cached
            capabilityStatuses = CapabilityFeature.allCases.map { CapabilityPolicy.current.status(for: $0) }
            findings = buildRiskFindings(for: apps)
            rebuildListSections()
            isLoading = false
        }

        // 2. Full scan in background
        let output = await pipeline.run()
        apps = output.0
        capabilityStatuses = output.1
        findings = buildRiskFindings(for: apps)
        rebuildListSections()
        updateSuggestions = await updateService.suggest(for: apps)

        // 3. Save fresh data to cache
        cacheStore.save(apps)
        isLoading = false

        // 4. Auto AI tasks if API configured
        if !apiKey.isEmpty {
            await runAIBackgroundTasks()
        }
    }

    private func runAIBackgroundTasks() async {
        isAIProcessing = true
        defer { isAIProcessing = false; aiProcessingProgress = "" }

        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.3,
            maxTokens: 2000
        )

        // 1. AI tag generation
        aiProcessingProgress = "正在生成应用标签..."
        do {
            let tags = try await taggingService.generateTags(for: apps, config: config)
            appTags = tagStore.merging(tags, into: appTags)
            tagStore.save(appTags)
        } catch {
            // Continue even if tagging fails
        }

        // 2. AI organization
        aiProcessingProgress = "正在生成AI整理..."
        await runAIOrganization()

        // 3. AI report
        aiProcessingProgress = "正在生成审计报告..."
        await runAIReport()

        // 4. Build AI assistant summary
        aiAssistantText = buildAIAssistantSummary()
    }

    private func buildAIAssistantSummary() -> String {
        var lines: [String] = []
        lines.append("📊 应用总览: \(apps.count) 个应用")
        let bgCount = apps.filter { $0.permissions.backgroundResident }.count
        lines.append("• App Store: \(apps.filter { $0.source == .appStore }.count) | 第三方: \(apps.filter { $0.source == .thirdParty }.count)")
        lines.append("• 后台常驻: \(bgCount) | 高风险: \(findings.filter { $0.level == .high }.count)")
        if !aiCategories.isEmpty {
            let topCategories = Dictionary(grouping: aiCategories.values) { $0 }
                .map { ($0.key, $0.value.count) }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
                .map { "\($0.0)(\($0.1))" }
            lines.append("• AI分类: \(topCategories.joined(separator: ", "))")
        }
        lines.append("\n点击此栏查看完整AI报告")
        return lines.joined(separator: "\n")
    }

    func applySearchAndGrouping() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            rebuildListSections()
        }
    }

    func runAIDigest() async {
        guard !apps.isEmpty else { return }
        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.2,
            maxTokens: 240
        )
        let prompt = "请按来源、类别、后台常驻情况给出应用整理摘要，并附1条简单审计提醒。"
        let (_, explanation) = await aiRouter.execute(query: prompt, apps: filteredApps(), config: config)
        if explanation.contains("AI 调用失败") {
            aiDigest = lastGoodAIExplanation.isEmpty ? explanation : "\(explanation)\n(已回退展示最近一次成功结果)"
        } else {
            lastGoodAIExplanation = explanation
            aiDigest = explanation
        }
    }

    func runAIOrganization() async {
        guard !apps.isEmpty else { return }
        isOrganizing = true
        aiOrganizationProgress = "正在准备应用列表..."
        defer { isOrganizing = false; aiOrganizationProgress = "" }

        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.3,
            maxTokens: 1600
        )

        let appList = filteredApps().map { "- \($0.name) (\($0.version))" }.joined(separator: "\n")
        aiOrganizationProgress = "正在请求 AI 分类..."

        let prompt = """
        你是一位 macOS 系统管理员，请将以下应用按用途智能分类。

        要求：
        1. 从以下类别中选择最合适的（可以新增类别）：
           - 开发工具（IDE、编译器、终端、版本控制等）
           - 设计创作（设计、绘图、视频编辑、音频制作等）
           - 办公效率（文档、笔记、表格、演示等）
           - 沟通协作（聊天、邮件、视频会议等）
           - 系统工具（清理、监控、文件管理、启动器等）
           - 网络浏览（浏览器、下载工具、VPN等）
           - 安全隐私（密码管理、杀毒、加密等）
           - 娱乐影音（音乐、视频、游戏等）
           - 教育学习（学习、阅读、编程练习等）
           - 其他

        2. 返回纯 JSON，格式如下（不要其他文字）：
        {
          "appCategories": {"应用名": "类别", ...},
          "categoryDescriptions": {"类别名": "一句话描述该类别", ...}
        }

        应用列表：
        \(appList)
        """

        let adapter = OpenAICompatibleAdapter()
        let payload = Data("[]".utf8)
        do {
            let response = try await adapter.complete(prompt: prompt, payload: payload, config: config)
            aiOrganizationProgress = "正在解析分类结果..."
            if let jsonData = extractJSON(from: response) {
                // Try new structured format first
                if let parsed = try? JSONDecoder().decode(AIOrganizationResponse.self, from: jsonData) {
                    aiCategories = parsed.appCategories
                    aiCategoryDescriptions = parsed.categoryDescriptions
                }
                // Fallback to old format
                else if let parsed = try? JSONDecoder().decode([String: String].self, from: jsonData) {
                    aiCategories = parsed
                }
                if groupingMode == .byAI {
                    rebuildListSections()
                }
            }
        } catch {
            aiOrganizationProgress = "分类失败，可重试"
        }
    }

    func runAIReport() async {
        guard !apps.isEmpty else { return }
        isGeneratingReport = true
        defer { isGeneratingReport = false }

        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.4,
            maxTokens: 1200
        )

        let totalApps = apps.count
        let appStoreCount = apps.filter { $0.source == .appStore }.count
        let thirdPartyCount = apps.filter { $0.source == .thirdParty }.count
        let bgResidentCount = apps.filter { $0.permissions.backgroundResident }.count
        let unsignedCount = apps.filter { $0.signature.trustLevel == .unsignedHighRisk }.count
        let highRiskCount = findings.filter { $0.level == .high }.count
        let sensitivePermApps = apps.filter { !$0.permissions.requested.isEmpty }.count

        let categoryBreakdown = Dictionary(grouping: apps) { app in
            aiCategories[app.name] ?? categoryClassifier.category(for: app).rawValue
        }.map { "\($0.key): \($0.value.count)个" }.sorted().joined(separator: "、")

        let topFindings = findings.prefix(5).map { "[\($0.level.rawValue)] \($0.appName): \($0.reason)" }.joined(separator: "\n")

        let prompt = """
        请为以下 macOS 应用生态生成一份结构化审计报告，使用中文。

        基础统计：
        - 总应用数: \(totalApps)
        - App Store: \(appStoreCount), 第三方: \(thirdPartyCount)
        - 后台常驻应用: \(bgResidentCount)
        - 未签名应用: \(unsignedCount)
        - 高风险发现: \(highRiskCount) 项
        - 涉及敏感权限的应用: \(sensitivePermApps) 个

        分类分布：\(categoryBreakdown)

        高风险发现详情：
        \(topFindings.isEmpty ? "无" : topFindings)

        请输出以下结构（每部分用 markdown 标题）：
        ## 总体概况
        ## 分类分布分析
        ## 安全态势评估
        ## 需关注的应用
        ## 优化建议（3-5 条可执行建议）
        """

        let adapter = OpenAICompatibleAdapter()
        let payload = Data("[]".utf8)
        do {
            let response = try await adapter.complete(prompt: prompt, payload: payload, config: config)
            aiReport = response
        } catch {
            aiReport = "报告生成失败: \(error.localizedDescription)"
        }

        showAIReport = true
    }

    private func extractJSON(from text: String) -> Data? {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            let json = String(text[start...end])
            return Data(json.utf8)
        }
        return nil
    }

    private(set) var appStoreBytes: Int64 = 0
    private(set) var thirdPartyBytes: Int64 = 0

    var summaryText: String {
        let backgroundCount = apps.filter { $0.permissions.backgroundResident }.count
        return "总计 \(apps.count) 个应用，后台常驻 \(backgroundCount) 个。"
    }

    func addTag(to appName: String, tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var tags = appTags[appName] ?? []
        if !tags.contains(trimmed) {
            tags.append(trimmed)
            appTags[appName] = tags
            tagStore.save(appTags)
        }
    }

    func removeTag(from appName: String, tag: String) {
        appTags[appName]?.removeAll { $0 == tag }
        tagStore.save(appTags)
    }

    func recordAppOpen(_ app: AppRecord) {
        recentUsageStore.recordOpen(appName: app.name)
    }

    private func buildRiskFindings(for apps: [AppRecord]) -> [AppRiskFinding] {
        apps.compactMap { app in
            let signals = riskEngine.evaluate(app: app)
            guard let topSignal = signals.max(by: { rank($0.level) < rank($1.level) }) else {
                return nil
            }
            return AppRiskFinding(
                appName: app.name,
                level: topSignal.level,
                reason: topSignal.reason,
                signals: signals
            )
        }
        .prefix(12)
        .map { $0 }
    }

    private func filteredApps() -> [AppRecord] {
        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return apps }
        // Try tag-based natural language search first
        let tagResults = nlSearch.matchApps(query: key, tags: appTags, apps: apps)
        if !tagResults.isEmpty { return tagResults }
        // Fallback to text match
        return apps.filter { app in
            app.name.lowercased().contains(key)
                || (app.bundleID?.lowercased().contains(key) ?? false)
                || app.path.lowercased().contains(key)
        }
    }

    private func rebuildListSections() {
        appStoreBytes = apps.filter { $0.source == .appStore }.map(\.sizeBytes).reduce(0, +)
        thirdPartyBytes = apps.filter { $0.source == .thirdParty }.map(\.sizeBytes).reduce(0, +)

        let visible = filteredApps()
        switch groupingMode {
        case .bySource:
            let grouped = Dictionary(grouping: visible) { $0.source.rawValue }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .byCategory:
            let grouped = Dictionary(grouping: visible) { categoryClassifier.category(for: $0).rawValue }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .byResidency:
            let grouped = Dictionary(grouping: visible) { $0.permissions.backgroundResident ? "后台常驻" : "前台/按需运行" }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .byAI:
            let grouped = Dictionary(grouping: visible) { app in
                aiCategories[app.name] ?? "未分类"
            }
            listSections = grouped.keys.sorted().map { key in
                let desc = aiCategoryDescriptions[key]
                let title = desc != nil ? "\(key) — \(desc!)" : key
                return AppListSection(title: title, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .recentlyUsed:
            let recent = recentUsageStore.recentApps(limit: 30)
            let recentApps = recent.compactMap { name in visible.first { $0.name == name } }
            if recentApps.isEmpty {
                listSections = [AppListSection(title: "最近常用", apps: [])]
            } else {
                listSections = [AppListSection(title: "最近常用", apps: recentApps)]
            }
        }
    }

    private func rank(_ level: AuditRiskLevel) -> Int {
        switch level {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

}
