import Foundation

struct AppTagStore {
    private let key = "app.tags"

    func load() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let tags = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return tags
    }

    func save(_ tags: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func merging(_ aiTags: [String: [String]], into existing: [String: [String]]) -> [String: [String]] {
        var result = existing
        for (app, tags) in aiTags {
            let existingTags = Set(result[app] ?? [])
            let merged = Array(existingTags.union(tags)).sorted()
            result[app] = merged
        }
        return result
    }
}
