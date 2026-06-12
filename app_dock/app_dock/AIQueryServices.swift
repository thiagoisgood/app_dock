import Foundation
import SwiftUI

struct AIProviderConfig: Hashable {
    var apiKey: String
    var baseURL: String
    var model: String
    var temperature: Double
    var maxTokens: Int
}

protocol AIProviderAdapter {
    func complete(prompt: String, payload: Data, config: AIProviderConfig) async throws -> AICompletionResult
}

struct AICompletionResult {
    let content: String
    let promptTokens: Int?
    let completionTokens: Int?
}

struct OpenAICompatibleAdapter: AIProviderAdapter {
    private let session: URLSession = .shared

    func complete(prompt: String, payload: Data, config: AIProviderConfig) async throws -> AICompletionResult {
        return try await complete(
            systemPrompt: PromptTemplates.securityAuditSystemPrompt(),
            userPrompt: prompt,
            payload: payload,
            config: config
        )
    }

    /// 支持自定义系统提示词的完成方法
    func complete(
        systemPrompt: String,
        userPrompt: String,
        payload: Data = Data("[]".utf8),
        config: AIProviderConfig
    ) async throws -> AICompletionResult {
        guard let baseURL = URL(string: config.baseURL) else {
            throw AIProviderError.invalidBaseURL
        }

        let trimmed = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        guard let endpoint = URL(string: "\(trimmed)/chat/completions") else {
            throw AIProviderError.invalidBaseURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let userPayload = String(decoding: payload, as: UTF8.self)
        let userContent = userPayload != "[]" ? "\(userPrompt)\n\n数据:\n\(userPayload)" : userPrompt
        let body = OpenAICompatRequest(
            model: config.model,
            temperature: config.temperature,
            max_tokens: config.maxTokens,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.network("无效响应")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 400:
            throw AIProviderError.badRequest(String(decoding: data, as: UTF8.self))
        case 401, 403:
            throw AIProviderError.unauthorized
        case 429:
            throw AIProviderError.rateLimited
        default:
            throw AIProviderError.serverError(http.statusCode)
        }

        guard let parsed = try? JSONDecoder().decode(OpenAICompatResponse.self, from: data),
              let content = parsed.choices.first?.message.content,
              !content.isEmpty else {
            throw AIProviderError.decodeFailure
        }
        return AICompletionResult(
            content: content,
            promptTokens: parsed.usage?.prompt_tokens,
            completionTokens: parsed.usage?.completion_tokens
        )
    }
}

private struct OpenAICompatRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }
    let model: String
    let temperature: Double
    let max_tokens: Int
    let messages: [Message]
}

private struct OpenAICompatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String?
            let content: String
        }
        let message: Message
    }
    struct Usage: Codable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
    let choices: [Choice]
    let usage: Usage?
}

struct SemanticQueryPlanner {
    func buildFilter(query: String) -> (AppRecord) -> Bool {
        if query.contains("国产") || query.lowercased().contains("china") {
            return { app in
                let team = app.signature.teamID?.lowercased() ?? ""
                return team.contains("cn") || app.name.contains("腾讯") || app.name.contains("阿里")
            }
        }
        if query.contains("后台") || query.contains("常驻") {
            return { $0.permissions.backgroundResident }
        }
        if query.contains("CPU") || query.contains("cpu") {
            return { $0.metrics.cpuPercent > 15 }
        }
        return { _ in true }
    }

    func summarize(_ query: String, apps: [AppRecord]) -> SemanticQueryResult {
        let top = apps.prefix(8).map(\.name)
        return SemanticQueryResult(
            title: "Query Matched \(apps.count) apps",
            summary: "已按语义条件过滤，返回重点应用。",
            appNames: Array(top)
        )
    }
}

struct AIProviderRouter {
    private let planner = SemanticQueryPlanner()
    private let jsonBuilder = SanitizedJsonBuilder()
    private let tokenStore = TokenUsageStore()

