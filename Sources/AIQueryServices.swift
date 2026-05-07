import Foundation

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

    init(mappingStore: SearchMappingStore = SearchMappingStore()) {
        self.mappingStore = mappingStore
        mappingStore.ensureInitialized()
    }

    func matchApps(query: String, tags: [String: [String]], apps: [AppRecord]) -> [AppRecord] {
        let queryLower = query.lowercased()
        let queryTokens = tokenize(queryLower)
        guard !queryTokens.isEmpty else { return [] }

        // Load mappings from store
        let mappings = mappingStore.getMappings()

        // Build expanded terms from mappings
        var expandedTerms = Set(queryTokens)
        var matchedCategories = Set<String>()

        for token in queryTokens {
            for mapping in mappings {
                // Check if token matches category name
                if mapping.category.lowercased().contains(token) || token.contains(mapping.category.lowercased()) {
                    expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                    matchedCategories.insert(mapping.category)
                }

                // Check if token matches any keyword
                for keyword in mapping.keywords {
                    let kwLower = keyword.lowercased()
                    if kwLower.contains(token) || token.contains(kwLower) {
                        expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        matchedCategories.insert(mapping.category)
                        expandedTerms.insert(mapping.category.lowercased())
                    }
                }

                // Check if token matches any app name in mapping
                for appName in mapping.appNames {
                    if appName.lowercased().contains(token) || token.contains(appName.lowercased()) {
                        expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        matchedCategories.insert(mapping.category)
                    }
                }
            }
        }

        print("[Search] Query: '\(query)' -> tokens: \(queryTokens) -> matched categories: \(matchedCategories)")
        print("[Search] Expanded terms: \(expandedTerms)")

        // Score each app by multiple factors
        var scored: [(app: AppRecord, score: Int, reasons: [String])] = []
        for app in apps {
            var score = 0
            var reasons: [String] = []

            // 1. Tag-based matching (highest weight)
            let appTags = (tags[app.name] ?? []).map { $0.lowercased() }
            for tag in appTags {
                for term in expandedTerms {
                    if tag.contains(term) || term.contains(tag) {
                        score += 3
                        reasons.append("tag: \(tag)")
                    }
                }
            }

            // 2. Mapping-based matching (app names and bundleID patterns)
            for mapping in mappings {
                if matchedCategories.contains(mapping.category) {
                    // Check app name in mapping
                    if mapping.appNames.contains(app.name) {
                        score += 5
                        reasons.append("mappingAppName")
                    }

                    // Check bundleID patterns
                    if let bid = app.bundleID {
                        for pattern in mapping.bundleIDPatterns {
                            if bid.contains(pattern) {
                                score += 4
                                reasons.append("bundleID: \(pattern)")
                            }
                        }
                    }
                }
            }

            // 3. Name/bundleID matching
            let nameLower = app.name.lowercased()
            let bundleLower = (app.bundleID ?? "").lowercased()
            for term in expandedTerms {
                if nameLower.contains(term) {
                    score += 2
                    reasons.append("name")
                }
                if bundleLower.contains(term) {
                    score += 2
                    reasons.append("bundleID")
                }
            }

            // 4. Permission-based hints (contextual matching)
            let permissions = app.permissions.requested
            if matchedCategories.contains("沟通") && (permissions.contains(.camera) || permissions.contains(.microphone)) {
                score += 1
                reasons.append("permissionHint: 沟通")
            }
            if matchedCategories.contains("安全") && permissions.contains(.fullDiskAccess) {
                score += 1
                reasons.append("permissionHint: 安全")
            }

            if score > 0 {
                scored.append((app, score, reasons))
            }
        }

        // Sort by score and return
        let results = scored.sorted { $0.score > $1.score }.map(\.app)
        print("[Search] Found \(results.count) apps for '\(query)', top scores: \(scored.prefix(5).map { "\($0.app.name): \($0.score)" })")
        return results
    }

    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                // CJK characters as individual tokens
                if char.unicodeScalars.contains(where: { $0.value > 0x4E00 && $0.value < 0x9FFF }) {
                    tokens.append(String(char))
                }
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
