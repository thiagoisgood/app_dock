import Foundation

/// 应用类别枚举 — 与 CategorySchema.standard 的 displayName 对齐
enum AppCategory: String, CaseIterable, Codable {
    case development = "开发工具"
    case design = "设计创作"
    case productivity = "办公效率"
    case communication = "沟通协作"
    case utility = "系统工具"
    case browser = "网络浏览"
    case security = "安全隐私"
    case entertainment = "影音娱乐"
    case reading = "阅读教育"
    case finance = "金融理财"
    case other = "其他"
}

/// 启发式分类器：与 CategorySchema 对齐，返回 ClassificationResult
struct AppCategoryClassifier {
    private let schema = CategorySchema.standard

    /// 对单个应用进行分类，返回带置信度和来源的结果
    func classify(app: AppRecord) -> ClassificationResult {
        let name = app.name.lowercased()
        let bundle = (app.bundleID ?? "").lowercased()
        let path = app.path.lowercased()
        let haystack = [name, bundle, path].joined(separator: " ")

        // 1. 先用 Schema 的 keywords 做匹配
        for categoryDef in schema {
            if containsAny(haystack, keys: categoryDef.keywords) {
                return ClassificationResult(
                    appName: app.name,
                    bundleID: app.bundleID,
                    category: categoryDef.displayName,
                    confidence: 0.7,
                    source: .heuristic
                )
            }
        }

        // 2. 再用 Schema 的 bundleIDPatterns 做匹配
        if let bid = app.bundleID {
            for categoryDef in schema {
                for pattern in categoryDef.bundleIDPatterns {
                    if bid.contains(pattern) {
                        return ClassificationResult(
                            appName: app.name,
                            bundleID: app.bundleID,
                            category: categoryDef.displayName,
                            confidence: 0.85,
                            source: .bundleID
                        )
                    }
                }
            }
        }

        // 3. 签名 teamID 匹配（如 Apple 自带应用）
        if let teamID = app.signature.teamID {
            for categoryDef in schema {
                if categoryDef.knownSigners.contains(teamID) {
                    return ClassificationResult(
                        appName: app.name,
                        bundleID: app.bundleID,
                        category: categoryDef.displayName,
                        confidence: 0.95,
                        source: .signature
                    )
                }
            }
        }

        // 4. 回退到"其他"
        return ClassificationResult(
            appName: app.name,
            bundleID: app.bundleID,
            category: "其他",
            confidence: 0.3,
            source: .heuristic
        )
    }

    /// 兼容旧接口：返回 AppCategory 枚举值（用于现有 UI 代码）
    func category(for app: AppRecord) -> AppCategory {
        let result = classify(app: app)
        return AppCategory(rawValue: result.category) ?? .other
    }

    private func containsAny(_ text: String, keys: [String]) -> Bool {
        keys.contains { text.contains($0) }
    }
}
