import Foundation

/// 意图检测器：从查询中识别用户意图，用于硬过滤和评分调整
struct IntentDetector {

    /// 检测查询中的意图过滤器
    static func detectIntents(from query: String) -> [IntentFilter] {
        let lower = query.lowercased()
        let tokens = tokenize(lower)
        var intents: [IntentFilter] = []

        if tokensContainsAny(tokens, of: ["后台", "常驻", "background", "resident", "后台运行", "后台的"]) {
            intents.append(.background)
        }
        if tokensContainsAny(tokens, of: ["占用大", "资源消耗", "heavy", "cpu高", "内存大", "吃资源", "资源占用", "卡顿", "slow", "占用大的", "高cpu", "高内存"]) {
            intents.append(.heavyResource)
        }
        if tokensContainsAny(tokens, of: ["未签名", "unsigned", "风险", "高风险", "不安全", "risk", "trust", "未签名的"]) {
            intents.append(.unsignedHighRisk)
        }
        if tokensContainsAny(tokens, of: ["摄像头", "camera", "摄像", "相机", "拍摄", "录像", "拍照"]) {
            intents.append(.hasPermission(.camera))
        }
        if tokensContainsAny(tokens, of: ["麦克风", "microphone", "录音", "mic", "语音", "话筒"]) {
            intents.append(.hasPermission(.microphone))
        }
        if tokensContainsAny(tokens, of: ["录屏", "screen recording", "截屏", "屏幕", "屏幕录制", "抓屏"]) {
            intents.append(.hasPermission(.screenRecording))
        }
        if tokensContainsAny(tokens, of: ["全盘", "full disk", "磁盘访问", "全部文件", "完整磁盘"]) {
            intents.append(.hasPermission(.fullDiskAccess))
        }
        if tokensContainsAny(tokens, of: ["辅助功能", "accessibility", "自动化控制", "操控"]) {
            intents.append(.hasPermission(.accessibility))
        }
        if tokensContainsAny(tokens, of: ["系统应用", "系统自带", "macos自带", "system", "apple", "苹果自带"]) {
            intents.append(.isSystem)
        }
        if tokensContainsAny(tokens, of: ["app store", "appstore", "商店应用", "商店下载"]) {
            intents.append(.isAppStore)
        }
        if tokensContainsAny(tokens, of: ["第三方", "third party", "third-party", "外部"]) {
            intents.append(.isThirdParty)
        }

        return intents
    }

    /// 判断应用是否满足所有意图条件
    static func appMatchesIntents(_ app: AppRecord, intents: [IntentFilter]) -> Bool {
        guard !intents.isEmpty else { return true }

        for intent in intents {
            switch intent {
            case .background:
                if !app.permissions.backgroundResident { return false }
            case .heavyResource:
                if app.metrics.cpuPercent < 5.0 && app.metrics.memoryMB < 500 { return false }
            case .unsignedHighRisk:
                if app.signature.trustLevel != .unsignedHighRisk { return false }
            case .hasPermission(let kind):
                if !app.permissions.requested.contains(kind) { return false }
            case .isSystem:
                if app.source != .system { return false }
            case .isAppStore:
                if app.source != .appStore { return false }
            case .isThirdParty:
                if app.source != .thirdParty { return false }
            }
        }
        return true
    }

    /// 检测查询意图类型
    static func detectIntent(query: String, knownAppNames: Set<String>) -> SearchIntent {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 精确名称匹配（优先级最高）
        if knownAppNames.contains(where: { $0.lowercased() == lower }) {
            return .specificName
        }

        // 名称别名匹配（如 "wechat" → "微信"）
        let aliasStore = AppNameAliasStore()
        let aliases = aliasStore.aliases(for: lower)
        if aliases.contains(where: { aliasName in
            knownAppNames.contains(where: { $0.lowercased() == aliasName.lowercased() })
        }) {
            return .specificName
        }

        // 类别匹配
        if SearchAliasRegistry.resolveCategoryAlias(lower) != nil {
            return .category
        }

        let actionKeywords = ["清理", "卸载", "删除", "关闭", "打开", "启动", "停止"]
        if actionKeywords.contains(where: { lower.contains($0) }) {
            return .action
        }
        return .general
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                if char.unicodeScalars.contains(where: { $0.value > 0x4E00 && $0.value < 0x9FFF }) {
                    tokens.append(String(char))
                }
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func tokensContainsAny(_ tokens: [String], of candidates: [String]) -> Bool {
        let joined = tokens.joined(separator: "")
        for candidate in candidates {
            if tokens.contains(candidate) || joined.contains(candidate) {
                return true
            }
        }
        return false
    }
}
