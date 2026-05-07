import Foundation

struct AIClassificationData: Codable {
    let categories: [String: String]      // appName/bundleID -> categoryName
    let descriptions: [String: String]    // categoryName -> description
    let lastUpdated: Date
}

struct AIClassificationStore {
    private let fileName = "ai-classification.json"

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AppDockAuditEngine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func save(categories: [String: String], descriptions: [String: String]) {
        let data = AIClassificationData(
            categories: categories,
            descriptions: descriptions,
            lastUpdated: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
        print("[ClassificationStore] Saved \(categories.count) categories, \(descriptions.count) descriptions")
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