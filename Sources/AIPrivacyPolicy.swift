import Foundation

enum AIPrivacyError: Error, LocalizedError {
    case consentRequired
    case secureEndpointRequired

    var errorDescription: String? {
        switch self {
        case .consentRequired: return "请在设置中确认向该 AI 服务发送应用元数据，并保存设置。"
        case .secureEndpointRequired: return "AI 服务必须使用不含账户、查询参数或片段的 HTTPS 地址。"
        }
    }
}

enum AIPrivacyPolicy {
    static func normalizedEndpoint(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    static func allowsAI(for endpoint: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "ai.metadataSharingAllowed")
            && normalizedEndpoint(defaults.string(forKey: "ai.approvedEndpoint") ?? "") == normalizedEndpoint(endpoint)
    }

    static func validateEndpoint(_ endpoint: String) throws {
        guard let url = URLComponents(string: normalizedEndpoint(endpoint)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AIPrivacyError.secureEndpointRequired
        }
    }

    static func authorize(_ endpoint: String, defaults: UserDefaults = .standard) throws {
        try validateEndpoint(endpoint)
        guard allowsAI(for: endpoint, defaults: defaults) else { throw AIPrivacyError.consentRequired }
    }

    static func saveConsent(_ allowed: Bool, endpoint: String, defaults: UserDefaults = .standard) {
        defaults.set(allowed, forKey: "ai.metadataSharingAllowed")
        if allowed { defaults.set(normalizedEndpoint(endpoint), forKey: "ai.approvedEndpoint") }
        else { defaults.removeObject(forKey: "ai.approvedEndpoint") }
    }

    static func sanitize(_ text: String, apiKey: String = "") -> String {
        var result = text
        if !apiKey.isEmpty { result = result.replacingOccurrences(of: apiKey, with: "[credential removed]") }
        let patterns = [
            (#"(?:/Users/|/home/)[^/\s\"<>]+"#, "/[private home]"),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[email removed]"),
            (#"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b"#, "[credential removed]")
        ]
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}