    func execute(
        query: String,
        apps: [AppRecord],
        config: AIProviderConfig
    ) async -> (SemanticQueryResult, String) {
        let filtered = apps.filter(planner.buildFilter(query: query))
        let structured = planner.summarize(query, apps: filtered)
        let payload = jsonBuilder.buildPayload(from: filtered, maxBytes: 1024)
        let prompt = "请基于应用元数据解释筛选结果，并给出1条审计建议。"

        let adapter: AIProviderAdapter = OpenAICompatibleAdapter()
        do {
            let result = try await adapter.complete(prompt: prompt, payload: payload, config: config)
            // Record token usage
            if let pt = result.promptTokens, let ct = result.completionTokens {
                tokenStore.recordUsage(
                    operation: "digest",
                    model: config.model,
                    promptTokens: pt,
                    completionTokens: ct
                )
            }
            return (structured, result.content)
        } catch let error as AIProviderError {
            return (structured, "AI 调用失败：\(error.localizedDescription)")
        } catch {
            return (structured, "AI 调用失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - AI Tagging Service

struct AITaggingService {
    private let tokenStore = TokenUsageStore()

    func generateTags(for apps: [AppRecord], config: AIProviderConfig) async throws -> [String: [String]] {
        // Batch apps to avoid exceeding token limits
        let batchSize = 30
        var allTags: [String: [String]] = [:]

        for batchStart in stride(from: 0, to: apps.count, by: batchSize) {
            let batch = Array(apps[batchStart..<min(batchStart + batchSize, apps.count)])
            let appList = batch.map { "- \($0.name) (\($0.bundleID ?? "unknown"))" }.joined(separator: "\n")
            let prompt = """
            请为以下 macOS 应用生成语义标签，每个应用 2-5 个标签。
            标签应描述应用的用途场景，使用中文标签（如"编程"、"设计"、"写作"、"协作"、"娱乐"、"浏览器"、"系统工具"等）。

            重要：返回纯 JSON，不要包含 markdown 代码块标记。格式如下：
            {"应用名": ["标签1", "标签2", ...], ...}

            应用列表：
            \(appList)
            """

            let adapter = OpenAICompatibleAdapter()
            let result = try await adapter.complete(prompt: prompt, payload: Data("[]".utf8), config: config)
            let response = result.content
            print("[AI] Tagging batch \(batchStart/batchSize + 1) response length: \(response.count)")

            // Record token usage
            if let pt = result.promptTokens, let ct = result.completionTokens {
                tokenStore.recordUsage(
                    operation: "tagging",
                    model: config.model,
                    promptTokens: pt,
                    completionTokens: ct
                )
            }

            // Robust JSON extraction: strip code fences if present
            var cleanResponse = response
            if let codeStart = cleanResponse.range(of: "```") {
                let afterFence = cleanResponse[codeStart.upperBound...]
                if let codeEnd = afterFence.range(of: "```") {
                    cleanResponse = String(afterFence[afterFence.startIndex..<codeEnd.lowerBound])
                    // Remove optional "json" language tag
                    if cleanResponse.hasPrefix("json") {
                        cleanResponse = String(cleanResponse.dropFirst(4))
                    }
                }
            }

            guard let start = cleanResponse.firstIndex(of: "{"),
                  let end = cleanResponse.lastIndex(of: "}"),
                  let data = String(cleanResponse[start...end]).data(using: .utf8) else {
                print("[AI] Tagging: no JSON found in response. Prefix: \(response.prefix(150))")
                continue
            }

            do {
                let tags = try JSONDecoder().decode([String: [String]].self, from: data)
                print("[AI] Tagging batch decoded: \(tags.count) apps")
                for (key, value) in tags {
                    allTags[key] = value
                }
            } catch {
                print("[AI] Tagging decode error: \(error)")
                // Try to decode one by one to salvage partial results
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (key, value) in dict {
                        if let tags = value as? [String] {
                            allTags[key] = tags
                        }
                    }
                    print("[AI] Tagging partial salvage: \(allTags.count) apps")
                }
            }
        }

        print("[AI] Tagging complete: \(allTags.count) total apps tagged")
        return allTags
    }
}

// MARK: - Natural Language Search

struct AINaturalLanguageSearch {
    private let mappingStore: SearchMappingStore
    private let aliasStore: AppNameAliasStore
    private let feedbackStore: SearchFeedbackStore?
    private let aiCategories: [String: String]
    private let recentUsageRecords: [String: AppUsageRecord]
    private let weights: SearchWeights
    private let categoryClassifier = AppCategoryClassifier()
    private let riskEngine = PermissionHeuristicsEngine()

    init(
        mappingStore: SearchMappingStore = SearchMappingStore(),
        aliasStore: AppNameAliasStore = AppNameAliasStore(),
        feedbackStore: SearchFeedbackStore? = nil,
        aiCategories: [String: String] = [:],
        recentUsageRecords: [String: AppUsageRecord] = [:],
        weights: SearchWeights = SearchWeights()
    ) {
        self.mappingStore = mappingStore
        self.aliasStore = aliasStore
        self.feedbackStore = feedbackStore
        self.aiCategories = aiCategories
        self.recentUsageRecords = recentUsageRecords
        self.weights = weights
        mappingStore.ensureInitialized()
    }

    // MARK: - 主搜索 API：返回带提示的结果

    func matchAppsWithHints(query: String, tags: [String: [String]], apps: [AppRecord]) -> [SearchResult] {
        LocalAppSearchEngine(
            mappingStore: mappingStore,
            aliasStore: aliasStore,
            feedbackStore: feedbackStore,
            aiCategories: aiCategories,
            recentUsageRecords: recentUsageRecords,
            weights: weights
        )
        .search(query: query, tags: tags, apps: apps)
    }

    // MARK: - 精确名称匹配（第一层）

    private func tryExactNameMatch(query: String, apps: [AppRecord]) -> SearchResult? {
        let queryLower = normalize(query)

        // 1. 直接名称匹配（大小写不敏感）
        for app in apps {
            if normalize(app.name) == queryLower {
                return SearchResult(
                    id: app.id,
                    app: app,
                    hints: [SearchMatchHint(id: "exact", displayText: "精确匹配", color: .green)],
                    score: 1000
                )
            }
        }

        // 2. 名称别名精确匹配（如 "wechat" → "微信"）
        let aliasRecords = aliasStore.matchingAliases(for: query)
        let aliases = aliasRecords.flatMap { [$0.chineseName, $0.englishName] }
        for aliasName in aliases {
            for app in apps {
                if normalize(app.name) == normalize(aliasName) {
                    return SearchResult(
                        id: app.id,
                        app: app,
                        hints: [SearchMatchHint(id: "aliasExact", displayText: "精确匹配 (别名)", color: .green)],
                        score: 1000
                    )
                }
            }
        }

        // 3. 别名 BundleID 精确匹配（如 "微信" → com.tencent.xinWeChat → WeChat）
        for alias in aliasRecords {
            guard let aliasBundleID = alias.bundleID else { continue }
            for app in apps {
                guard let appBundleID = app.bundleID else { continue }
                if normalize(appBundleID) == normalize(aliasBundleID) {
                    return SearchResult(
                        id: app.id,
                        app: app,
                        hints: [SearchMatchHint(id: "aliasBundleExact", displayText: "精确匹配 (中英别名)", color: .green)],
                        score: 1000
                    )
                }
            }
        }

        // 4. BundleID 精确匹配
        for app in apps {
            if let bid = app.bundleID, normalize(bid) == queryLower {
                return SearchResult(
                    id: app.id,
                    app: app,
                    hints: [SearchMatchHint(id: "bundleExact", displayText: "精确匹配 (BundleID)", color: .green)],
                    score: 1000
                )
            }
        }

        return nil
    }

    // MARK: - 类别直接匹配

    private func tryDirectCategoryMatch(tokens: [String], apps: [AppRecord], intents: [IntentFilter]) -> [SearchResult]? {
        var matchedCategory: String? = nil

        for token in tokens {
            if let cat = canonicalCategory(for: token) {
                matchedCategory = cat
                break
            }
        }

        if matchedCategory == nil {
            let usedCategories = Set(apps.map { resolvedCategory(for: $0) })
            for token in tokens {
                for cat in usedCategories {
                    let catLower = normalize(cat)
                    if catLower.contains(token) || token.contains(catLower) {
                        matchedCategory = cat
                        break
                    }
                }
                if matchedCategory != nil { break }
            }
        }

        guard let category = matchedCategory else { return nil }

        var categoryApps: [AppRecord] = []
        for app in apps {
            if resolvedCategory(for: app) == category { categoryApps.append(app) }
        }

        guard !categoryApps.isEmpty else { return nil }

        let filtered = intents.isEmpty ? categoryApps : categoryApps.filter {
            matchesHardIntents($0, intents: intents)
        }

        let hint = SearchMatchHint(id: "category:\(category)", displayText: "匹配类别: \(category)", color: .blue)
        return filtered.map { app in
            SearchResult(id: app.id, app: app, hints: [hint], score: 100)
        }
    }

    // MARK: - 评分匹配

    private func scoredMatch(tokens: [String], tags: [String: [String]], apps: [AppRecord], intents: [IntentFilter], query: String) -> [SearchResult] {
        let mappings = mappingStore.getMappings()
        var expandedTerms = Set(tokens)
        var matchedCategories = Set<String>()
        var matchedMappings: [SearchMapping] = []

        for token in tokens {
            // 类别别名
            if let cat = canonicalCategory(for: token) {
                matchedCategories.insert(cat)
                if let def = CategorySchema.standard.first(where: { $0.displayName == cat }) {
                    expandedTerms.formUnion(def.keywords.map { $0.lowercased() })
                }
            }
            // Mapping 扩展
            for mapping in mappings {
                let canonicalMappingCategory = canonicalCategory(for: mapping.category) ?? mapping.category
                let catLower = normalize(mapping.category)
                if catLower.contains(token) || token.contains(catLower) {
                    expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                    matchedCategories.insert(canonicalMappingCategory)
                    matchedMappings.append(mapping)
                }
                for keyword in mapping.keywords {
                    let kwLower = normalize(keyword)
                    if kwLower.contains(token) || token.contains(kwLower) {
                        expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        matchedCategories.insert(canonicalMappingCategory)
                        expandedTerms.insert(normalize(canonicalMappingCategory))
                        matchedMappings.append(mapping)
                    }
                }
                for appName in mapping.appNames {
                    let appNameLower = normalize(appName)
                    if appNameLower.contains(token) || token.contains(appNameLower) {
                        expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        matchedCategories.insert(canonicalMappingCategory)
                        matchedMappings.append(mapping)
                    }
                }
            }
            // 名称别名（AI 生成的中英文映射）
            let nameAliases = aliasStore.aliases(for: token)
            for alias in nameAliases {
                expandedTerms.insert(normalize(alias))
                expandedTerms.formUnion(tokenize(alias))
            }
        }

        var scored: [(app: AppRecord, score: Double, hints: [SearchMatchHint])] = []

        for app in apps {
            // 意图硬过滤
            if !intents.isEmpty && !matchesHardIntents(app, intents: intents) {
                continue
            }

            var score: Double = 0
            var hints: [SearchMatchHint] = []
            let searchDocument = documentTerms(for: app, tags: tags)

            // 1. 标签匹配（最高权重）
            let appTags = (tags[app.name] ?? [])
            for tag in appTags {
                let tagLower = normalize(tag)
                for term in expandedTerms {
                    if tagLower.contains(term) || term.contains(tagLower) {
                        score += weights.tagWeight
                        let hintID = "tag:\(tag)"
                        if !hints.contains(where: { $0.id == hintID }) {
                            hints.append(SearchMatchHint(id: hintID, displayText: "匹配标签: \(tag)", color: .purple))
                        }
                    }
                }
            }

            // 2. 类别匹配
            let resolvedCat = resolvedCategory(for: app)

            if matchedCategories.contains(resolvedCat) {
                score += weights.mappingWeight
                if !hints.contains(where: { $0.id == "category:\(resolvedCat)" }) {
                    hints.append(SearchMatchHint(id: "category:\(resolvedCat)", displayText: "匹配类别: \(resolvedCat)", color: .blue))
                }
            }

            // 3. Mapping-based matching
            for mapping in dedupeMappings(matchedMappings) {
                if mapping.appNames.contains(where: { normalize($0) == normalize(app.name) }) {
                    score += weights.mappingWeight * 0.6
                    if !hints.contains(where: { $0.id.starts(with: "mapping:") }) {
                        hints.append(SearchMatchHint(id: "mapping:\(mapping.category)", displayText: "语义映射: \(mapping.category)", color: .teal))
                    }
                }
                if let bid = app.bundleID {
                    for pattern in mapping.bundleIDPatterns where normalize(bid).contains(normalize(pattern)) {
                        score += weights.bundleIDWeight * 0.5
                        break
                    }
                }
            }

            // 4. 应用搜索文档匹配：名称、BundleID、路径、分类、来源、签名、权限、标签
            for term in expandedTerms {
                guard term.count >= 2 || term.unicodeScalars.contains(where: { $0.value > 0x4E00 && $0.value < 0x9FFF }) else { continue }
                if searchDocument.exact.contains(term) {
                    score += weights.exactNameBonus
                    addHint(&hints, id: "exactDoc:\(term)", text: "精确命中: \(term)", color: .green)
                } else if searchDocument.strong.contains(where: { $0.contains(term) || term.contains($0) }) {
                    score += weights.nameWeight * 1.6
                    addHint(&hints, id: "nameDoc:\(term)", text: "名称/标识命中", color: .green)
                } else if searchDocument.weak.contains(where: { $0.contains(term) || term.contains($0) }) {
                    score += weights.nameWeight * 0.75
                }
            }

            // 5. 权限提示
            let permissions = app.permissions.requested
            if matchedCategories.contains("沟通协作") && (permissions.contains(.camera) || permissions.contains(.microphone)) {
                score += weights.permissionHintWeight
            }
            if matchedCategories.contains("安全隐私") && permissions.contains(.fullDiskAccess) {
                score += weights.permissionHintWeight
            }

            // 5.5 意图加权
            let intentBoost = softIntentBoost(for: app, intents: intents, hints: &hints)
            score += intentBoost

            // 6. 反馈 boosting
            if let feedbackStore {
                let boost = feedbackStore.boostForApp(app.name, query: query)
                if boost > 0 {
                    score += boost
                    hints.append(SearchMatchHint(id: "feedback", displayText: "学习推荐", color: .teal))
                }
            }

            // 7. 意图提示
            for intent in intents {
                switch intent {
                case .background:
                    addHint(&hints, id: "intent:bg", text: "意图: 后台常驻", color: .orange)
                case .heavyResource:
                    addHint(&hints, id: "intent:heavy", text: "意图: 资源消耗大", color: .red)
                case .risky:
                    addHint(&hints, id: "intent:risky", text: "意图: 风险应用", color: .red)
                case .unsignedHighRisk:
                    addHint(&hints, id: "intent:unsigned", text: "意图: 签名异常", color: .red)
                case .hasPermission(let kind):
                    addHint(&hints, id: "intent:perm:\(kind.rawValue)", text: "意图: 含\(kind.displayLabel)", color: .orange)
                case .isSystem:
                    addHint(&hints, id: "intent:system", text: "意图: 系统应用", color: .gray)
                case .isAppStore:
                    addHint(&hints, id: "intent:appstore", text: "意图: App Store", color: .green)
                case .isThirdParty:
                    addHint(&hints, id: "intent:third", text: "意图: 第三方", color: .orange)
                }
            }

            if score > 0 {
                scored.append((app, score, hints))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .map { SearchResult(id: $0.app.id, app: $0.app, hints: $0.hints, score: Int($0.score)) }
    }

    // MARK: - 向后兼容

    func matchApps(query: String, tags: [String: [String]], apps: [AppRecord]) -> [AppRecord] {
        matchAppsWithHints(query: query, tags: tags, apps: apps).map(\.app)
    }

    // MARK: - 辅助

    private func tokenize(_ text: String) -> [String] {
        let normalized = normalize(text)
        var tokens: [String] = []
        var current = ""
        for char in normalized {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
                if char.unicodeScalars.contains(where: { $0.value > 0x4E00 && $0.value < 0x9FFF }) {
                    tokens.append(String(char))
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        let joinedChinese = tokens.filter { containsChinese($0) }.joined()
        if joinedChinese.count >= 2 {
            tokens.append(joinedChinese)
            tokens.append(contentsOf: chineseNGrams(joinedChinese, lengths: [2, 3, 4]))
        }
        return Array(Set(tokens)).filter { !$0.isEmpty }
    }

    private func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    private func chineseNGrams(_ text: String, lengths: [Int]) -> [String] {
        let chars = Array(text)
        guard chars.count > 1 else { return [] }
        var result: [String] = []
        for length in lengths where chars.count >= length {
            for index in 0...(chars.count - length) {
                result.append(String(chars[index..<index + length]))
            }
        }
        return result
    }

    private func canonicalCategory(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if CategorySchema.standard.contains(where: { $0.displayName == trimmed }) {
            return trimmed
        }
        if let alias = SearchAliasRegistry.resolveCategoryAlias(trimmed) {
            return alias
        }
        let map: [String: String] = [
            "编程": "开发工具",
            "开发": "开发工具",
            "设计": "设计创作",
            "写作": "办公效率",
            "办公": "办公效率",
            "娱乐": "影音娱乐",
            "沟通": "沟通协作",
            "安全": "安全隐私",
            "效率": "办公效率",
            "浏览": "网络浏览",
            "媒体": "影音娱乐",
            "系统": "系统工具",
        ]
        return map[trimmed] ?? map[normalize(trimmed)]
    }

    private func resolvedCategory(for app: AppRecord) -> String {
        if let bid = app.bundleID, let cat = aiCategories[bid] {
            return canonicalCategory(for: cat) ?? cat
        }
        if let cat = aiCategories[app.name] {
            return canonicalCategory(for: cat) ?? cat
        }
        return categoryClassifier.category(for: app).rawValue
    }

    private func documentTerms(for app: AppRecord, tags: [String: [String]]) -> (exact: Set<String>, strong: Set<String>, weak: Set<String>) {
        var exact: Set<String> = [normalize(app.name)]
        if let bid = app.bundleID { exact.insert(normalize(bid)) }

        var strong: Set<String> = exact
        strong.formUnion(tokenize(app.name))
        if let bid = app.bundleID { strong.formUnion(tokenize(bid)) }
        strong.insert(normalize(resolvedCategory(for: app)))
        for alias in aliasStore.aliases(forAppName: app.name, bundleID: app.bundleID) {
            exact.insert(normalize(alias))
            strong.insert(normalize(alias))
            strong.formUnion(tokenize(alias))
        }

        var weak: Set<String> = strong
        weak.insert(normalize(app.source.displayLabel))
        weak.insert(normalize(app.signature.trustLevel.displayLabel))
        weak.formUnion(tokenize(app.path))
        weak.formUnion(app.permissions.requested.flatMap { tokenize($0.displayLabel + " " + $0.rawValue) })
        weak.formUnion((tags[app.name] ?? []).flatMap { tokenize($0) })
        if app.permissions.backgroundResident {
            weak.formUnion(["后台", "常驻", "background", "resident"])
        }
        if app.metrics.cpuPercent >= 5 || app.metrics.memoryMB >= 500 {
            weak.formUnion(["资源", "占用", "高cpu", "高内存", "heavy"])
        }
        if !riskEngine.evaluate(app: app).isEmpty {
            weak.formUnion(["风险", "高风险", "可疑", "不安全", "risky"])
        }
        return (exact, strong, weak)
    }

    private func matchesHardIntents(_ app: AppRecord, intents: [IntentFilter]) -> Bool {
        let hardIntents = intents.filter {
            switch $0 {
            case .isSystem, .isAppStore, .isThirdParty, .hasPermission, .unsignedHighRisk:
                return true
            case .risky, .background, .heavyResource:
                return false
            }
        }
        return IntentDetector.appMatchesIntents(app, intents: hardIntents)
    }

    private func softIntentBoost(for app: AppRecord, intents: [IntentFilter], hints: inout [SearchMatchHint]) -> Double {
        var boost: Double = 0
        let signals = riskEngine.evaluate(app: app)
        for intent in intents {
            switch intent {
            case .risky:
                if !signals.isEmpty || app.signature.trustLevel != .trusted {
                    boost += 8
                    addHint(&hints, id: "soft:risky", text: "风险信号", color: .red)
                }
            case .background:
                if app.permissions.backgroundResident {
                    boost += 5
                    addHint(&hints, id: "soft:bg", text: "后台常驻", color: .orange)
                }
            case .heavyResource:
                if app.metrics.cpuPercent >= 5 || app.metrics.memoryMB >= 500 {
                    boost += 5
                    addHint(&hints, id: "soft:heavy", text: "资源占用", color: .red)
                }
            case .unsignedHighRisk:
                if app.signature.trustLevel != .trusted { boost += 6 }
            case .hasPermission(let kind):
                if app.permissions.requested.contains(kind) { boost += 5 }
            case .isSystem, .isAppStore, .isThirdParty:
                break
            }
        }
        return boost
    }

    private func addHint(_ hints: inout [SearchMatchHint], id: String, text: String, color: Color) {
        if !hints.contains(where: { $0.id == id }) {
            hints.append(SearchMatchHint(id: id, displayText: text, color: color))
        }
    }

    private func dedupeMappings(_ mappings: [SearchMapping]) -> [SearchMapping] {
        var seen = Set<UUID>()
        var result: [SearchMapping] = []
        for mapping in mappings where !seen.contains(mapping.id) {
            seen.insert(mapping.id)
            result.append(mapping)
        }
        return result
    }
}

// MARK: - Local App Search Engine

private struct LocalAppSearchEngine {
    private let mappingStore: SearchMappingStore
    private let aliasStore: AppNameAliasStore
    private let feedbackStore: SearchFeedbackStore?
    private let aiCategories: [String: String]
    private let recentUsageRecords: [String: AppUsageRecord]
    private let weights: SearchWeights
    private let categoryClassifier = AppCategoryClassifier()
    private let riskEngine = PermissionHeuristicsEngine()
    private let config = LocalSearchConfig()

    init(
        mappingStore: SearchMappingStore,
        aliasStore: AppNameAliasStore,
        feedbackStore: SearchFeedbackStore?,
        aiCategories: [String: String],
        recentUsageRecords: [String: AppUsageRecord],
        weights: SearchWeights
    ) {
        self.mappingStore = mappingStore
        self.aliasStore = aliasStore
        self.feedbackStore = feedbackStore
        self.aiCategories = aiCategories
        self.recentUsageRecords = recentUsageRecords
        self.weights = weights
    }

    func search(query rawQuery: String, tags: [String: [String]], apps: [AppRecord]) -> [SearchResult] {
        let query = LocalSearchQuery(raw: rawQuery)
        guard !query.normalized.isEmpty else { return [] }

        let intents = IntentDetector.detectIntents(from: query.normalized)
        let mappings = mappingStore.getMappings()
        var candidates: [LocalSearchCandidate] = []

        for app in apps {
            if !matchesHardIntents(app, intents: intents) {
                continue
            }

            let document = document(for: app, tags: tags, mappings: mappings)
            var candidate = LocalSearchCandidate(app: app)

            for field in document.fields {
                if let match = bestMatch(query: query, field: field) {
                    candidate.add(match, config: config)
                }
            }

            addSemanticMappingScore(
                to: &candidate,
                query: query,
                app: app,
                document: document,
                mappings: mappings
            )

            addIntentScore(to: &candidate, app: app, intents: intents)
            addUsageScore(to: &candidate, app: app)

            if let feedbackStore {
                let boost = feedbackStore.boostForApp(app.name, query: rawQuery) * 25
                if boost > 0 {
                    candidate.score += boost
                    candidate.addHint(id: "feedback", text: "学习推荐", color: Color.teal)
                }
            }

            addPenalties(to: &candidate)

            if candidate.score > 0 {
                candidates.append(candidate)
            }
        }

        let sorted = candidates.sorted(by: candidateSort)
        return applyTop3Guard(sorted)
            .map { SearchResult(id: $0.app.id, app: $0.app, hints: $0.hints, score: Int($0.score.rounded())) }
    }

    private func bestMatch(query: LocalSearchQuery, field: LocalSearchField) -> LocalFieldMatch? {
        let value = normalize(field.value)
        let compactValue = compactText(value)
        guard !value.isEmpty else { return nil }

        var best: LocalFieldMatch?

        if value == query.normalized || compactValue == query.compact {
            best = LocalFieldMatch(level: .exact, field: field, quality: 1.0, baseScore: config.exactScore)
        }

        if value.hasPrefix(query.normalized) || compactValue.hasPrefix(query.compact) {
            let quality = prefixQuality(queryLength: query.compact.count, valueLength: max(compactValue.count, 1))
            best = maxMatch(best, LocalFieldMatch(level: .prefix, field: field, quality: quality, baseScore: config.prefixScore))
        } else if field.tokens.contains(where: { $0.hasPrefix(query.normalized) || compactText($0).hasPrefix(query.compact) }) {
            best = maxMatch(best, LocalFieldMatch(level: .prefix, field: field, quality: 0.86, baseScore: config.prefixScore))
        }

        let tokenScore = tokenMatchQuality(query: query, field: field)
        if tokenScore > 0 {
            best = maxMatch(best, LocalFieldMatch(level: .token, field: field, quality: tokenScore, baseScore: config.tokenScore))
        }

        if let fuzzy = fuzzyMatchQuality(query: query, field: field), fuzzy > 0 {
            best = maxMatch(best, LocalFieldMatch(level: .fuzzy, field: field, quality: fuzzy, baseScore: config.fuzzyScore))
        }

        return best
    }

    private func maxMatch(_ lhs: LocalFieldMatch?, _ rhs: LocalFieldMatch) -> LocalFieldMatch {
        guard let lhs else { return rhs }
        return rhs.weightedScore(config: config) > lhs.weightedScore(config: config) ? rhs : lhs
    }

    private func tokenMatchQuality(query: LocalSearchQuery, field: LocalSearchField) -> Double {
        guard !query.tokens.isEmpty else { return 0 }
        let value = normalize(field.value)
        let fieldTokens = Set(field.tokens)
        var score: Double = 0

        for token in query.tokens {
            if token.count <= 1 && !containsChinese(token) { continue }
            if fieldTokens.contains(token) {
                score += 1.0
            } else if fieldTokens.contains(where: { $0.hasPrefix(token) }) {
                score += 0.82
            } else if value.contains(token) {
                score += 0.62
            }
        }

        let usableTokenCount = query.tokens.filter { $0.count > 1 || containsChinese($0) }.count
        guard usableTokenCount > 0 else { return 0 }
        let coverage = score / Double(usableTokenCount)
        return coverage >= 0.5 ? min(1.0, coverage) : 0
    }

    private func fuzzyMatchQuality(query: LocalSearchQuery, field: LocalSearchField) -> Double? {
        guard query.compact.count >= 2 else { return nil }

        var best: Double = 0
        let candidates = fuzzyCandidates(for: field)

        for candidate in candidates {
            let normalizedCandidate = compactText(normalize(candidate))
            guard !normalizedCandidate.isEmpty else { continue }

            if let ordered = orderedCharacterScore(query: query.compact, candidate: normalizedCandidate) {
                best = max(best, ordered)
            }

            if levenshteinAllowed(query.compact, normalizedCandidate) {
                best = max(best, query.compact.count <= 4 ? 0.70 : 0.78)
            }
        }

        return best >= 0.58 ? min(best, 1.0) : nil
    }

    private func fuzzyCandidates(for field: LocalSearchField) -> [String] {
        var values = [field.value]
        values.append(contentsOf: field.tokens)
        values.append(acronym(for: field.value))
        values.append(camelCaseAcronym(for: field.originalValue))

        let pinyin = pinyinForms(for: field.value)
        values.append(contentsOf: pinyin)

        if field.kind == .path || field.kind == .pathBasename {
            values.append(contentsOf: pathSegments(field.originalValue))
        }

        return values.deduplicated().filter { !$0.isEmpty }
    }

    private func orderedCharacterScore(query: String, candidate: String) -> Double? {
        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        var positions: [Int] = []
        var cursor = 0

        for queryChar in queryChars {
            var found: Int?
            while cursor < candidateChars.count {
                if candidateChars[cursor] == queryChar {
                    found = cursor
                    cursor += 1
                    break
                }
                cursor += 1
            }
            guard let found else { return nil }
            positions.append(found)
        }

        guard let first = positions.first else { return nil }
        let gaps = zip(positions, positions.dropFirst()).map { $1 - $0 - 1 }
        let totalGap = gaps.reduce(0, +)
        let longestRun = longestConsecutiveRun(positions)

        var score = 0.35
        score += min(0.20, Double(max(0, longestRun - 1)) * 0.06)
        if first == 0 {
            score += 0.08
        } else if first <= 3 {
            score += 0.04
        } else if first > 10 {
            score -= 0.04
        }

        if totalGap <= 2 {
            score += 0.08
        } else if totalGap <= 5 {
            score += 0.04
        } else if totalGap > 10 {
            score -= 0.08
        }

        if candidate.hasPrefix(query) {
            score += 0.20
        }

        if acronym(for: candidate) == query || camelCaseAcronym(for: candidate) == query {
            score += 0.15
        }

        return max(0, min(1, score))
    }

    private func addSemanticMappingScore(
        to candidate: inout LocalSearchCandidate,
        query: LocalSearchQuery,
        app: AppRecord,
        document: LocalSearchDocument,
        mappings: [SearchMapping]
    ) {
        let category = resolvedCategory(for: app)
        let normalizedCategory = normalize(category)
        var bestScore: Double = 0
        var matchedLabel: String?

        for token in query.tokens {
            if let canonical = canonicalCategory(for: token), canonical == category {
                bestScore = max(bestScore, config.semanticScore * 0.95)
                matchedLabel = category
            }
            if normalizedCategory.contains(token) || token.contains(normalizedCategory) {
                bestScore = max(bestScore, config.semanticScore * 0.88)
                matchedLabel = category
            }
        }

        for mapping in mappings {
            let mappingCategory = canonicalCategory(for: mapping.category) ?? mapping.category
            let appliesToApp =
                mappingCategory == category ||
                mapping.appNames.contains(where: { normalize($0) == normalize(app.name) }) ||
                app.bundleID.map { bundleID in
                    mapping.bundleIDPatterns.contains { normalize(bundleID).contains(normalize($0)) }
                } ?? false

            guard appliesToApp else { continue }

            for token in query.tokens {
                if mapping.keywords.contains(where: { keyword in
                    let normalizedKeyword = normalize(keyword)
                    return normalizedKeyword == token || normalizedKeyword.contains(token) || token.contains(normalizedKeyword)
                }) {
                    bestScore = max(bestScore, config.semanticScore * max(0.6, mapping.confidence))
                    matchedLabel = mappingCategory
                }
            }
        }

        guard bestScore > 0 else { return }
        candidate.score += bestScore
        candidate.semanticOnly = candidate.bestLevel == nil
        candidate.bestLevel = max(candidate.bestLevel ?? .semantic, .semantic)
        candidate.addHint(id: "semantic:\(matchedLabel ?? document.category)", text: "语义补充: \(matchedLabel ?? document.category)", color: .teal)
    }

    private func addIntentScore(to candidate: inout LocalSearchCandidate, app: AppRecord, intents: [IntentFilter]) {
        let signals = riskEngine.evaluate(app: app)

        for intent in intents {
            switch intent {
            case .risky:
                if !signals.isEmpty || app.signature.trustLevel != .trusted {
                    candidate.score += 80
                    candidate.addHint(id: "intent:risky", text: "风险信号", color: .red)
                }
            case .background:
                if app.permissions.backgroundResident {
                    candidate.score += 70
                    candidate.addHint(id: "intent:bg", text: "后台常驻", color: .orange)
                }
            case .heavyResource:
                if app.metrics.cpuPercent >= 5 || app.metrics.memoryMB >= 500 {
                    candidate.score += 65
                    candidate.addHint(id: "intent:heavy", text: "资源占用", color: .red)
                }
            case .unsignedHighRisk:
                if app.signature.trustLevel != .trusted {
                    candidate.score += 65
                    candidate.addHint(id: "intent:unsigned", text: "签名异常", color: .red)
                }
            case .hasPermission(let kind):
                if app.permissions.requested.contains(kind) {
                    candidate.score += 60
                    candidate.addHint(id: "intent:perm:\(kind.rawValue)", text: "含\(kind.displayLabel)", color: .orange)
                }
            case .isSystem:
                if app.source == .system { candidate.score += 45 }
            case .isAppStore:
                if app.source == .appStore { candidate.score += 45 }
            case .isThirdParty:
                if app.source == .thirdParty { candidate.score += 45 }
            }
        }
    }

    private func addUsageScore(to candidate: inout LocalSearchCandidate, app: AppRecord) {
        guard let usage = recentUsageRecords[app.name] else { return }

        let hours = Date().timeIntervalSince(usage.lastOpenedAt) / 3600
        let recency: Double
        if hours <= 1 {
            recency = 180
        } else if hours <= 24 {
            recency = 140
        } else if hours <= 24 * 7 {
            recency = 90
        } else if hours <= 24 * 30 {
            recency = 45
        } else {
            recency = 10
        }

        let frequency = min(120, 30 * log2(1 + Double(usage.openCount)))
        candidate.score += recency + frequency

        if hours <= 24 * 7 && usage.openCount >= 3 && candidate.isKeywordStrong {
            candidate.protectRecentFrequent = true
            candidate.addHint(id: "usage:recent", text: "最近常用", color: .teal)
        }
    }

    private func addPenalties(to candidate: inout LocalSearchCandidate) {
        if candidate.semanticOnly {
            candidate.score -= config.semanticOnlyPenalty
        }
        if candidate.contentOnly {
            candidate.score -= config.contentOnlyPenalty
        }
        if candidate.app.path.contains("/System/") && candidate.bestLevel == .semantic {
            candidate.score -= 40
        }
    }

    private func applyTop3Guard(_ sorted: [LocalSearchCandidate]) -> [LocalSearchCandidate] {
        var protected: [LocalSearchCandidate] = []
        var used = Set<UUID>()

        appendProtected(from: sorted, to: &protected, used: &used) { $0.protectExactTitleAlias }
        appendProtected(from: sorted, to: &protected, used: &used) { $0.protectPrefixTitleAlias }
        appendProtected(from: sorted, to: &protected, used: &used) { $0.protectRecentFrequent }

        let keywordStrongCount = sorted.filter { !$0.semanticOnly && $0.isKeywordStrong }.count
        var rest: [LocalSearchCandidate] = []
        var delayedSemantic: [LocalSearchCandidate] = []

        for candidate in sorted where !used.contains(candidate.app.id) {
            if candidate.semanticOnly && keywordStrongCount >= 3 && protected.count < 3 {
                delayedSemantic.append(candidate)
            } else {
                rest.append(candidate)
            }
        }

        return (protected + rest + delayedSemantic)
    }

    private func appendProtected(
        from sorted: [LocalSearchCandidate],
        to protected: inout [LocalSearchCandidate],
        used: inout Set<UUID>,
        where shouldProtect: (LocalSearchCandidate) -> Bool
    ) {
        guard protected.count < 3 else { return }
        guard let candidate = sorted.first(where: { shouldProtect($0) && !used.contains($0.app.id) }) else { return }
        protected.append(candidate)
        used.insert(candidate.app.id)
    }

    private func candidateSort(_ lhs: LocalSearchCandidate, _ rhs: LocalSearchCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.app.name.localizedStandardCompare(rhs.app.name) == .orderedAscending
    }

    private func document(for app: AppRecord, tags: [String: [String]], mappings: [SearchMapping]) -> LocalSearchDocument {
        let category = resolvedCategory(for: app)
        let appTags = tags[app.name] ?? []
        let aliases = aliasStore.aliases(forAppName: app.name, bundleID: app.bundleID)
        let basename = (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let segments = pathSegments(app.path)
        let permissions = app.permissions.requested.map { "\($0.displayLabel) \($0.rawValue)" }
        let source = app.source.displayLabel
        let signature = app.signature.trustLevel.displayLabel
        let bundleID = app.bundleID ?? ""

        var summaryParts = [category, source, signature]
        if app.permissions.backgroundResident { summaryParts.append("后台 常驻 background resident") }
        if app.metrics.cpuPercent >= 5 { summaryParts.append("高CPU 资源占用") }
        if app.metrics.memoryMB >= 500 { summaryParts.append("高内存 资源占用") }
        if !riskEngine.evaluate(app: app).isEmpty { summaryParts.append("风险 高风险 可疑") }

        var contentParts = [bundleID, app.path]
        contentParts.append(contentsOf: permissions)
        contentParts.append(contentsOf: mappingsFor(app: app, category: category, mappings: mappings))

        var fields: [LocalSearchField] = []
        fields.append(LocalSearchField(kind: .title, value: app.name))
        fields.append(contentsOf: aliases.map { LocalSearchField(kind: .alias, value: $0) })
        fields.append(contentsOf: appTags.map { LocalSearchField(kind: .tag, value: $0) })
        if !bundleID.isEmpty {
            fields.append(LocalSearchField(kind: .bundleID, value: bundleID))
        }
        fields.append(LocalSearchField(kind: .pathBasename, value: basename, originalValue: basename))
        fields.append(contentsOf: segments.map { LocalSearchField(kind: .path, value: $0, originalValue: app.path) })
        fields.append(LocalSearchField(kind: .summary, value: summaryParts.joined(separator: " ")))
        fields.append(LocalSearchField(kind: .content, value: contentParts.joined(separator: " ")))

        return LocalSearchDocument(category: category, fields: fields)
    }

    private func mappingsFor(app: AppRecord, category: String, mappings: [SearchMapping]) -> [String] {
        mappings.compactMap { mapping in
            let mappingCategory = canonicalCategory(for: mapping.category) ?? mapping.category
            let appNameMatched = mapping.appNames.contains { normalize($0) == normalize(app.name) }
            let bundleMatched = app.bundleID.map { bundleID in
                mapping.bundleIDPatterns.contains { normalize(bundleID).contains(normalize($0)) }
            } ?? false
            return (mappingCategory == category || appNameMatched || bundleMatched) ? mapping.keywords.joined(separator: " ") : nil
        }
    }

    private func matchesHardIntents(_ app: AppRecord, intents: [IntentFilter]) -> Bool {
        let hardIntents = intents.filter {
            switch $0 {
            case .isSystem, .isAppStore, .isThirdParty, .hasPermission, .unsignedHighRisk:
                return true
            case .risky, .background, .heavyResource:
                return false
            }
        }
        return IntentDetector.appMatchesIntents(app, intents: hardIntents)
    }

    private func resolvedCategory(for app: AppRecord) -> String {
        if let bid = app.bundleID, let cat = aiCategories[bid] {
            return canonicalCategory(for: cat) ?? cat
        }
        if let cat = aiCategories[app.name] {
            return canonicalCategory(for: cat) ?? cat
        }
        return categoryClassifier.category(for: app).rawValue
    }

    private func canonicalCategory(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if CategorySchema.standard.contains(where: { $0.displayName == trimmed }) {
            return trimmed
        }
        if let alias = SearchAliasRegistry.resolveCategoryAlias(trimmed) {
            return alias
        }
        let map: [String: String] = [
            "编程": "开发工具",
            "开发": "开发工具",
            "设计": "设计创作",
            "写作": "办公效率",
            "办公": "办公效率",
            "娱乐": "影音娱乐",
            "沟通": "沟通协作",
            "安全": "安全隐私",
            "效率": "办公效率",
            "浏览": "网络浏览",
            "媒体": "影音娱乐",
            "系统": "系统工具",
        ]
        return map[trimmed] ?? map[normalize(trimmed)]
    }
}

private struct LocalSearchConfig {
    let exactScore: Double = 1000
    let prefixScore: Double = 800
    let tokenScore: Double = 500
    let fuzzyScore: Double = 300
    let semanticScore: Double = 120
    let exactBoost: Double = 250
    let aliasExactBoost: Double = 220
    let tagExactBoost: Double = 180
    let basenameExactBoost: Double = 160
    let semanticOnlyPenalty: Double = 20
    let contentOnlyPenalty: Double = 120
}

private enum LocalSearchLevel: Int, Comparable {
    case semantic = 1
    case fuzzy = 2
    case token = 3
    case prefix = 4
    case exact = 5

    static func < (lhs: LocalSearchLevel, rhs: LocalSearchLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private enum LocalSearchFieldKind {
    case title
    case alias
    case tag
    case bundleID
    case pathBasename
    case path
    case summary
    case content

    var weight: Double {
        switch self {
        case .title: return 1.00
        case .alias: return 0.95
        case .tag: return 0.85
        case .bundleID: return 0.90
        case .pathBasename: return 0.80
        case .path: return 0.60
        case .summary: return 0.45
        case .content: return 0.20
        }
    }

    var hintColor: Color {
        switch self {
        case .title, .alias, .bundleID, .pathBasename: return .green
        case .tag: return .purple
        case .path: return .blue
        case .summary: return .teal
        case .content: return .gray
        }
    }

    var hintLabel: String {
        switch self {
        case .title: return "标题"
        case .alias: return "别名"
        case .tag: return "标签"
        case .bundleID: return "BundleID"
        case .pathBasename: return "文件名"
        case .path: return "路径"
        case .summary: return "摘要"
        case .content: return "详情"
        }
    }
}

private struct LocalSearchQuery {
    let raw: String
    let normalized: String
    let compact: String
    let tokens: [String]

    init(raw: String) {
        self.raw = raw
        self.normalized = normalize(raw)
        self.compact = compactText(self.normalized)
        self.tokens = tokenize(self.normalized)
    }
}

private struct LocalSearchField {
    let kind: LocalSearchFieldKind
    let value: String
    let originalValue: String
    let tokens: [String]

    init(kind: LocalSearchFieldKind, value: String, originalValue: String? = nil) {
        self.kind = kind
        self.value = value
        self.originalValue = originalValue ?? value
        self.tokens = tokenize(value)
    }
}

private struct LocalSearchDocument {
    let category: String
    let fields: [LocalSearchField]
}

private struct LocalFieldMatch {
    let level: LocalSearchLevel
    let field: LocalSearchField
    let quality: Double
    let baseScore: Double

    func weightedScore(config: LocalSearchConfig) -> Double {
        var score = baseScore * quality * field.kind.weight
        if level == .exact {
            switch field.kind {
            case .title:
                score += config.exactBoost
            case .alias:
                score += config.aliasExactBoost
            case .tag:
                score += config.tagExactBoost
            case .bundleID:
                score += config.aliasExactBoost
            case .pathBasename:
                score += config.basenameExactBoost
            case .path, .summary, .content:
                break
            }
        }

        if level == .prefix || level == .exact {
            let start = compactText(normalize(field.value)).range(of: compactText(normalize(field.value)))?.lowerBound
            if start != nil { score += 20 }
        }

        return score
    }

    var hintText: String {
        switch level {
        case .exact: return "精确命中: \(field.kind.hintLabel)"
        case .prefix: return "前缀命中: \(field.kind.hintLabel)"
        case .token: return "关键词命中: \(field.kind.hintLabel)"
        case .fuzzy: return "模糊命中: \(field.kind.hintLabel)"
        case .semantic: return "语义补充"
        }
    }
}

private struct LocalSearchCandidate {
    let app: AppRecord
    var score: Double = 0
    var hints: [SearchMatchHint] = []
    var bestLevel: LocalSearchLevel?
    var protectExactTitleAlias = false
    var protectPrefixTitleAlias = false
    var protectRecentFrequent = false
    var semanticOnly = false
    var contentOnly = false
    private var matchedFieldKinds = Set<String>()

    init(app: AppRecord) {
        self.app = app
    }

    var isKeywordStrong: Bool {
        guard let bestLevel else { return false }
        return bestLevel >= .token
    }

    mutating func add(_ match: LocalFieldMatch, config: LocalSearchConfig) {
        score += match.weightedScore(config: config)
        bestLevel = max(bestLevel ?? match.level, match.level)
        addHint(id: "\(match.level):\(match.field.kind):\(match.field.value)", text: match.hintText, color: match.field.kind.hintColor)

        if match.level == .exact && match.field.kind == .title {
            addHint(id: "exact", text: "精确匹配", color: .green)
        }
        if match.level == .exact && match.field.kind == .alias {
            addHint(id: "aliasExact", text: "精确匹配 (别名)", color: .green)
            addHint(id: "aliasBundleExact", text: "精确匹配 (中英别名)", color: .green)
        }
        if match.level == .exact && match.field.kind == .bundleID {
            addHint(id: "bundleExact", text: "精确匹配 (BundleID)", color: .green)
        }

        if match.level == .exact && (match.field.kind == .title || match.field.kind == .alias || match.field.kind == .bundleID) {
            protectExactTitleAlias = true
        }
        if match.level == .prefix && (match.field.kind == .title || match.field.kind == .alias || match.field.kind == .bundleID) {
            protectPrefixTitleAlias = true
        }

        matchedFieldKinds.insert(String(describing: match.field.kind))
        contentOnly = matchedFieldKinds == Set([String(describing: LocalSearchFieldKind.content)])
        semanticOnly = false
    }

    mutating func addHint(id: String, text: String, color: Color) {
        if !hints.contains(where: { $0.id == id }) {
            hints.append(SearchMatchHint(id: id, displayText: text, color: color))
        }
    }
}

private func normalize(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: ".", with: " ")
        .replacingOccurrences(of: "/", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func compactText(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
}

private func tokenize(_ text: String) -> [String] {
    let normalized = normalize(text)
    var tokens: [String] = []
    var current = ""

    for char in normalized {
        if char.isLetter || char.isNumber {
            current.append(char)
        } else {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            if containsChinese(String(char)) {
                tokens.append(String(char))
            }
        }
    }
    if !current.isEmpty { tokens.append(current) }

    let chinese = tokens.filter(containsChinese).joined()
    if chinese.count >= 2 {
        tokens.append(chinese)
        tokens.append(contentsOf: chineseNGrams(chinese, lengths: [2, 3, 4]))
    }

    tokens.append(contentsOf: splitCamelCase(normalized))
    return tokens.deduplicated().filter { !$0.isEmpty }
}

private func containsChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
}

private func chineseNGrams(_ text: String, lengths: [Int]) -> [String] {
    let chars = Array(text)
    guard chars.count > 1 else { return [] }
    var result: [String] = []
    for length in lengths where chars.count >= length {
        for index in 0...(chars.count - length) {
            result.append(String(chars[index..<index + length]))
        }
    }
    return result
}

private func splitCamelCase(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var previousWasLowercase = false

    for char in text {
        if char.isUppercase && previousWasLowercase && !current.isEmpty {
            result.append(current.lowercased())
            current = ""
        }
        if char.isLetter || char.isNumber {
            current.append(char)
        } else if !current.isEmpty {
            result.append(current.lowercased())
            current = ""
        }
        previousWasLowercase = char.isLowercase
    }

    if !current.isEmpty {
        result.append(current.lowercased())
    }
    return result
}

private func acronym(for text: String) -> String {
    tokenize(text)
        .compactMap(\.first)
        .map(String.init)
        .joined()
}

private func camelCaseAcronym(for text: String) -> String {
    text.filter { $0.isUppercase }
        .map { String($0).lowercased() }
        .joined()
}

private func pathSegments(_ path: String) -> [String] {
    path.split(separator: "/")
        .map(String.init)
        .map { $0.replacingOccurrences(of: ".app", with: "") }
        .filter { !$0.isEmpty }
}

private func pinyinForms(for text: String) -> [String] {
    guard containsChinese(text) else { return [] }
    let mutable = NSMutableString(string: text) as CFMutableString
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
    let full = normalize(mutable as String)
    let initials = full
        .split(separator: " ")
        .compactMap(\.first)
        .map(String.init)
        .joined()
    return [full, initials].filter { !$0.isEmpty }
}

private func prefixQuality(queryLength: Int, valueLength: Int) -> Double {
    guard valueLength > 0 else { return 0 }
    let ratio = Double(queryLength) / Double(valueLength)
    return max(0.72, min(1.0, 0.72 + ratio))
}

private func longestConsecutiveRun(_ positions: [Int]) -> Int {
    guard !positions.isEmpty else { return 0 }
    var best = 1
    var current = 1
    for pair in zip(positions, positions.dropFirst()) {
        if pair.1 == pair.0 + 1 {
            current += 1
            best = max(best, current)
        } else {
            current = 1
        }
    }
    return best
}

private func levenshteinAllowed(_ query: String, _ candidate: String) -> Bool {
    let minLength = min(query.count, candidate.count)
    guard query.count >= 4, minLength >= query.count - 1 else { return false }
    let distance = levenshteinDistance(query, String(candidate.prefix(max(query.count + 1, query.count))))
    if query.count >= 7 { return distance <= 2 }
    return distance <= 1
}

private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs)
    let b = Array(rhs)
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }

    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)

    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + cost
            )
        }
        previous = current
    }

    return previous[b.count]
}

private extension Array {
    func deduplicated<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        var result: [Element] = []
        for element in self {
            let k = key(element)
            if !seen.contains(k) {
                seen.insert(k)
                result.append(element)
            }
        }
        return result
    }
}

private extension Array where Element: Hashable {
    func deduplicated() -> [Element] {
        deduplicated { $0 }
    }
}
