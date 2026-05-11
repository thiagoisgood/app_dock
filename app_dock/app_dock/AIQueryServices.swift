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
    private let weights: SearchWeights

    init(
        mappingStore: SearchMappingStore = SearchMappingStore(),
        aliasStore: AppNameAliasStore = AppNameAliasStore(),
        feedbackStore: SearchFeedbackStore? = nil,
        aiCategories: [String: String] = [:],
        weights: SearchWeights = SearchWeights()
    ) {
        self.mappingStore = mappingStore
        self.aliasStore = aliasStore
        self.feedbackStore = feedbackStore
        self.aiCategories = aiCategories
        self.weights = weights
        mappingStore.ensureInitialized()
    }

    // MARK: - 主搜索 API：返回带提示的结果

    func matchAppsWithHints(query: String, tags: [String: [String]], apps: [AppRecord]) -> [SearchResult] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        let queryLower = key.lowercased()

        // 第一层：精确名称匹配（最高优先级）
        if let exact = tryExactNameMatch(query: key, apps: apps) {
            return [exact]
        }

        let queryTokens = tokenize(queryLower)
        guard !queryTokens.isEmpty else { return [] }

        // 意图检测
        let intents = IntentDetector.detectIntents(from: queryLower)

        // 第二层：类别直接匹配
        let categoryResult = tryDirectCategoryMatch(tokens: queryTokens, apps: apps, intents: intents)
        if let results = categoryResult { return results }

        // 第三层：评分模式
        return scoredMatch(tokens: queryTokens, tags: tags, apps: apps, intents: intents, query: key)
    }

    // MARK: - 精确名称匹配（第一层）

    private func tryExactNameMatch(query: String, apps: [AppRecord]) -> SearchResult? {
        let queryLower = query.lowercased()

        // 1. 直接名称匹配（大小写不敏感）
        for app in apps {
            if app.name.lowercased() == queryLower {
                return SearchResult(
                    id: app.id,
                    app: app,
                    hints: [SearchMatchHint(id: "exact", displayText: "精确匹配", color: .green)],
                    score: 1000
                )
            }
        }

        // 2. 名称别名精确匹配（如 "wechat" → "微信"）
        let aliases = aliasStore.aliases(for: query)
        for aliasName in aliases {
            for app in apps {
                if app.name.lowercased() == aliasName.lowercased() {
                    return SearchResult(
                        id: app.id,
                        app: app,
                        hints: [SearchMatchHint(id: "aliasExact", displayText: "精确匹配 (别名)", color: .green)],
                        score: 1000
                    )
                }
            }
        }

        // 3. BundleID 精确匹配
        for app in apps {
            if let bid = app.bundleID, bid.lowercased() == queryLower {
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
            if let cat = SearchAliasRegistry.resolveCategoryAlias(token) {
                matchedCategory = cat
                break
            }
        }

        if matchedCategory == nil {
            let usedCategories = Set(aiCategories.values)
            for token in tokens {
                for cat in usedCategories {
                    if cat.lowercased().contains(token) || token.contains(cat.lowercased()) {
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
            let appCat: String
            if let bid = app.bundleID, let cat = aiCategories[bid] { appCat = cat }
            else if let cat = aiCategories[app.name] { appCat = cat }
            else { continue }
            if appCat == category { categoryApps.append(app) }
        }

        guard !categoryApps.isEmpty else { return nil }

        let filtered = intents.isEmpty ? categoryApps : categoryApps.filter {
            IntentDetector.appMatchesIntents($0, intents: intents)
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

        for token in tokens {
            // 类别别名
            if let cat = SearchAliasRegistry.resolveCategoryAlias(token) {
                matchedCategories.insert(cat)
                if let def = CategorySchema.standard.first(where: { $0.displayName == cat }) {
                    expandedTerms.formUnion(def.keywords.map { $0.lowercased() })
                }
            }
            // Mapping 扩展
            for mapping in mappings {
                let catLower = mapping.category.lowercased()
                if catLower.contains(token) || token.contains(catLower) {
                    expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                    matchedCategories.insert(mapping.category)
                }
                for keyword in mapping.keywords {
                    let kwLower = keyword.lowercased()
                    if kwLower.contains(token) || token.contains(kwLower) {
                        expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        matchedCategories.insert(mapping.category)
                        expandedTerms.insert(catLower)
                    }
                }
                for appName in mapping.appNames {
                    if appName.lowercased().contains(token) || token.contains(appName.lowercased()) {
                        expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        matchedCategories.insert(mapping.category)
                    }
                }
            }
            // 名称别名（AI 生成的中英文映射）
            let nameAliases = aliasStore.aliases(for: token)
            expandedTerms.formUnion(nameAliases.map { $0.lowercased() })
        }

        var scored: [(app: AppRecord, score: Double, hints: [SearchMatchHint])] = []

        for app in apps {
            // 意图硬过滤
            if !intents.isEmpty && !IntentDetector.appMatchesIntents(app, intents: intents) {
                continue
            }

            var score: Double = 0
            var hints: [SearchMatchHint] = []

            // 1. 标签匹配（最高权重）
            let appTags = (tags[app.name] ?? [])
            for tag in appTags {
                let tagLower = tag.lowercased()
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
            let resolvedCat: String?
            if let bid = app.bundleID, let cat = aiCategories[bid] { resolvedCat = cat }
            else if let cat = aiCategories[app.name] { resolvedCat = cat }
            else { resolvedCat = nil }

            if let cat = resolvedCat, matchedCategories.contains(cat) {
                score += weights.mappingWeight
                if !hints.contains(where: { $0.id == "category:\(cat)" }) {
                    hints.append(SearchMatchHint(id: "category:\(cat)", displayText: "匹配类别: \(cat)", color: .blue))
                }
            }

            // 3. Mapping-based matching
            for mapping in mappings where matchedCategories.contains(mapping.category) {
                if mapping.appNames.contains(app.name) {
                    score += weights.mappingWeight * 0.6
                    if !hints.contains(where: { $0.id.starts(with: "mapping:") }) {
                        hints.append(SearchMatchHint(id: "mapping:\(mapping.category)", displayText: "关键词匹配: \(mapping.category)", color: .teal))
                    }
                }
                if let bid = app.bundleID {
                    for pattern in mapping.bundleIDPatterns where bid.contains(pattern) {
                        score += weights.bundleIDWeight * 0.5
                        break
                    }
                }
            }

            // 4. 名称/BundleID 匹配
            let nameLower = app.name.lowercased()
            let bundleLower = (app.bundleID ?? "").lowercased()
            for term in tokens {
                if nameLower.contains(term) {
                    score += weights.nameWeight
                    if nameLower == term {
                        score += weights.exactNameBonus
                    }
                }
                if bundleLower.contains(term) {
                    score += weights.nameWeight * 0.5
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
                    hints.append(SearchMatchHint(id: "intent:bg", displayText: "意图: 后台常驻", color: .orange))
                case .heavyResource:
                    hints.append(SearchMatchHint(id: "intent:heavy", displayText: "意图: 资源消耗大", color: .red))
                case .unsignedHighRisk:
                    hints.append(SearchMatchHint(id: "intent:unsigned", displayText: "意图: 未签名/高风险", color: .red))
                case .hasPermission(let kind):
                    hints.append(SearchMatchHint(id: "intent:perm", displayText: "意图: 含\(kind.rawValue)权限", color: .orange))
                case .isSystem:
                    hints.append(SearchMatchHint(id: "intent:system", displayText: "意图: 系统应用", color: .gray))
                case .isAppStore:
                    hints.append(SearchMatchHint(id: "intent:appstore", displayText: "意图: App Store", color: .green))
                case .isThirdParty:
                    hints.append(SearchMatchHint(id: "intent:third", displayText: "意图: 第三方", color: .orange))
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
        var tokens: [String] = []
        var current = ""
        for char in text {
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
        return tokens
    }
}
