import Foundation

/// 类别层级：core 为核心高置信类别，extended 为补充类别，custom 为用户/AI 发现的新类别
enum CategoryTier: String, Codable, Hashable {
    case core
    case extended
    case custom
}

/// 类别定义：包含描述、关键词、Bundle ID 模式、已知签名者
struct CategoryDefinition: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let description: String
    let tier: CategoryTier
    let keywords: [String]
    let bundleIDPatterns: [String]
    let knownSigners: [String]

    static func == (lhs: CategoryDefinition, rhs: CategoryDefinition) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// 标准类别 Schema — 与现有 runAIOrganization 提示词中的 10 个类别对齐
struct CategorySchema {
    static let standard: [CategoryDefinition] = [
        CategoryDefinition(
            id: "development",
            displayName: "开发工具",
            description: "IDE、编译器、终端、数据库、版本控制、容器、调试器",
            tier: .core,
            keywords: ["xcode", "cursor", "code", "terminal", "iterm", "docker", "git", "simulator", "postman", "vscode", "jetbrains", "swift", "python", "node"],
            bundleIDPatterns: ["com.apple.dt", "com.microsoft.VSCode", "com.jetbrains", "com.google.androidstudio"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "design",
            displayName: "设计创作",
            description: "UI/UX 设计、图片编辑、视频剪辑、音频制作、3D 建模、字体工具",
            tier: .core,
            keywords: ["figma", "sketch", "photoshop", "illustrator", "lightroom", "pixelmator", "blender", "cinema", "premiere", "after effects", "final cut"],
            bundleIDPatterns: ["com.adobe", "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.blackmagic-design"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "productivity",
            displayName: "办公效率",
            description: "文档编辑、笔记、表格、演示、项目管理、日历、邮件客户端",
            tier: .core,
            keywords: ["notion", "obsidian", "excel", "word", "powerpoint", "numbers", "keynote", "calendar", "things", "fantastical", "microsoft", "project"],
            bundleIDPatterns: ["com.microsoft.Excel", "com.microsoft.Word", "com.microsoft.Powerpoint", "com.apple.iWork"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "communication",
            displayName: "沟通协作",
            description: "即时通讯、视频会议、团队协作、社交网络",
            tier: .core,
            keywords: ["wechat", "slack", "discord", "zoom", "teams", "telegram", "mail", "whatsapp", "signal", "messenger"],
            bundleIDPatterns: ["com.tencent.xinWeChat", "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.microsoft.teams"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "utility",
            displayName: "系统工具",
            description: "macOS 系统组件、清理工具、监控、启动器、文件管理、输入法、系统偏好设置",
            tier: .core,
            keywords: ["clean", "monitor", "alfred", "raycast", "finder", "system settings", "activity monitor", "input", "输入法"],
            bundleIDPatterns: ["com.apple.systempreferences", "com.apple.finder", "com.runningwithcrayons.Alfred", "com.qianying.InputMethod"],
            knownSigners: ["59GAB85EFG"] // Apple known teamID
        ),
        CategoryDefinition(
            id: "browser",
            displayName: "网络浏览",
            description: "浏览器、下载管理器、代理工具、VPN",
            tier: .extended,
            keywords: ["safari", "chrome", "firefox", "downie", "surge", "edge", "brave", "arc", "opera", "proxy", "vpn"],
            bundleIDPatterns: ["com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.qspace.Downie"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "security",
            displayName: "安全隐私",
            description: "密码管理、杀毒软件、加密工具、防火墙、隐私保护",
            tier: .extended,
            keywords: ["1password", "bitwarden", "little snitch", "antivirus", "firewall", "encryption", "密码"],
            bundleIDPatterns: ["com.bitwarden.desktop", "com.agilebits.onepassword", "com.obdev.LittleSnitch"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "entertainment",
            displayName: "影音娱乐",
            description: "音乐播放、视频播放、游戏、直播、播客",
            tier: .core,
            keywords: ["music", "tv", "video", "steam", "game", "vlc", "spotify", "iina", "netflix", "podcast"],
            bundleIDPatterns: ["com.spotify.client", "de.christian-kohler.vlc", "com.valvesoftware.steam", "com.colliderli.iina"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "reading",
            displayName: "阅读教育",
            description: "电子书阅读、学习工具、翻译、文献管理",
            tier: .extended,
            keywords: ["kindle", "marginnote", "zotero", "有道词典", "翻译", "book", "read", "pdf reader"],
            bundleIDPatterns: ["com.amazon.Kindle", "org.zotero.zotero", "com.neteasenews"],
            knownSigners: []
        ),
        CategoryDefinition(
            id: "finance",
            displayName: "金融理财",
            description: "记账、股票、银行、支付",
            tier: .extended,
            keywords: ["支付宝", "随手记", "股票", "bank", "ledger", "accounting", "finance"],
            bundleIDPatterns: ["com.alipay"],
            knownSigners: []
        ),
    ]

    static func allDisplayNames() -> [String] {
        standard.map(\.displayName)
    }

    static func description(for category: String) -> String {
        standard.first { $0.displayName == category }?.description ?? ""
    }

    static func allKeywords() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for cat in standard {
            map[cat.displayName] = cat.keywords
        }
        return map
    }
}

// MARK: - 搜索别名注册表

/// 中英文类别别名映射：英文查询匹配中文类别
struct SearchAliasRegistry {
    static let categoryAliases: [String: [String]] = [
        "开发工具": ["开发", "编程", "代码", "developer", "development", "dev", "dev tools", "ide", "editor", "compiler", "build", "coding", "工程", "软件"],
        "设计创作": ["设计", "创作", "绘图", "图形", "ui", "ux", "design", "creative", "graphic", "photo", "illustration", "3d", "建模"],
        "办公效率": ["办公", "效率", "笔记", "文档", "表格", "演示", "productivity", "office", "note", "notes", "document", "spreadsheet", "presentation", "calendar"],
        "沟通协作": ["沟通", "协作", "聊天", "通讯", "社交", "消息", "通话", "communication", "chat", "message", "messaging", "social", "call", "meeting", "collab", "team"],
        "系统工具": ["系统", "工具", "清理", "监控", "设置", "启动器", "utility", "utilities", "system", "system tool", "cleaner", "monitor", "launcher", "settings"],
        "网络浏览": ["浏览", "浏览器", "上网", "网页", "下载", "代理", "browser", "web", "internet", "download", "proxy", "vpn", "surf", "网络"],
        "安全隐私": ["安全", "隐私", "密码", "加密", "杀毒", "防火墙", "security", "privacy", "password", "encryption", "antivirus", "firewall", "safe", "protection", "2fa"],
        "影音娱乐": ["娱乐", "影音", "游戏", "音乐", "视频", "播放", "休闲", "entertainment", "media", "game", "gaming", "music", "video", "player", "streaming", "movie", "影视"],
        "阅读教育": ["阅读", "教育", "学习", "电子书", "翻译", "词典", "reading", "education", "learning", "ebook", "book", "translate", "dictionary", "study", "文献", "pdf"],
        "金融理财": ["金融", "理财", "记账", "股票", "银行", "支付", "钱包", "finance", "financial", "banking", "bank", "stock", "payment", "accounting", "ledger", "budget", "投资"],
    ]

    /// 查询令牌解析为类别名称
    static func resolveCategoryAlias(_ token: String) -> String? {
        let lower = token.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }

        // 精确匹配
        for (displayName, aliases) in categoryAliases {
            if aliases.contains(lower) {
                return displayName
            }
        }

        // 部分匹配（令牌较长时）
        if lower.count >= 2 {
            for (displayName, aliases) in categoryAliases {
                for alias in aliases where alias.count >= 2 {
                    if lower.contains(alias) || alias.contains(lower) {
                        return displayName
                    }
                }
            }
        }

        return nil
    }

    static let allAliasSet: Set<String> = {
        var set = Set<String>()
        for aliases in categoryAliases.values {
            set.formUnion(aliases)
        }
        return set
    }()
}
