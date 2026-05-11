import Foundation

final class SearchFeedbackStore {
    private let feedbackURL: URL
    private let weightsURL: URL
    private var events: [SearchFeedbackEvent] = []
    private(set) var weights: SearchWeights = SearchWeights()
    private(set) var stats: SearchLearningStats = SearchLearningStats()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AppDockAuditEngine")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        feedbackURL = dir.appendingPathComponent("search_feedback.json")
        weightsURL = dir.appendingPathComponent("search_weights.json")
        loadFeedback()
        loadWeights()
        computeStats()
    }

    func recordEvent(_ event: SearchFeedbackEvent) {
        events.append(event)
        saveFeedback()
        computeStats()

        if events.count % 10 == 0 {
            evolve()
        }
    }

    // MARK: - 进化

    func evolve() {
        let recent = events.suffix(50)
        var adjusted = weights

        // 点击率低 → 扩大匹配
        let clickRate = Double(stats.totalClicks) / max(Double(stats.totalQueries), 1)
        if clickRate < 0.3 && stats.totalQueries > 5 {
            adjusted.tagWeight += 0.5
            adjusted.mappingWeight += 0.5
        }

        // 快速首击多 → 精确匹配工作良好
        let fastFirstClicks = recent.filter {
            ($0.clickedIndex ?? Int.max) == 0 && ($0.clickDelay ?? .infinity) < 2.0
        }.count
        if fastFirstClicks > 5 {
            adjusted.exactNameBonus += 1.0
        }

        // 晚期点击多 → 排序不佳
        let lateClicks = recent.filter { ($0.clickedIndex ?? 0) > 3 }.count
        if lateClicks > 3 {
            adjusted.feedbackBoost += 1.0
        }

        // 失败率高 → 需要更广泛的匹配
        let failedRatio = Double(stats.failedQueries) / max(Double(stats.totalQueries), 1)
        if failedRatio > 0.2 && stats.totalQueries > 10 {
            adjusted.permissionHintWeight += 0.5
        }

        adjusted.clamp()
        weights = adjusted
        saveWeights()
        print("[Feedback] Evolved weights: tag=\(adjusted.tagWeight) map=\(adjusted.mappingWeight) name=\(adjusted.nameWeight) exact=\(adjusted.exactNameBonus) boost=\(adjusted.feedbackBoost)")
    }

    /// 查询历史反馈，返回对指定 app 的 boosting 分数
    func boostForApp(_ appName: String, query: String) -> Double {
        let relevant = events.filter {
            $0.clickedApp == appName && fuzzyQueryMatch($0.query, query)
        }
        let boost = min(Double(relevant.count) * 0.5, weights.feedbackBoost)
        return boost > 0 ? boost : 0
    }

    // MARK: - 持久化

    private func loadFeedback() {
        guard let data = try? Data(contentsOf: feedbackURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([SearchFeedbackEvent].self, from: data) {
            events = loaded
        }
    }

    private func saveFeedback() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(events) {
            try? data.write(to: feedbackURL, options: .atomic)
        }
    }

    private func loadWeights() {
        guard let data = try? Data(contentsOf: weightsURL) else { return }
        if let loaded = try? JSONDecoder().decode(SearchWeights.self, from: data) {
            weights = loaded
        }
    }

    private func saveWeights() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(weights) {
            try? data.write(to: weightsURL, options: .atomic)
        }
    }

    private func computeStats() {
        var s = SearchLearningStats()
        s.totalQueries = events.count
        s.totalClicks = events.filter { $0.clickedApp != nil }.count
        s.failedQueries = events.filter { $0.hasResults && $0.clickedApp == nil }.count

        let clicked = events.compactMap(\.clickedIndex)
        if !clicked.isEmpty {
            s.avgClickPosition = clicked.map(Double.init).reduce(0, +) / Double(clicked.count)
        }

        let delays = events.compactMap(\.clickDelay)
        if !delays.isEmpty {
            s.avgClickDelay = delays.reduce(0, +) / Double(delays.count)
        }

        s.lastUpdated = Date()
        stats = s
    }

    private func fuzzyQueryMatch(_ a: String, _ b: String) -> Bool {
        let aL = a.lowercased(), bL = b.lowercased()
        if aL == bL { return true }
        if aL.contains(bL) || bL.contains(aL) { return true }
        let tokensA = Set(aL.components(separatedBy: .whitespaces))
        let tokensB = Set(bL.components(separatedBy: .whitespaces))
        let overlap = tokensA.intersection(tokensB)
        return !overlap.isEmpty && overlap.count >= min(tokensA.count, tokensB.count) / 2
    }
}
