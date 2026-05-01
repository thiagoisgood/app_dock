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
