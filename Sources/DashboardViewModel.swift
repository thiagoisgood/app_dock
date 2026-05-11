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
    @Published var reportGeneratedAt: Date = Date()
    @Published var reportStats: ReportStats = ReportStats()
    @Published var appTags: [String: [String]] = [:]
    @Published var aiAssistantText: String = ""
    @Published var isAIProcessing = false
    @Published var aiProcessingProgress: String = ""

    private let pipeline = AuditPipeline()
    private let aiRouter = AIProviderRouter()
    private let updateService = UpdateAdvisorService()
    private let riskEngine = PermissionHeuristicsEngine()
    private let categoryClassifier = AppCategoryClassifier()
    private let classifierService = AppClassifierService()
    private let cacheStore = AppCacheStore()
    private let tagStore = AppTagStore()
    private var recentUsageStore = RecentUsageStore()
    private let taggingService = AITaggingService()
    private var nlSearch: AINaturalLanguageSearch {
        AINaturalLanguageSearch(
            mappingStore: searchMappingStore,
            aliasStore: aliasStore,
            feedbackStore: feedbackStore,
            aiCategories: aiCategories,
            weights: feedbackStore.weights
        )
    }
    private(set) var tokenUsageStore = TokenUsageStore()  // Public getter for UI
    private let searchMappingStore = SearchMappingStore()
    private let searchMappingGenerator = AISearchMappingGenerator()
    private let classificationStore = AIClassificationStore()
    private let feedbackStore = SearchFeedbackStore()
    private let aliasStore = AppNameAliasStore()
    private var lastGoodAIExplanation: String = ""

    // 搜索反馈追踪
    private var searchStartTime: Date?
    private var lastSearchResults: [AppRecord] = []
    @Published var searchResults: [SearchResult] = []
    @Published var searchLearningStats: SearchLearningStats = SearchLearningStats()

    @Published var tokenUsageSummary: TokenUsageSummary = TokenUsageSummary()
    @Published var searchMappings: [SearchMapping] = []
    @Published var isUpdatingMappings = false

    func saveAPISettings() {
        UserDefaults.standard.set(apiKey, forKey: "ai.apiKey")
        UserDefaults.standard.set(baseURL, forKey: "ai.baseURL")
        UserDefaults.standard.set(model, forKey: "ai.model")
    }

    func bootstrap() async {
        isLoading = true
        appTags = tagStore.load()
        searchMappings = searchMappingStore.getMappings()
        searchLearningStats = feedbackStore.stats

        // Load cached AI classification results
        if let cachedClassification = classificationStore.load() {
            aiCategories = cachedClassification.categories
            aiCategoryDescriptions = cachedClassification.descriptions
        }

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

        // 4. AI strategy: only run if no cached results OR API key just changed
        let hasCachedAI = !aiCategories.isEmpty
        if !apiKey.isEmpty && !hasCachedAI {
            // 首次配置或缓存清空：运行完整 AI 分类
            await runAIBackgroundTasks()
        } else if !apiKey.isEmpty && hasCachedAI {
            // 有缓存：只检查新应用
            let cachedApps = cacheStore.load() ?? []
            let cachedBundleIDs = Set(cachedApps.compactMap { $0.bundleID })
            let newApps = apps.filter { app in
                if let bid = app.bundleID { return !cachedBundleIDs.contains(bid) }
                return !cachedApps.contains { $0.name == app.name && $0.path == app.path }
            }
            if !newApps.isEmpty {
                await processNewlyInstalledApps(newApps)
            } else {
                // 无新应用：只构建摘要
                aiAssistantText = buildAIAssistantSummary()
            }
        }

        // 5. Load token usage summary
        tokenUsageSummary = tokenUsageStore.getSummary()
    }

    func updateSearchMappings() async {
        guard !apiKey.isEmpty else { return }
        isUpdatingMappings = true
        defer { isUpdatingMappings = false }

        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.3,
            maxTokens: 2000
        )

        do {
            let newMappings = try await searchMappingGenerator.generateMappings(for: apps, config: config)
            searchMappingStore.updateMappings(newMappings: newMappings)
            searchMappings = searchMappingStore.getMappings()
            tokenUsageSummary = tokenUsageStore.getSummary()
            print("[ViewModel] Updated search mappings: \(newMappings.count) categories")
        } catch {
            print("[ViewModel] Failed to update search mappings: \(error.localizedDescription)")
        }
    }

    func refresh() async {
        isLoading = true
        aiProcessingProgress = "正在扫描新安装的应用..."

        // Get previous app list
        let previousApps = apps

        // Run new scan
        let output = await pipeline.run()
        let newApps = output.0

        // Find newly installed apps
        let previousBundleIDs = Set(previousApps.compactMap { $0.bundleID })
        let newlyInstalled = newApps.filter { app in
            if let bid = app.bundleID {
                return !previousBundleIDs.contains(bid)
            }
            // For apps without bundleID, check by name and path
            return !previousApps.contains { $0.name == app.name && $0.path == app.path }
        }

        print("[Refresh] Found \(newlyInstalled.count) newly installed apps")

        // Update main list
        apps = newApps
        capabilityStatuses = output.1
        findings = buildRiskFindings(for: apps)
        rebuildListSections()
        updateSuggestions = await updateService.suggest(for: apps)
        cacheStore.save(apps)
        isLoading = false

        // Process newly installed apps if API configured
        if !apiKey.isEmpty && !newlyInstalled.isEmpty {
            await processNewlyInstalledApps(newlyInstalled)
        }

        // Refresh token usage summary
        tokenUsageSummary = tokenUsageStore.getSummary()
    }

    private func processNewlyInstalledApps(_ newApps: [AppRecord]) async {
        isAIProcessing = true
        defer { isAIProcessing = false; aiProcessingProgress = "" }

        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.3,
            maxTokens: 2000
        )

        // 使用统一分类服务：同时生成类别和标签
        aiProcessingProgress = "正在为新应用进行AI分类..."
        let (categories, tags) = await classifierService.classifyWithTags(
            apps: newApps,
            existingCategories: existingCategoryMap(),
            config: config
        )

        // 更新类别
        for result in categories {
            aiCategories[result.appName] = result.category
            if let bid = result.bundleID, bid != "unknown" {
                aiCategories[bid] = result.category
            }
        }
        // 填充类别描述
        for (_, cat) in aiCategories {
            if aiCategoryDescriptions[cat] == nil {
                aiCategoryDescriptions[cat] = CategorySchema.description(for: cat)
            }
        }

        // 更新标签
        appTags = tagStore.merging(tags, into: appTags)
        tagStore.save(appTags)

        // Save classification results to cache
        classificationStore.save(categories: aiCategories, descriptions: aiCategoryDescriptions)

        // 增量更新名称别名
        aiProcessingProgress = "正在更新名称映射..."
        do {
            let newAliases = try await aliasStore.generateAliases(for: newApps, config: config)
            if !newAliases.isEmpty {
                aliasStore.updateAliases(newAliases)
            }
        } catch {
            print("[AI] Failed to update name aliases: \(error.localizedDescription)")
        }

        aiAssistantText = buildAIAssistantSummary()
        rebuildListSections()
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

        print("[AI] Starting background tasks with model: \(config.model), baseURL: \(config.baseURL)")

        // 1. 统一分类+标签（替代原有的 tagging + organization 两次调用）
        aiProcessingProgress = "正在进行AI整理..."
        let (categories, tags) = await classifierService.classifyWithTags(
            apps: apps,
            existingCategories: existingCategoryMap(),
            config: config
        )

        // 更新类别
        for result in categories {
            aiCategories[result.appName] = result.category
            if let bid = result.bundleID, bid != "unknown" {
                aiCategories[bid] = result.category
            }
        }
        // 填充类别描述（从 CategorySchema 获取）
        let usedCategories = Set(aiCategories.values)
        for cat in usedCategories {
            if aiCategoryDescriptions[cat] == nil {
                aiCategoryDescriptions[cat] = CategorySchema.description(for: cat)
            }
        }

        // 更新标签
        appTags = tagStore.merging(tags, into: appTags)
        tagStore.save(appTags)

        // 保存分类结果到持久化存储
        classificationStore.save(categories: aiCategories, descriptions: aiCategoryDescriptions)

        tokenUsageSummary = tokenUsageStore.getSummary()

        print("[AI] Classification complete: \(categories.count) apps classified, \(tags.count) apps tagged")

        // 4. 生成应用中英文别名映射（首次配置时调用）
        if aliasStore.getAliases().isEmpty {
            aiProcessingProgress = "正在生成应用中英文名称映射..."
            do {
                let newAliases = try await aliasStore.generateAliases(for: apps, config: config)
                if !newAliases.isEmpty {
                    aliasStore.updateAliases(newAliases)
                    print("[AI] Generated \(newAliases.count) name aliases")
                }
            } catch {
                print("[AI] Failed to generate name aliases: \(error.localizedDescription)")
            }
        }

        // 5. AI report
        aiProcessingProgress = "正在生成审计报告..."
        await runAIReport()

        // 6. Update search mappings
        aiProcessingProgress = "正在更新搜索映射..."
        await updateSearchMappings()

        // 7. Build AI assistant summary
        aiAssistantText = buildAIAssistantSummary()
        print("[AI] Background tasks complete. Tags: \(appTags.count) apps, Categories: \(aiCategories.count), Mappings: \(searchMappings.count), Aliases: \(aliasStore.getAliases().count)")
    }

    /// 将当前 aiCategories 转为 [String: String] 映射，供 classifierService 兼容使用
    private func existingCategoryMap() -> [String: String] {
        aiCategories
    }

    private func buildAIAssistantSummary() -> String {
        var lines: [String] = []
        lines.append("📊 应用总览: \(apps.count) 个应用")
        let bgCount = apps.filter { $0.permissions.backgroundResident }.count
        lines.append("• 系统: \(systemCount) | App Store: \(appStoreCount) | 第三方: \(thirdPartyCount)")
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
        // 使用 DispatchQueue.main.async 确保在下一个 run loop 周期执行
        // 避免在视图更新周期中修改 @Published 属性
        DispatchQueue.main.async { [weak self] in
            self?.rebuildListSections()
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
        aiOrganizationProgress = "正在分类..."
        defer { isOrganizing = false; aiOrganizationProgress = "" }

        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.2,
            maxTokens: 2400
        )

        let categories = await classifierService.classify(
            apps: filteredApps(),
            existingCategories: existingCategoryMap(),
            config: config
        )

        // 更新类别映射
        for result in categories {
            aiCategories[result.appName] = result.category
            if let bid = result.bundleID, bid != "unknown" {
                aiCategories[bid] = result.category
            }
        }
        // 填充类别描述
        for (_, cat) in aiCategories {
            if aiCategoryDescriptions[cat] == nil {
                aiCategoryDescriptions[cat] = CategorySchema.description(for: cat)
            }
        }

        tokenUsageSummary = tokenUsageStore.getSummary()
        print("[AI] Organization complete: \(categories.count) apps classified into \(Set(categories.map(\.category)).count) categories")

        // Save classification results to cache
        classificationStore.save(categories: aiCategories, descriptions: aiCategoryDescriptions)

        rebuildListSections()
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
            maxTokens: 2000
        )

        // 基础统计
        let totalApps = apps.count
        let systemCount = apps.filter { $0.source == .system }.count
        let appStoreCount = apps.filter { $0.source == .appStore }.count
        let thirdPartyCount = apps.filter { $0.source == .thirdParty }.count
        let bgResidentCount = apps.filter { $0.permissions.backgroundResident }.count
        let unsignedCount = apps.filter { $0.signature.trustLevel == .unsignedHighRisk }.count
        let highRiskCount = findings.filter { $0.level == .high }.count
        let sensitivePermApps = apps.filter { !$0.permissions.requested.isEmpty }.count

        // 签名信任分布
        let sigDistribution = Dictionary(grouping: apps, by: \.signature.trustLevel)
            .map { "\($0.key.rawValue): \($0.value.count)个" }
            .joined(separator: "、")

        // 标签统计
        let taggedAppsCount = appTags.filter { !$0.value.isEmpty }.count
        let allTags = appTags.values.flatMap { $0 }
        let tagFrequency = Dictionary(grouping: allTags, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map { "\($0.0)(\($0.1))" }
            .joined(separator: "、")

        // 资源消耗 TOP3
        let topCPU = apps.sorted { $0.metrics.cpuPercent > $1.metrics.cpuPercent }
            .prefix(3)
            .filter { $0.metrics.cpuPercent > 0 }
            .map { "\($0.name)(\($0.metrics.cpuPercent)%)" }
            .joined(separator: "、")
        let topMemory = apps.sorted { $0.metrics.memoryMB > $1.metrics.memoryMB }
            .prefix(3)
            .filter { $0.metrics.memoryMB > 100 }
            .map { "\($0.name)(\(Int($0.metrics.memoryMB))MB)" }
            .joined(separator: "、")

        // 分类分布详情
        let categoryDetail = Dictionary(grouping: apps) { app in
            if let bid = app.bundleID, let cat = aiCategories[bid] { return cat }
            return aiCategories[app.name] ?? categoryClassifier.category(for: app).rawValue
        }.map { (cat, appsInCat) in
            let topNames = appsInCat.sorted { $0.metrics.cpuPercent > $1.metrics.cpuPercent }
                .prefix(2).map(\.name).joined(separator: "、")
            return "- \(cat): \(appsInCat.count)个 (\(topNames))"
        }.sorted().joined(separator: "\n")

        // 权限风险矩阵
        let dangerousPerms: Set<PermissionKind> = [.camera, .microphone, .fullDiskAccess, .screenRecording, .accessibility]
        let permRiskApps = apps
            .map { (app: $0, dangerous: $0.permissions.requested.intersection(dangerousPerms)) }
            .filter { $0.dangerous.count >= 2 }
            .sorted { $0.dangerous.count > $1.dangerous.count }
            .prefix(5)
            .map { "- \($0.app.name): \($0.dangerous.map(\.rawValue).joined(separator: "+"))" }
            .joined(separator: "\n")

        // 高风险发现
        let topFindings = findings.prefix(5).map { "[\($0.level.rawValue)] \($0.appName): \($0.reason)" }.joined(separator: "\n")

        // 新增应用
        let cachedApps = cacheStore.load() ?? []
        let cachedNames = Set(cachedApps.map(\.name))
        let newAppNames = apps.filter { !cachedNames.contains($0.name) }
            .map { $0.name }
            .prefix(5)
            .joined(separator: "、")

        // Token 使用上下文
        let totalOps = tokenUsageSummary.operationCounts.values.reduce(0, +)
        let tokenContext = "总调用 \(totalOps) 次, 累计 \(tokenUsageSummary.totalTokens) tokens"

        let prompt = """
        你是资深 macOS 系统安全审计专家。请基于以下数据生成一份详细的中文审计报告。

        ## 应用生态数据

        ### 基础统计
        - 总应用数: \(totalApps)
        - 来源分布: 系统 \(systemCount)个, App Store \(appStoreCount)个, 第三方 \(thirdPartyCount)个
        - 后台常驻应用: \(bgResidentCount)个
        - 未签名/高风险应用: \(unsignedCount)个
        - 高风险发现: \(highRiskCount)项
        - 涉及敏感权限的应用: \(sensitivePermApps)个

        ### 签名信任分布
        \(sigDistribution)

        ### 标签统计
        - 已打标签应用: \(taggedAppsCount)/\(totalApps)
        - 热门标签: \(tagFrequency.isEmpty ? "无" : tagFrequency)

        ### 资源消耗 TOP3
        - CPU: \(topCPU.isEmpty ? "无明显占用" : topCPU)
        - 内存: \(topMemory.isEmpty ? "无明显占用" : topMemory)

        ### 分类分布详情
        \(categoryDetail)

        ### 权限风险矩阵（多危险权限组合）
        \(permRiskApps.isEmpty ? "无显著风险组合" : permRiskApps)

        ### 高风险发现
        \(topFindings.isEmpty ? "无" : topFindings)

        ### 新增应用
        \(newAppNames.isEmpty ? "无新增应用" : "近期新增: \(newAppNames)")

        ### Token 使用统计
        \(tokenContext)

        ## 输出格式要求
        请使用 Markdown 格式，严格遵循以下结构：

        ## 总体概况
        （一段话总结应用生态整体健康状况，包含关键数字）

        ## 分类分布分析
        （按类别分析，指出哪类应用最多、是否存在某类过多或不足）

        ## 安全态势评估
        （基于签名分布、权限风险矩阵、后台常驻情况评估整体安全水平）

        ## 资源消耗分析
        （分析 CPU/内存大户，指出可能的性能优化点）

        ## 需关注的应用
        （列出 3-5 个最值得关注的应用，说明原因）

        ## 优化建议
        （3-5 条具体可执行建议，每条以 - 开头）

        ## 格式注意
        - 每个 ## 标题后跟一段分析文字
        - 列表项统一使用 - 前缀
        - 应用名称使用 **加粗** 标记
        - 保持分析简洁，总字数控制在 800-1200 字
        """

        let adapter = OpenAICompatibleAdapter()
        let payload = Data("[]".utf8)
        do {
            let result = try await adapter.complete(prompt: prompt, payload: payload, config: config)
            aiReport = result.content
            if let pt = result.promptTokens, let ct = result.completionTokens {
                tokenUsageStore.recordUsage(
                    operation: "report",
                    model: config.model,
                    promptTokens: pt,
                    completionTokens: ct
                )
                tokenUsageSummary = tokenUsageStore.getSummary()
            }
        } catch {
            aiReport = "报告生成失败: \(error.localizedDescription)"
        }

        // 填充报告统计元数据
        reportGeneratedAt = Date()
        reportStats = ReportStats(
            totalApps: totalApps,
            highRisk: highRiskCount,
            unsigned: unsignedCount,
            bgResident: bgResidentCount
        )

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
    private(set) var systemCount: Int = 0
    private(set) var appStoreCount: Int = 0
    private(set) var thirdPartyCount: Int = 0

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

    func resolvedCategory(for app: AppRecord) -> String {
        if let bid = app.bundleID, let cat = aiCategories[bid] { return cat }
        if let cat = aiCategories[app.name] { return cat }
        return categoryClassifier.category(for: app).rawValue
    }

    func changeCategory(for appName: String, bundleID: String?, to category: String) {
        aiCategories[appName] = category
        if let bid = bundleID, !bid.isEmpty {
            aiCategories[bid] = category
        }
        classificationStore.save(categories: aiCategories, descriptions: aiCategoryDescriptions)
        rebuildListSections()
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
        guard !key.isEmpty else { searchResults = []; return apps }

        searchStartTime = Date()
        let results = nlSearch.matchAppsWithHints(query: searchText, tags: appTags, apps: apps)
        if !results.isEmpty {
            searchResults = results
            lastSearchResults = results.map(\.app)
            return results.map(\.app)
        }

        // Fallback to text match
        searchResults = []
        let textResults = apps.filter { app in
            app.name.lowercased().contains(key)
                || (app.bundleID?.lowercased().contains(key) ?? false)
                || app.path.lowercased().contains(key)
        }
        lastSearchResults = textResults
        return textResults
    }

    func searchHints(for app: AppRecord) -> [SearchMatchHint] {
        searchResults.first(where: { $0.app.id == app.id })?.hints ?? []
    }

    func recordSearchClick(app: AppRecord, resultIndex: Int) {
        guard let startTime = searchStartTime, !searchText.isEmpty else { return }
        let delay = Date().timeIntervalSince(startTime)
        let intent = IntentDetector.detectIntent(query: searchText, knownAppNames: Set(apps.map(\.name)))
        let event = SearchFeedbackEvent(
            query: searchText,
            intent: intent,
            resultCount: lastSearchResults.count,
            clickedApp: app.name,
            clickedIndex: resultIndex,
            clickDelay: delay,
            timestamp: Date(),
            hasResults: !lastSearchResults.isEmpty
        )
        feedbackStore.recordEvent(event)
        searchLearningStats = feedbackStore.stats
        rebuildListSections()

        // 强化名称别名映射
        let aliases = aliasStore.aliases(for: searchText)
        if !aliases.isEmpty && aliases.contains(app.name) {
            aliasStore.reinforce(app.name, searchText, positive: true)
        }
    }

    func recordSearchNoClick() {
        guard !searchText.isEmpty, !lastSearchResults.isEmpty else { return }
        let intent = IntentDetector.detectIntent(query: searchText, knownAppNames: Set(apps.map(\.name)))
        let event = SearchFeedbackEvent(
            query: searchText,
            intent: intent,
            resultCount: lastSearchResults.count,
            clickedApp: nil,
            clickedIndex: nil,
            clickDelay: nil,
            timestamp: Date(),
            hasResults: true
        )
        feedbackStore.recordEvent(event)
        searchLearningStats = feedbackStore.stats
    }

    private func rebuildListSections() {
        appStoreBytes = apps.filter { $0.source == .appStore }.map(\.sizeBytes).reduce(0, +)
        thirdPartyBytes = apps.filter { $0.source == .thirdParty }.map(\.sizeBytes).reduce(0, +)
        systemCount = apps.filter { $0.source == .system }.count
        appStoreCount = apps.filter { $0.source == .appStore }.count
        thirdPartyCount = apps.filter { $0.source == .thirdParty }.count

        let visible = filteredApps()
        switch groupingMode {
        case .bySource:
            let grouped = Dictionary(grouping: visible) { $0.source.rawValue }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .byCategory:
            let grouped = Dictionary(grouping: visible) { app in
                // 优先使用AI分类结果
                if let bid = app.bundleID, let cat = aiCategories[bid] {
                    return cat
                }
                if let cat = aiCategories[app.name] {
                    return cat
                }
                // 回退到启发式分类
                return categoryClassifier.category(for: app).rawValue
            }
            listSections = grouped.keys.sorted().map { key in
                // 尝试从 AI 描述或 Schema 获取类别描述
                let desc = aiCategoryDescriptions[key] ?? CategorySchema.description(for: key)
                let title = desc.isEmpty ? key : "\(key) — \(desc)"
                return AppListSection(title: title, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .byResidency:
            let grouped = Dictionary(grouping: visible) { $0.permissions.backgroundResident ? "后台常驻" : "前台/按需运行" }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
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
