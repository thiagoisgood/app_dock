import Foundation

/// 统一的 AI 响应 JSON 解析器
/// 替代分布在 DashboardViewModel、AIQueryServices、SearchMappingStore 中的 5 处重复代码
enum JSONResponseParser {

    enum ParseError: Error, LocalizedError {
        case noJSONArray
        case noJSONObject
        case decodeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noJSONArray: return "响应中未找到 JSON 数组"
            case .noJSONObject: return "响应中未找到 JSON 对象"
            case .decodeFailed(let err): return "JSON 解析失败: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - 数组提取

    static func extractArray<T: Decodable>(_ response: String, type: T.Type) throws -> [T] {
        let cleaned = stripMarkdownFences(response)
        guard let jsonStr = findJSONArray(cleaned) else {
            throw ParseError.noJSONArray
        }
        return try JSONDecoder().decode([T].self, from: Data(jsonStr.utf8))
    }

    static func extractArrayRaw(_ response: String) throws -> [[String: Any]] {
        let cleaned = stripMarkdownFences(response)
        guard let jsonStr = findJSONArray(cleaned),
              let data = jsonStr.data(using: .utf8),
              let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ParseError.noJSONArray
        }
        return arr
    }

    // MARK: - 对象提取

    static func extractObject<T: Decodable>(_ response: String, type: T.Type) throws -> T {
        let cleaned = stripMarkdownFences(response)
        guard let jsonStr = findJSONObject(cleaned) else {
            throw ParseError.noJSONObject
        }
        return try JSONDecoder().decode(T.self, from: Data(jsonStr.utf8))
    }

    static func extractObjectRaw(_ response: String) throws -> [String: Any] {
        let cleaned = stripMarkdownFences(response)
        guard let jsonStr = findJSONObject(cleaned),
              let data = jsonStr.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.noJSONObject
        }
        return dict
    }

    // MARK: - 部分恢复

    static func salvageArrayOfDictionaries(_ rawData: Data) -> [[String: Any]] {
        guard let arr = try? JSONSerialization.jsonObject(with: rawData) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    static func salvageStringDict(_ rawData: Data) -> [String: [String]] {
        guard let dict = try? JSONSerialization.jsonObject(with: rawData) as? [String: [String]] else {
            return [:]
        }
        return dict
    }

    // MARK: - Private

    private static func stripMarkdownFences(_ text: String) -> String {
        guard let start = text.range(of: "```") else { return text }
        let after = text[start.upperBound...]
        guard let end = after.range(of: "```") else { return text }
        var content = String(after[after.startIndex..<end.lowerBound])
        if content.hasPrefix("json") {
            content = String(content.dropFirst(4))
        }
        return content
    }

    private static func findJSONArray(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "["),
              let close = text.lastIndex(of: "]"),
              close > open else {
            return nil
        }
        return String(text[open...close])
    }

    private static func findJSONObject(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              close > open else {
            return nil
        }
        return String(text[open...close])
    }
}
