import Foundation

/// 统一分类服务：融合签名、Bundle ID、启发式、AI 四种判定方式
struct AppClassifierService {
    private let tokenStore = TokenUsageStore()
    private let schema = CategorySchema.standard
    private let categoryClassifier = AppCategoryClassifier()

    // MARK: - 统一分类入口

    func classify(
        apps: [AppRecord],
        existingCategories: [String: String],
        config: AIProviderConfig
    ) async -> [ClassificationResult] {
        guard !apps.isEmpty else { return [] }

        // 步骤 1-3: 预分类（零 API 成本）
        let preClassified = preClassify(apps)
        let preClassifiedKeys = Set(preClassified.keys)

        // 步骤 4: 过滤出需要 AI 分类的应用
        let remaining = apps.filter { app in
            !preClassifiedKeys.contains(app.name)
                && !(app.bundleID.map { preClassifiedKeys.contains($0) } ?? false)
        }

        // 步骤 5: AI 批量分类
        let aiResults = remaining.isEmpty
            ? []
            : await aiClassifyBatched(remaining, config: config)

        // 步骤 6: 合并结果
        return mergeResults(preClassified, aiResults, existingCategories)
    }

    // MARK: - 分类+标签联合

    func classifyWithTags(
        apps: [AppRecord],
        existingCategories: [String: String],
        config: AIProviderConfig
    ) async -> (categories: [ClassificationResult], tags: [String: [String]]) {
        guard !apps.isEmpty else { return ([], [:]) }

        // 预分类
        let preClassified = preClassify(apps)
        let preClassifiedKeys = Set(preClassified.keys)

        let remaining = apps.filter { app in
            !preClassifiedKeys.contains(app.name)
                && !(app.bundleID.map { preClassifiedKeys.contains($0) } ?? false)
        }

        let (aiCategories, aiTags) = remaining.isEmpty
            ? ([], [:])
            : await aiClassifyWithTagsBatched(remaining, config: config)

        let allCategories = mergeResults(preClassified, aiCategories, existingCategories)

        // 合并标签：预分类应用使用启发式标签
        var allTags = aiTags
        for app in apps where preClassifiedKeys.contains(app.name) || preClassifiedKeys.contains(app.bundleID ?? "") {
            let result = categoryClassifier.classify(app: app)
            allTags[app.name] = [result.category] + schemaKeywords(for: result.category).prefix(2).map { $0 }
        }

        return (allCategories, allTags)
    }

    // MARK: - 预分类：签名匹配

    private func preClassifyBySignature(_ apps: [AppRecord]) -> [String: ClassificationResult] {
        var results: [String: ClassificationResult] = [:]
        for app in apps {
            guard let teamID = app.signature.teamID else { continue }
            for category in schema {
                if category.knownSigners.contains(teamID) {
                    results[app.name] = ClassificationResult(
                        appName: app.name,
                        bundleID: app.bundleID,
                        category: category.displayName,
                        confidence: 0.95,
                        source: .signature
                    )
                    if let bid = app.bundleID {
                        results[bid] = results[app.name]!
                    }
                    break
                }
            }
        }
        return results
    }

    // MARK: - 预分类：Bundle ID 模式匹配

    private func preClassifyByBundleID(_ apps: [AppRecord]) -> [String: ClassificationResult] {
        var results: [String: ClassificationResult] = [:]
        for app in apps {
            guard let bid = app.bundleID else { continue }
            for category in schema {
                for pattern in category.bundleIDPatterns {
                    if bid.contains(pattern) {
                        results[app.name] = ClassificationResult(
                            appName: app.name,
                            bundleID: app.bundleID,
                            category: category.displayName,
                            confidence: 0.85,
                            source: .bundleID
                        )
                        results[bid] = results[app.name]!
                        break
                    }
                }
            }
        }
        return results
    }

    // MARK: - 预分类：启发式

    private func preClassifyByHeuristic(_ apps: [AppRecord]) -> [String: ClassificationResult] {
        var results: [String: ClassificationResult] = [:]
        for app in apps {
            let result = categoryClassifier.classify(app: app)
            if result.source != .heuristic || result.confidence >= 0.6 {
                results[app.name] = result
                if let bid = app.bundleID {
                    results[bid] = result
                }
            }
        }
        return results
    }

    // MARK: - 合并预分类结果

    private func preClassify(_ apps: [AppRecord]) -> [String: ClassificationResult] {
        var merged: [String: ClassificationResult] = [:]

        // 优先级：signature > bundleID > heuristic
        for (key, value) in preClassifyByHeuristic(apps) { merged[key] = value }
        for (key, value) in preClassifyByBundleID(apps) { merged[key] = value }
        for (key, value) in preClassifyBySignature(apps) { merged[key] = value }

        return merged
    }

