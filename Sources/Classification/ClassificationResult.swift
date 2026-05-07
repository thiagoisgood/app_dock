import Foundation

/// 分类来源：标记分类结果是如何得出的
enum ClassificationSource: String, Codable, Hashable {
    case ai          // AI 模型分类
    case heuristic   // 启发式关键词匹配
    case signature   // 签名 teamID 匹配
    case bundleID    // Bundle ID 模式匹配
}

/// 统一分类结果，替代原有的 [String: String] 字典
struct ClassificationResult: Codable, Hashable {
    let appName: String
    let bundleID: String?
    let category: String
    let confidence: Double       // 0.0–1.0，AI 返回或预分类预设
    let source: ClassificationSource

    /// 从旧格式 [String: String] 兼容转换
    static func fromLegacy(name: String, bundleID: String?, category: String) -> ClassificationResult {
        ClassificationResult(
            appName: name,
            bundleID: bundleID,
            category: category,
            confidence: 0.5,
            source: .ai
        )
    }
}
