import Foundation

struct AIProviderConfig: Hashable {
    var apiKey: String
    var baseURL: String
    var model: String
    var temperature: Double
    var maxTokens: Int
}

protocol AIProviderAdapter {
    func complete(prompt: String, payload: Data, config: AIProviderConfig) async throws -> String
}

struct OpenAICompatibleAdapter: AIProviderAdapter {
    private let session: URLSession = .shared

    func complete(prompt: String, payload: Data, config: AIProviderConfig) async throws -> String {
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
        request.timeoutInterval = 30

        let userPayload = String(decoding: payload, as: UTF8.self)
        let body = OpenAICompatRequest(
            model: config.model,
            temperature: config.temperature,
            max_tokens: config.maxTokens,
            messages: [
                .init(role: "system", content: "你是 macOS 应用安全审计助手，回答要简洁可执行。"),
                .init(role: "user", content: "\(prompt)\n\n数据:\n\(userPayload)")
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
        return content
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
    let choices: [Choice]
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
            let response = try await adapter.complete(prompt: prompt, payload: payload, config: config)
            return (structured, response)
        } catch let error as AIProviderError {
            return (structured, "AI 调用失败：\(error.localizedDescription)")
        } catch {
            return (structured, "AI 调用失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - AI Tagging Service

struct AITaggingService {
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
            let response = try await adapter.complete(prompt: prompt, payload: Data("[]".utf8), config: config)
            print("[AI] Tagging batch \(batchStart/batchSize + 1) response length: \(response.count)")

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
    private let synonymMap: [String: [String]] = [
        "编程": ["代码", "开发", "IDE", "编辑器", "终端", "git", "docker", "编译", "debug", "xcode", "cursor", "vscode", "code"],
        "设计": ["UI", "UX", "绘图", "原型", "插画", "图形", "色彩", "figma", "sketch", "photoshop"],
        "写作": ["文档", "笔记", "文本", "markdown", "文字处理", "notion", "obsidian"],
        "办公": ["表格", "幻灯片", "演示", "日历", "邮件", "会议", "excel", "word", "powerpoint"],
        "娱乐": ["游戏", "音乐", "视频", "播放", "流媒体", "steam", "spotify", "vlc"],
        "沟通": ["聊天", "消息", "通话", "社交", "微信", "slack", "discord", "zoom"],
        "安全": ["密码", "加密", "VPN", "杀毒", "防火墙"],
        "效率": ["启动器", "快捷键", "自动化", "剪贴板", "任务管理", "alfred", "raycast"],
        "浏览": ["浏览器", "网页", "下载", "safari", "chrome", "firefox"],
        "媒体": ["图片", "照片", "视频编辑", "音频", "录屏"],
        "系统": ["设置", "清理", "监控", "管理", "活动监视器", "finder"],
    ]

    func matchApps(query: String, tags: [String: [String]], apps: [AppRecord]) -> [AppRecord] {
        let queryLower = query.lowercased()
        let queryTokens = tokenize(queryLower)
        guard !queryTokens.isEmpty else { return [] }

        // Expand query with synonyms
        var expandedTerms = Set(queryTokens)
        for token in queryTokens {
            for (key, synonyms) in synonymMap {
                if key.contains(token) || token.contains(key) {
                    expandedTerms.formUnion(synonyms.map { $0.lowercased() })
                    expandedTerms.insert(key)
                }
                for syn in synonyms {
                    if syn.lowercased().contains(token) || token.contains(syn.lowercased()) {
                        expandedTerms.insert(key)
                        expandedTerms.formUnion(synonyms.map { $0.lowercased() })
                    }
                }
            }
        }

        print("[Search] Query: '\(query)' -> tokens: \(queryTokens) -> expanded: \(expandedTerms)")

        // Score each app by tag match AND name/bundleID match
        var scored: [(app: AppRecord, score: Int)] = []
        for app in apps {
            var score = 0

            // Tag-based matching
            let appTags = (tags[app.name] ?? []).map { $0.lowercased() }
            for tag in appTags {
                for term in expandedTerms {
                    if tag.contains(term) || term.contains(tag) {
                        score += 2  // Tags get higher weight
                    }
                }
            }

            // Name/bundleID matching (fallback when no tags)
            let nameLower = app.name.lowercased()
            let bundleLower = (app.bundleID ?? "").lowercased()
            for term in expandedTerms {
                if nameLower.contains(term) || bundleLower.contains(term) {
                    score += 1
                }
            }

            if score > 0 {
                scored.append((app, score))
            }
        }

        let results = scored.sorted { $0.score > $1.score }.map(\.app)
        print("[Search] Found \(results.count) apps for '\(query)'")
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
