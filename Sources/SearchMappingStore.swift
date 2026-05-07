import Foundation

struct SearchMapping: Codable, Identifiable {
    let id = UUID()
    let category: String // 类别名称，如"编程"、"设计"
    let keywords: [String] // 关键词列表
    let appNames: [String] // 关联的应用名称
    let bundleIDPatterns: [String] // BundleID匹配模式
    let lastUpdated: Date
    let confidence: Double // AI置信度 0-1

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case keywords
        case appNames
        case bundleIDPatterns
        case lastUpdated
        case confidence
    }
}

final class SearchMappingStore {
    private let fileURL: URL
    private var mappings: [SearchMapping] = []

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AppDockAuditEngine")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fileURL = dir.appendingPathComponent("search_mappings.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([SearchMapping].self, from: data) {
            mappings = loaded
            print("[SearchMapping] Loaded \(mappings.count) mappings from cache")
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(mappings) {
            try? data.write(to: fileURL)
            print("[SearchMapping] Saved \(mappings.count) mappings")
        }
    }

    func getMappings() -> [SearchMapping] {
        return mappings
    }

    func getMappingsByCategory() -> [String: SearchMapping] {
        return Dictionary(uniqueKeysWithValues: mappings.map { ($0.category, $0) })
    }

    func updateMappings(newMappings: [SearchMapping]) {
        // Merge with existing: update if category exists, add if new
        var merged: [String: SearchMapping] = Dictionary(uniqueKeysWithValues: mappings.map { ($0.category, $0) })
        for mapping in newMappings {
            if let existing = merged[mapping.category] {
                // Merge keywords and appNames
                let mergedKeywords = Array(Set(existing.keywords + mapping.keywords))
                let mergedAppNames = Array(Set(existing.appNames + mapping.appNames))
                let mergedPatterns = Array(Set(existing.bundleIDPatterns + mapping.bundleIDPatterns))
                merged[mapping.category] = SearchMapping(
                    category: mapping.category,
                    keywords: mergedKeywords,
                    appNames: mergedAppNames,
                    bundleIDPatterns: mergedPatterns,
                    lastUpdated: mapping.lastUpdated,
                    confidence: max(existing.confidence, mapping.confidence)
                )
            } else {
                merged[mapping.category] = mapping
            }
        }
        mappings = Array(merged.values)
        save()
    }

    func clearMappings() {
        mappings.removeAll()
        save()
    }

