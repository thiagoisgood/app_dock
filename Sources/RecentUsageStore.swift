import Foundation

struct AppUsageRecord: Codable {
    var openCount: Int
    var lastOpenedAt: Date
}

struct RecentUsageStore {
    private let key = "app.recentUsage"

    func load() -> [String: AppUsageRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([String: AppUsageRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    func save(_ records: [String: AppUsageRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    mutating func recordOpen(appName: String) {
        var records = load()
        if var record = records[appName] {
            record.openCount += 1
            record.lastOpenedAt = Date()
            records[appName] = record
        } else {
            records[appName] = AppUsageRecord(openCount: 1, lastOpenedAt: Date())
        }
        save(records)
    }

    func recentApps(limit: Int = 30) -> [String] {
        let records = load()
        let now = Date()
        // Score = openCount * timeDecay (half-life 7 days)
        return records.map { (name, record) in
            let daysSinceOpen = now.timeIntervalSince(record.lastOpenedAt) / 86400
            let decay = pow(0.5, daysSinceOpen / 7.0)
            let score = Double(record.openCount) * decay
            return (name: name, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map(\.name)
    }
}
