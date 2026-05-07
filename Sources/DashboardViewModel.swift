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

        print("[AI] Starting background tasks with model: \(config.model), baseURL: \(config.baseURL)")

        // 1. AI tag generation
        aiProcessingProgress = "正在生成应用标签..."
        do {
            let tags = try await taggingService.generateTags(for: apps, config: config)
            print("[AI] Tagging returned \(tags.count) app tags")
            appTags = tagStore.merging(tags, into: appTags)
            tagStore.save(appTags)
        } catch {
            print("[AI] Tagging failed: \(error.localizedDescription)")
            aiProcessingProgress = "标签生成失败: \(error.localizedDescription)"
        }

        // 2. AI organization
        aiProcessingProgress = "正在生成AI整理..."
        await runAIOrganization()

        // 3. AI report
        aiProcessingProgress = "正在生成审计报告..."
        await runAIReport()

        // 4. Build AI assistant summary
        aiAssistantText = buildAIAssistantSummary()
        print("[AI] Background tasks complete. Tags: \(appTags.count) apps, Categories: \(aiCategories.count)")
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
            temperature: 0.2,
            maxTokens: 2400
        )

        let adapter = OpenAICompatibleAdapter()
        var allCategories: [String: String] = [:]
        var allDescriptions: [String: String] = [:]

        // Batch apps in groups of 25 for better accuracy
        let targetApps = filteredApps()
        let batchSize = 25
        let batches = stride(from: 0, to: targetApps.count, by: batchSize).map {
            Array(targetApps[$0..<min($0 + batchSize, targetApps.count)])
        }

        for (index, batch) in batches.enumerated() {
            aiOrganizationProgress = "正在分类 \(index + 1)/\(batches.count) 批..."

            // Build rich context for each app
            let appEntries = batch.map { app -> String in
                let perms = app.permissions.requested.map(\.rawValue).joined(separator: ",")
                let bgFlag = app.permissions.backgroundResident ? "是" : "否"
                let sourceLabel: String
                switch app.source {
                case .system: sourceLabel = "macOS系统自带"
                case .appStore: sourceLabel = "App Store"
                case .thirdParty: sourceLabel = "第三方"
                case .unknown: sourceLabel = "未知"
                }
                return """
                  {
                    "name": "\(app.name)",
                    "bundleID": "\(app.bundleID ?? "unknown")",
                    "version": "\(app.version)",
                    "source": "\(sourceLabel)",
                    "background": \(bgFlag),
                    "permissions": "[\(perms)]"
                  }
                """
            }

            let prompt = """
            你是一位资深 macOS 系统管理员，精通 Apple 生态。请根据以下应用的 **名称、Bundle ID、来源、权限** 等元数据，将每个应用归入最合适的类别。

            ## 分类规则

            1. 优先使用以下预设类别（可根据应用特点新增更精确的类别）：
               - **开发工具**: IDE、编译器、终端、数据库、版本控制、容器、调试器。例: Xcode, VS Code, iTerm2, Docker, Git, Postman
               - **设计创作**: UI/UX 设计、图片编辑、视频剪辑、音频制作、3D 建模、字体工具。例: Figma, Sketch, Photoshop, Final Cut, Blender
               - **办公效率**: 文档编辑、笔记、表格、演示、项目管理、日历、邮件客户端。例: Notion, Obsidian, Microsoft Office, Things, Fantastical
               - **沟通协作**: 即时通讯、视频会议、团队协作、社交网络。例: 微信, Slack, Zoom, Discord, Telegram
               - **系统工具**: macOS 系统组件、清理工具、监控、启动器、文件管理、输入法、系统偏好设置。例: Activity Monitor, Alfred, Raycast, CleanMyMac, 搜狗输入法
               - **网络浏览**: 浏览器、下载管理器、代理工具、VPN。例: Safari, Chrome, Firefox, Downie, Surge
               - **安全隐私**: 密码管理、杀毒软件、加密工具、防火墙、隐私保护。例: 1Password, Bitwarden, Little Snitch
               - **影音娱乐**: 音乐播放、视频播放、游戏、直播、播客。例: Spotify, VLC, Steam, IINA
               - **阅读教育**: 电子书阅读、学习工具、翻译、文献管理。例: Kindle, MarginNote, Zotero, 有道词典
               - **金融理财**: 记账、股票、银行、支付。例: 支付宝, 随手记

            2. **关键判断依据**：
               - Bundle ID 包含 "apple" 或来源为"macOS系统自带" → 系统工具
               - 有摄像头/麦克风权限 + 来源为"第三方" → 大概率是沟通协作或影音娱乐
               - 有辅助功能/屏幕录制权限 → 可能是系统工具或开发工具
               - 后台常驻(background=true) → 关注其核心功能判断类别

            3. **输出格式**：返回纯 JSON 数组，不要其他文字。
            [
              {"name": "应用显示名", "bundleID": "com.example.app", "category": "类别名"},
              ...
            ]

            ## 应用列表
            \(appEntries.joined(separator: ",\n"))
            """

            let payload = Data("[]".utf8)
            do {
                let response = try await adapter.complete(prompt: prompt, payload: payload, config: config)
                print("[AI] Org batch \(index+1) response length: \(response.count)")

                // Robust JSON extraction
                var cleanResponse = response
                if let fenceStart = cleanResponse.range(of: "```") {
                    let after = cleanResponse[fenceStart.upperBound...]
                    if let fenceEnd = after.range(of: "```") {
                        cleanResponse = String(after[after.startIndex..<fenceEnd.lowerBound])
                        if cleanResponse.hasPrefix("json") { cleanResponse = String(cleanResponse.dropFirst(4)) }
                    }
                }

                guard let jsonStart = cleanResponse.firstIndex(of: "["),
                      let jsonEnd = cleanResponse.lastIndex(of: "]"),
                      let data = String(cleanResponse[jsonStart...jsonEnd]).data(using: .utf8) else {
                    print("[AI] Org batch \(index+1): no JSON array found")
                    continue
                }

                // Parse as array of objects
                struct CategoryEntry: Codable {
                    let name: String
                    let bundleID: String?
                    let category: String
                }

                do {
                    let entries = try JSONDecoder().decode([CategoryEntry].self, from: data)
                    for entry in entries {
                        allCategories[entry.name] = entry.category
                        if let bid = entry.bundleID, bid != "unknown" {
                            // Also index by bundleID for stable lookups
                            allCategories[bid] = entry.category
                        }
                    }
                    print("[AI] Org batch \(index+1): parsed \(entries.count) entries")
                } catch {
                    print("[AI] Org batch \(index+1) decode error: \(error)")
                    // Try partial salvage via JSONSerialization
                    if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        for entry in arr {
                            if let name = entry["name"] as? String,
                               let cat = entry["category"] as? String {
                                allCategories[name] = cat
                            }
                        }
                        print("[AI] Org batch \(index+1): partial salvage \(allCategories.count)")
                    }
                }
            } catch {
                print("[AI] Org batch \(index+1) API error: \(error.localizedDescription)")
            }
        }

        aiOrganizationProgress = "分类完成"
        aiCategories = allCategories
        // Build descriptions from collected categories
        for (_, cat) in allCategories {
            if allDescriptions[cat] == nil {
                allDescriptions[cat] = ""
            }
        }
        aiCategoryDescriptions = allDescriptions

        print("[AI] Organization complete: \(allCategories.count) apps classified into \(Set(allCategories.values).count) categories")
        if groupingMode == .byAI {
            rebuildListSections()
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
        // Try natural language / tag-based search
        let nlResults = nlSearch.matchApps(query: searchText, tags: appTags, apps: apps)
        if !nlResults.isEmpty { return nlResults }
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
                // Look up by bundleID first (stable), then by name
                if let bid = app.bundleID, let cat = aiCategories[bid] {
                    return cat
                }
                return aiCategories[app.name] ?? "未分类"
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
