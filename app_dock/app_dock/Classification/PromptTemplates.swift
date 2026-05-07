import Foundation

/// 版本化提示词模板
enum PromptTemplates {
    static let currentVersion = "v3"

    // MARK: - 分类任务系统提示词

    static func classificationSystemPrompt() -> String {
        """
        你是一位资深 macOS 系统管理员，精通 Apple 生态。请将以下应用归入最合适的类别。

        ## 可用类别（必须从以下列表中选择 exact match）
        - 开发工具: IDE、编译器、终端、数据库工具、版本控制、容器化、调试器
        - 设计创作: UI/UX 设计、图形编辑、视频剪辑、音频制作、3D 建模、字体工具
        - 办公效率: 文档编辑、表格、演示、笔记、项目管理、日历、邮件客户端
        - 沟通协作: 即时通讯、视频会议、团队协作、社交网络
        - 系统工具: macOS 系统组件、清理工具、监控、启动器、文件管理、输入法、系统偏好设置
        - 网络浏览: 浏览器、下载管理器、代理工具、VPN
        - 安全隐私: 密码管理、杀毒软件、加密工具、防火墙、隐私保护
        - 影音娱乐: 音乐播放、视频播放、游戏、直播、播客
        - 阅读教育: 电子书阅读、学习工具、翻译、文献管理
        - 金融理财: 记账、股票、银行、支付

        ## 判断依据（按优先级）
        1. Bundle ID 前缀: com.apple.dt.* → 开发工具, com.adobe.* → 设计创作
        2. 签名 teamID: 已知企业签名者（如 Apple 59GAB85EFG → 系统工具）
        3. 权限组合: 摄像头+麦克风 → 沟通协作或影音娱乐; 屏幕录制 → 系统工具或开发工具
        4. 后台常驻 + 高CPU → 系统工具（服务进程）
        5. 来源: macOS系统自带 → 系统工具
        6. 不确定时归入"其他"
        """
    }

    static func classificationUserPrompt(appEntries: String) -> String {
        """
        请对以下 macOS 应用进行分类。

        ## 输出要求
        - 返回纯 JSON 数组，不要其他文字或 markdown
        - 每个元素: {"name": "应用显示名", "bundleID": "com.example.app", "category": "精确类别名", "confidence": 0.0-1.0}
        - confidence 是你对该分类的确定程度，不确定时给 0.5-0.7
        - 如果不确定属于哪个类别，category 设为 "其他"，confidence 设为 0.3

        ## 应用列表
        \(appEntries)
        """
    }

    // MARK: - 分类+标签联合任务

    static func classificationWithTagsSystemPrompt() -> String {
        """
        你是 macOS 应用分类专家。为每个应用：
        1. 归入最合适的类别（从预设列表中选择）
        2. 生成 2-5 个描述用途场景的中文标签

        ## 可用类别
        开发工具、设计创作、办公效率、沟通协作、系统工具、网络浏览、安全隐私、影音娱乐、阅读教育、金融理财
        """
    }

    static func classificationWithTagsUserPrompt(appEntries: String) -> String {
        """
        请对以下 macOS 应用进行分类并生成语义标签。

        ## 输出要求
        - 返回纯 JSON 数组，不要其他文字
        - 格式: {"name": "...", "bundleID": "...", "category": "...", "confidence": 0.85, "tags": ["标签1", "标签2"]}
        - tags 为 2-5 个描述用途场景的中文标签
        - 如果不确定，category 设为 "其他"

        ## 应用列表
        \(appEntries)
        """
    }

    // MARK: - 安全审计任务

    static func securityAuditSystemPrompt() -> String {
        "你是 macOS 应用安全审计助手，回答要简洁可执行。"
    }

    // MARK: - 应用条目构建器

    static func buildAppEntries(for apps: [AppRecord]) -> String {
        apps.map { app in
            let perms = app.permissions.requested.map(\.rawValue).sorted().joined(separator: ",")
            let bgFlag = app.permissions.backgroundResident ? "是" : "否"
            let sourceLabel: String
            switch app.source {
            case .system: sourceLabel = "macOS系统自带"
            case .appStore: sourceLabel = "App Store"
            case .thirdParty: sourceLabel = "第三方"
            case .unknown: sourceLabel = "未知"
            }

            var fields = [
                "\"name\": \"\(app.name)\"",
                "\"bundleID\": \"\(app.bundleID ?? "unknown")\"",
                "\"version\": \"\(app.version)\"",
                "\"source\": \"\(sourceLabel)\"",
                "\"background\": \(bgFlag)",
                "\"permissions\": \"[\(perms)]\"",
            ]

            // 添加 teamID（用于企业签名识别）
            if let teamID = app.signature.teamID {
                fields.append("\"teamID\": \"\(teamID)\"")
            }

            // 添加签名者信息
            if !app.signature.signingAuthority.isEmpty {
                let signer = app.signature.signingAuthority.first ?? ""
                fields.append("\"signer\": \"\(signer)\"")
            }

            // 添加运行时指标（仅异常值）
            if app.metrics.cpuPercent > 10 {
                fields.append("\"cpu\": \(app.metrics.cpuPercent)")
            }
            if app.metrics.memoryMB > 500 {
                fields.append("\"memoryMB\": \(app.metrics.memoryMB)")
            }

            // 添加签名信任级别
            fields.append("\"trustLevel\": \"\(app.signature.trustLevel.rawValue)\"")

            return "  {\n    \(fields.joined(separator: ",\n    "))\n  }"
        }.joined(separator: ",\n")
    }
}
