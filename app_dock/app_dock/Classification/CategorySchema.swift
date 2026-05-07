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