    // Default fallback mappings
    func getDefaultMappings() -> [SearchMapping] {
        return [
            SearchMapping(
                category: "编程",
                keywords: ["代码", "开发", "IDE", "编辑器", "终端", "git", "docker", "编译", "debug", "xcode", "cursor", "vscode", "code", "程序", "框架", "库", "API"],
                appNames: [],
                bundleIDPatterns: ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.jetbrains", "com.github", "com.docker"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "设计",
                keywords: ["UI", "UX", "绘图", "原型", "插画", "图形", "色彩", "figma", "sketch", "photoshop", "设计", "创意", "排版", "字体", "矢量"],
                appNames: [],
                bundleIDPatterns: ["com.figma", "com.bohemiancoding.sketch", "com.adobe.photoshop"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "写作",
                keywords: ["文档", "笔记", "文本", "markdown", "文字处理", "notion", "obsidian", "写作", "编辑", "博客", "文章", "日记"],
                appNames: [],
                bundleIDPatterns: ["com.notion.id", "md.obsidian", "com.apple.iWork.Pages"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "办公",
                keywords: ["表格", "幻灯片", "演示", "日历", "邮件", "会议", "excel", "word", "powerpoint", "办公", "效率", "项目管理", "任务"],
                appNames: [],
                bundleIDPatterns: ["com.microsoft.Office", "com.apple.iWork", "com.apple.Mail"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "娱乐",
                keywords: ["游戏", "音乐", "视频", "播放", "流媒体", "steam", "spotify", "vlc", "娱乐", "休闲", "影视", "直播"],
                appNames: [],
                bundleIDPatterns: ["com.valvesoftware.steam", "com.spotify.client", "org.videolan.vlc"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "沟通",
                keywords: ["聊天", "消息", "通话", "社交", "微信", "slack", "discord", "zoom", "沟通", "协作", "团队", "会议"],
                appNames: [],
                bundleIDPatterns: ["com.tencent.xinWeChat", "com.slack", "com.hnc.Discord", "us.zoom.xos"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "安全",
                keywords: ["密码", "加密", "VPN", "杀毒", "防火墙", "安全", "隐私", "保护", "认证", "双重验证"],
                appNames: [],
                bundleIDPatterns: ["com.agilebits.onepassword", "com.bitwarden", "com.apple.firewall"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "效率",
                keywords: ["启动器", "快捷键", "自动化", "剪贴板", "任务管理", "alfred", "raycast", "效率", "快捷", "workflow", "自动化"],
                appNames: [],
                bundleIDPatterns: ["com.runningwithcrayons.Alfred", "com.raycast.macos"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "浏览",
                keywords: ["浏览器", "网页", "下载", "safari", "chrome", "firefox", "上网", "搜索", "网络"],
                appNames: [],
                bundleIDPatterns: ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "媒体",
                keywords: ["图片", "照片", "视频编辑", "音频", "录屏", "媒体", "素材", "剪辑", "渲染"],
                appNames: [],
                bundleIDPatterns: ["com.apple.FinalCut", "com.apple.photos", "com.blackmagic-design.DaVinciResolve"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
            SearchMapping(
                category: "系统",
                keywords: ["设置", "清理", "监控", "管理", "活动监视器", "finder", "系统", "工具", "优化", "维护", "卸载"],
                appNames: [],
                bundleIDPatterns: ["com.apple.finder", "com.apple.ActivityMonitor", "com.macpaw.CleanMyMac"],
                lastUpdated: Date(),
                confidence: 0.5
            ),
        ]
    }

    // Initialize with defaults if empty
    func ensureInitialized() {
        if mappings.isEmpty {
            mappings = getDefaultMappings()
            save()
            print("[SearchMapping] Initialized with default mappings")
        }
    }
}

// MARK: - AI Search Mapping Generator

struct AISearchMappingGenerator {
    private let tokenStore = TokenUsageStore()

    func generateMappings(for apps: [AppRecord], config: AIProviderConfig) async throws -> [SearchMapping] {
        let adapter = OpenAICompatibleAdapter()

        // Build app context
        let appEntries = apps.map { app -> String in
            let perms = app.permissions.requested.map(\.rawValue).joined(separator: ",")
            let bgFlag = app.permissions.backgroundResident ? "是" : "否"
            let sourceLabel: String
            switch app.source {
            case .system: sourceLabel = "macOS系统自带"
            case .appStore: sourceLabel = "App Store"
            case .thirdParty: sourceLabel = "第三方"
            case .unknown: sourceLabel = "未知"
            }
            return """
              {
                "name": "\(app.name)",
                "bundleID": "\(app.bundleID ?? "unknown")",
                "source": "\(sourceLabel)",
                "background": \(bgFlag),
                "permissions": "[\(perms)]"
              }
            """
        }

        let prompt = """
        你是一位macOS应用专家。请分析以下应用列表，为每个主要类别生成精确的搜索关键词映射。

        ## 要求
        1. 分析应用名称、BundleID、来源、权限等特征
        2. 为每个类别生成5-15个精准的关键词（中文为主，包含常见英文术语）
        3. 关键词应覆盖：
           - 功能描述（如"代码编辑"、"视频剪辑"）
           - 常见动作（如"写代码"、"看视频"）
           - 英文名/缩写（如"IDE", "VPN"）
           - 具体应用名（如"微信", "Slack"）
        4. 提取BundleID模式用于精确匹配

        ## 输出格式（纯JSON数组）
        [
          {
            "category": "类别名",
            "keywords": ["关键词1", "关键词2", ...],
            "appNames": ["应用名1", "应用名2"],
            "bundleIDPatterns": ["com.example.pattern", ...],
            "confidence": 0.85
          }
        ]

        ## 应用列表
        \(appEntries.joined(separator: ",\n"))

        请确保生成的关键词能覆盖用户搜索时可能使用的各种表达方式。
        """

        let payload = Data("[]".utf8)
        let result = try await adapter.complete(prompt: prompt, payload: payload, config: config)

        // Record token usage
        if let pt = result.promptTokens, let ct = result.completionTokens {
            tokenStore.recordUsage(
                operation: "searchMapping",
                model: config.model,
                promptTokens: pt,
                completionTokens: ct
            )
        }

        // Parse response
        var cleanResponse = result.content
        if let fenceStart = cleanResponse.range(of: "```") {
            let after = cleanResponse[fenceStart.upperBound...]
            if let fenceEnd = after.range(of: "```") {
                cleanResponse = String(after[after.startIndex..<fenceEnd.lowerBound])
                if cleanResponse.hasPrefix("json") { cleanResponse = String(cleanResponse.dropFirst(4)) }
            }
        }

        guard let jsonStart = cleanResponse.firstIndex(of: "["),
              let jsonEnd = cleanResponse.lastIndex(of: "]"),
              let data = String(cleanResponse[jsonStart...jsonEnd]).data(using: .utf8) else {
            print("[SearchMapping] No JSON array found")
            throw AIProviderError.decodeFailure
        }

        // Parse mappings
        struct RawMapping: Codable {
            let category: String
            let keywords: [String]
            let appNames: [String]?
            let bundleIDPatterns: [String]?
            let confidence: Double?
        }

        let rawMappings = try JSONDecoder().decode([RawMapping].self, from: data)
        let mappings = rawMappings.map { raw in
            SearchMapping(
                category: raw.category,
                keywords: raw.keywords,
                appNames: raw.appNames ?? [],
                bundleIDPatterns: raw.bundleIDPatterns ?? [],
                lastUpdated: Date(),
                confidence: raw.confidence ?? 0.8
            )
        }

        print("[SearchMapping] Generated \(mappings.count) mappings from AI")
        return mappings
    }
}