    // MARK: - AI 批量分类

    private func aiClassifyBatched(_ apps: [AppRecord], config: AIProviderConfig) async -> [ClassificationResult] {
        let batchSize = max(config.maxTokens / 200, 50)
        var allResults: [ClassificationResult] = []

        for batchStart in stride(from: 0, to: apps.count, by: batchSize) {
            let batch = Array(apps[batchStart..<min(batchStart + batchSize, apps.count)])
            let appEntries = PromptTemplates.buildAppEntries(for: batch)
            let prompt = PromptTemplates.classificationUserPrompt(appEntries: appEntries)

            let adapter = OpenAICompatibleAdapter()
            do {
                let result = try await adapter.complete(
                    systemPrompt: PromptTemplates.classificationSystemPrompt(),
                    userPrompt: prompt,
                    config: config
                )

                if let pt = result.promptTokens, let ct = result.completionTokens {
                    tokenStore.recordUsage(
                        operation: "classification",
                        model: config.model,
                        promptTokens: pt,
                        completionTokens: ct
                    )
                }

                struct CategoryEntry: Codable {
                    let name: String
                    let bundleID: String?
                    let category: String
                    let confidence: Double?
                }

                let entries = try JSONResponseParser.extractArray(result.content, type: CategoryEntry.self)
                for entry in entries {
                    allResults.append(ClassificationResult(
                        appName: entry.name,
                        bundleID: entry.bundleID,
                        category: entry.category,
                        confidence: entry.confidence ?? 0.7,
                        source: .ai
                    ))
                }
            } catch {
                print("[Classifier] AI batch error: \(error.localizedDescription)")
            }
        }

        return allResults
    }

    // MARK: - AI 分类+标签联合

    private func aiClassifyWithTagsBatched(_ apps: [AppRecord], config: AIProviderConfig) async -> ([ClassificationResult], [String: [String]]) {
        let batchSize = max(config.maxTokens / 250, 40)
        var categories: [ClassificationResult] = []
        var tags: [String: [String]] = [:]

        for batchStart in stride(from: 0, to: apps.count, by: batchSize) {
            let batch = Array(apps[batchStart..<min(batchStart + batchSize, apps.count)])
            let appEntries = PromptTemplates.buildAppEntries(for: batch)
            let prompt = PromptTemplates.classificationWithTagsUserPrompt(appEntries: appEntries)

            let adapter = OpenAICompatibleAdapter()
            do {
                let result = try await adapter.complete(
                    systemPrompt: PromptTemplates.classificationWithTagsSystemPrompt(),
                    userPrompt: prompt,
                    config: config
                )

                if let pt = result.promptTokens, let ct = result.completionTokens {
                    tokenStore.recordUsage(
                        operation: "classification+tags",
                        model: config.model,
                        promptTokens: pt,
                        completionTokens: ct
                    )
                }

                struct EntryWithTags: Codable {
                    let name: String
                    let bundleID: String?
                    let category: String
                    let confidence: Double?
                    let tags: [String]?
                }

                let entries = try JSONResponseParser.extractArray(result.content, type: EntryWithTags.self)
                for entry in entries {
                    categories.append(ClassificationResult(
                        appName: entry.name,
                        bundleID: entry.bundleID,
                        category: entry.category,
                        confidence: entry.confidence ?? 0.7,
                        source: .ai
                    ))
                    if let t = entry.tags, !t.isEmpty {
                        tags[entry.name] = t
                    }
                }
            } catch {
                print("[Classifier] AI classifyWithTags batch error: \(error.localizedDescription)")
            }
        }

        return (categories, tags)
    }

    // MARK: - 合并最终结果

    private func mergeResults(
        _ preClassified: [String: ClassificationResult],
        _ aiResults: [ClassificationResult],
        _ existingCategories: [String: String]
    ) -> [ClassificationResult] {
        var merged = preClassified

        // AI 结果覆盖预分类（AI 优先级更高）
        for result in aiResults {
            merged[result.appName] = result
            if let bid = result.bundleID {
                merged[bid] = result
            }
        }

        // 仍未分类的应用，使用旧格式兼容
        for (name, category) in existingCategories {
            if merged[name] == nil {
                merged[name] = ClassificationResult.fromLegacy(
                    name: name,
                    bundleID: nil,
                    category: category
                )
            }
        }

        return Array(merged.values)
    }

    // MARK: - 辅助

    private func schemaKeywords(for category: String) -> [String] {
        schema.first { $0.displayName == category }?.keywords ?? []
    }
}
