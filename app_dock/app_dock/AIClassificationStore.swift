import Foundation

struct AIClassificationData: Codable {
    let categories: [String: String]      // appName/bundleID -> categoryName
    let descriptions: [String: String]    // categoryName -> description
    let confidences: [String: Double]     // appName/bundleID -> confidence (0.0-1.0)
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case categories, descriptions, confidences, lastUpdated
    }

    init(categories: [String: String], descriptions: [String: String], confidences: [String: Double], lastUpdated: Date) {
        self.categories = categories
        self.descriptions = descriptions
        self.confidences = confidences
        self.lastUpdated = lastUpdated
    }

    /// 兼容旧版本缓存（缺失 confidences 字段时回退为空字典）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decode([String: String].self, forKey: .categories)
        descriptions = try container.decodeIfPresent([String: String].self, forKey: .descriptions) ?? [:]
        confidences = try container.decodeIfPresent([String: Double].self, forKey: .confidences) ?? [:]
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
    }
}

struct AIClassificationStore {
    private let fileName = "ai-classification.json"

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OpenDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func save(categories: [String: String], descriptions: [String: String], confidences: [String: Double]) {
        let data = AIClassificationData(
            categories: categories,
            descriptions: descriptions,
            confidences: confidences,
            lastUpdated: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
        print("[ClassificationStore] Saved \(categories.count) categories, \(confidences.count) confidences")
    }

    func load() -> AIClassificationData? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode(AIClassificationData.self, from: data) else { return nil }
        print("[ClassificationStore] Loaded \(loaded.categories.count) categories from cache (updated: \(loaded.lastUpdated))")
        return loaded
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        print("[ClassificationStore] Cleared classification cache")
    }
}
