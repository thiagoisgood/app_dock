import Foundation

enum LocalDataPrivacy {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenDock", isDirectory: true)
    }

    static func historyEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "privacy.localHistoryEnabled")
    }

    static func clear(defaults: UserDefaults = .standard, directory: URL = Self.directory) throws {
        let files = ["app-cache.json", "ai-classification.json", "search_feedback.json",
                     "search_weights.json", "search_mappings.json", "app_name_aliases.json", "token_usage.json"]
        for file in files {
            let url = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        defaults.removeObject(forKey: "app.tags")
        defaults.removeObject(forKey: "app.recentUsage")
        // Credentials and AI settings are intentionally kept; an empty saved key removes it.
    }

    static func clearHistory(defaults: UserDefaults = .standard, directory: URL = Self.directory) throws {
        defaults.removeObject(forKey: "app.recentUsage")
        let feedback = directory.appendingPathComponent("search_feedback.json")
        if FileManager.default.fileExists(atPath: feedback.path) { try FileManager.default.removeItem(at: feedback) }
    }
}
