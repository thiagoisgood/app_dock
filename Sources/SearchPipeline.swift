import Foundation

// MARK: - 管道协议

protocol SearchPipelineStage {
    func process(_ context: SearchContext) -> SearchContext
}

struct SearchContext {
    let originalQuery: String
    var tokens: [String]
    var intent: SearchIntent
    var expandedTerms: Set<String>
    var matchedCategories: Set<String>
    var candidates: [ScoredApp]
    var weights: SearchWeights
    var intents: [IntentFilter]

    static func empty(query: String, weights: SearchWeights) -> SearchContext {
        SearchContext(
            originalQuery: query,
            tokens: [],
            intent: .unknown,
            expandedTerms: [],
            matchedCategories: [],
            candidates: [],
            weights: weights,
            intents: []
        )
    }
}

// MARK: - 默认阶段

struct DefaultQueryParser: SearchPipelineStage {
    func process(_ context: SearchContext) -> SearchContext {
        var ctx = context
        ctx.tokens = tokenize(ctx.originalQuery.lowercased())
        return ctx
    }

    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
                if char.unicodeScalars.contains(where: { $0.value > 0x4E00 && $0.value < 0x9FFF }) {
                    tokens.append(String(char))
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

struct DefaultIntentDetector: SearchPipelineStage {
    private let knownAppNames: Set<String>

    init(knownAppNames: Set<String> = []) {
        self.knownAppNames = knownAppNames
    }

    func process(_ context: SearchContext) -> SearchContext {
        var ctx = context
        ctx.intents = IntentDetector.detectIntents(from: ctx.originalQuery)
        ctx.intent = IntentDetector.detectIntent(query: ctx.originalQuery, knownAppNames: knownAppNames)
        return ctx
    }
}

struct DefaultTermExpander: SearchPipelineStage {
    private let mappingStore: SearchMappingStore
    private let aliasStore: AppNameAliasStore

    init(mappingStore: SearchMappingStore = SearchMappingStore(), aliasStore: AppNameAliasStore = AppNameAliasStore()) {
        self.mappingStore = mappingStore
        self.aliasStore = aliasStore
    }

    func process(_ context: SearchContext) -> SearchContext {
        var ctx = context
        let mappings = mappingStore.getMappings()

        for token in ctx.tokens {
            // 类别别名解析
            if let cat = SearchAliasRegistry.resolveCategoryAlias(token) {
                ctx.matchedCategories.insert(cat)
                if let def = CategorySchema.standard.first(where: { $0.displayName == cat }) {
                    ctx.expandedTerms.formUnion(def.keywords.map { $0.lowercased() })
                }
            }

            // SearchMapping 扩展
            for mapping in mappings {
                let catLower = mapping.category.lowercased()
                if catLower.contains(token) || token.contains(catLower) {
                    ctx.expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                    ctx.matchedCategories.insert(mapping.category)
                }
                for keyword in mapping.keywords {
                    let kwLower = keyword.lowercased()
                    if kwLower.contains(token) || token.contains(kwLower) {
                        ctx.expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        ctx.matchedCategories.insert(mapping.category)
                        ctx.expandedTerms.insert(catLower)
                    }
                }
                for appName in mapping.appNames {
                    if appName.lowercased().contains(token) || token.contains(appName.lowercased()) {
                        ctx.expandedTerms.formUnion(mapping.keywords.map { $0.lowercased() })
                        ctx.matchedCategories.insert(mapping.category)
                    }
                }
            }

            // 应用中英文名称扩展
            let nameAliases = aliasStore.aliases(for: token)
            ctx.expandedTerms.formUnion(nameAliases.map { $0.lowercased() })
        }

        ctx.expandedTerms.formUnion(ctx.tokens)
        return ctx
    }
}

struct DefaultScorer: SearchPipelineStage {
    private let tags: [String: [String]]
    private let aiCategories: [String: String]
    private let mappingStore: SearchMappingStore
    private let feedbackStore: SearchFeedbackStore?

    init(tags: [String: [String]], aiCategories: [String: String], mappingStore: SearchMappingStore = SearchMappingStore(), feedbackStore: SearchFeedbackStore? = nil) {
        self.tags = tags
        self.aiCategories = aiCategories
        self.mappingStore = mappingStore
        self.feedbackStore = feedbackStore
    }

    func process(_ context: SearchContext) -> SearchContext {
        var ctx = context
        let mappings = mappingStore.getMappings()
        var scored: [ScoredApp] = []

        for app in ctx.candidates {
            // 意图硬过滤
            if !ctx.intents.isEmpty && !IntentDetector.appMatchesIntents(app.app, intents: ctx.intents) {
                continue
            }

            var score: Double = 0
            var reasons: [String] = []

            // 1. 标签匹配（最高权重）
            let appTags = (tags[app.app.name] ?? []).map { $0.lowercased() }
            for tag in appTags {
                for term in ctx.expandedTerms {
                    if tag.contains(term) || term.contains(tag) {
                        score += ctx.weights.tagWeight
                        reasons.append("tag:\(tag)")
                    }
                }
            }

            // 2. 类别匹配
            let resolvedCat = resolvedCategory(for: app.app, aiCategories: aiCategories)
            if let cat = resolvedCat, ctx.matchedCategories.contains(cat) {
                score += ctx.weights.mappingWeight
                reasons.append("category:\(cat)")
            }

            // 3. Mapping-based matching
            for mapping in mappings where ctx.matchedCategories.contains(mapping.category) {
                if mapping.appNames.contains(app.app.name) {
                    score += ctx.weights.mappingWeight * 0.6
                    reasons.append("mappingAppName")
                }
                if let bid = app.app.bundleID {
                    for pattern in mapping.bundleIDPatterns where bid.contains(pattern) {
                        score += ctx.weights.bundleIDWeight * 0.5
                        reasons.append("bundleID:\(pattern)")
                    }
                }
            }

            // 4. 名称/BundleID 文本匹配
            let nameLower = app.app.name.lowercased()
            let bundleLower = (app.app.bundleID ?? "").lowercased()
            for term in ctx.tokens {
                if nameLower.contains(term) {
                    score += ctx.weights.nameWeight
                    reasons.append("name")
                    if nameLower == term {
                        score += ctx.weights.exactNameBonus
                        reasons.append("exactName")
                    }
                }
                if bundleLower.contains(term) {
                    score += ctx.weights.nameWeight * 0.5
                    reasons.append("bundleID")
                }
            }

            // 5. 权限提示
            let permissions = app.app.permissions.requested
            if ctx.matchedCategories.contains("沟通协作") && (permissions.contains(.camera) || permissions.contains(.microphone)) {
                score += ctx.weights.permissionHintWeight
                reasons.append("permissionHint:沟通")
            }
            if ctx.matchedCategories.contains("安全隐私") && permissions.contains(.fullDiskAccess) {
                score += ctx.weights.permissionHintWeight
                reasons.append("permissionHint:安全")
            }

            // 6. 反馈 boosting
            if let feedbackStore {
                let boost = feedbackStore.boostForApp(app.app.name, query: ctx.originalQuery)
                if boost > 0 {
                    score += boost
                    reasons.append("feedbackBoost:\(boost)")
                }
            }

            if score > 0 {
                scored.append(ScoredApp(app: app.app, score: score, reasons: reasons))
            }
        }

        ctx.candidates = scored
        return ctx
    }

    private func resolvedCategory(for app: AppRecord, aiCategories: [String: String]) -> String? {
        if let bid = app.bundleID, let cat = aiCategories[bid] { return cat }
        if let cat = aiCategories[app.name] { return cat }
        return nil
    }
}

struct DefaultRanker: SearchPipelineStage {
    func process(_ context: SearchContext) -> SearchContext {
        var ctx = context
        ctx.candidates.sort { $0.score > $1.score }
        return ctx
    }
}

// MARK: - 管道编排器

final class SearchPipeline {
    private let stages: [SearchPipelineStage]

    init(stages: [SearchPipelineStage]) {
        self.stages = stages
    }

    static func defaultPipeline(
        tags: [String: [String]],
        aiCategories: [String: String],
        weights: SearchWeights,
        knownAppNames: Set<String> = [],
        feedbackStore: SearchFeedbackStore? = nil
    ) -> SearchPipeline {
        SearchPipeline(stages: [
            DefaultQueryParser(),
            DefaultIntentDetector(knownAppNames: knownAppNames),
            DefaultTermExpander(),
            DefaultScorer(tags: tags, aiCategories: aiCategories, feedbackStore: feedbackStore),
            DefaultRanker(),
        ])
    }

    func execute(query: String, apps: [AppRecord]) -> [ScoredApp] {
        var context = SearchContext.empty(query: query, weights: weights)
        context.candidates = apps.map { ScoredApp(app: $0, score: 0, reasons: []) }

        for stage in stages {
            context = stage.process(context)
        }

        return context.candidates
    }

    private var weights: SearchWeights = SearchWeights()
}
