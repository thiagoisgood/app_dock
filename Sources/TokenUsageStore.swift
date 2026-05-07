import Foundation

struct TokenUsageRecord: Codable, Identifiable {
    let id = UUID()
    let date: Date
    let operation: String // "tagging", "organization", "report", "digest"
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cost: Double // USD

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case operation
        case model
        case promptTokens
        case completionTokens
        case totalTokens
        case cost
    }
}

struct TokenUsageSummary: Codable {
    var totalPromptTokens: Int = 0
    var totalCompletionTokens: Int = 0
    var totalTokens: Int = 0
    var totalCost: Double = 0.0
    var operationCounts: [String: Int] = [:]
    var lastUpdated: Date = Date()

    mutating func add(record: TokenUsageRecord) {
        totalPromptTokens += record.promptTokens
        totalCompletionTokens += record.completionTokens
        totalTokens += record.totalTokens
        totalCost += record.cost
        operationCounts[record.operation, default: 0] += 1
        lastUpdated = Date()
    }
}

final class TokenUsageStore {
    private let fileURL: URL
    private var records: [TokenUsageRecord] = []
    private var summary: TokenUsageSummary = TokenUsageSummary()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AppDockAuditEngine")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fileURL = dir.appendingPathComponent("token_usage.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([TokenUsageRecord].self, from: data) {
            records = loaded
            summary = TokenUsageSummary()
            for record in records {
                summary.add(record: record)
            }
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL)
        }
    }

    func recordUsage(
        operation: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int
    ) {
        let totalTokens = promptTokens + completionTokens
        // Estimate cost based on model (approximate GPT-4o-mini pricing)
        let costPerPromptToken: Double
        let costPerCompletionToken: Double
        if model.contains("gpt-4o") {
            costPerPromptToken = 0.0000025  // $2.50 per 1M tokens
            costPerCompletionToken = 0.00001  // $10.00 per 1M tokens
        } else if model.contains("gpt-3.5") {
            costPerPromptToken = 0.0000005  // $0.50 per 1M tokens
            costPerCompletionToken = 0.0000015  // $1.50 per 1M tokens
        } else {
            // Default: assume similar to GPT-4o-mini
            costPerPromptToken = 0.0000025
            costPerCompletionToken = 0.00001
        }
        let cost = Double(promptTokens) * costPerPromptToken + Double(completionTokens) * costPerCompletionToken

        let record = TokenUsageRecord(
            date: Date(),
            operation: operation,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            cost: cost
        )
        records.append(record)
        summary.add(record: record)
        save()
        print("[TokenUsage] Recorded: \(operation) - \(totalTokens) tokens ($\(String(format: "%.4f", cost)))")
    }

    func getSummary() -> TokenUsageSummary {
        return summary
    }

    func getRecentRecords(limit: Int = 20) -> [TokenUsageRecord] {
        return records.suffix(limit).reversed()
    }

    func clearHistory() {
        records.removeAll()
        summary = TokenUsageSummary()
        save()
    }
}