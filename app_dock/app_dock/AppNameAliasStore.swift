import Foundation

/// 应用中英文名称对
struct AppNameAlias: Codable {
    let chineseName: String
    let englishName: String
    let bundleID: String?
    var confidence: Double  // AI 置信度 0-1，随反馈调整

    init(chineseName: String, englishName: String, bundleID: String?, confidence: Double = 0.8) {
        self.chineseName = chineseName
        self.englishName = englishName
        self.bundleID = bundleID
        self.confidence = confidence
    }
}

final class AppNameAliasStore {
    private let fileURL: URL
    private var aliases: [AppNameAlias] = []
    private static let builtInAliases: [AppNameAlias] = [
        AppNameAlias(chineseName: "微信", englishName: "WeChat", bundleID: "com.tencent.xinWeChat", confidence: 1.0),
        AppNameAlias(chineseName: "企业微信", englishName: "WeCom", bundleID: "com.tencent.WeWorkMac", confidence: 1.0),
        AppNameAlias(chineseName: "腾讯会议", englishName: "Tencent Meeting", bundleID: "com.tencent.meeting", confidence: 1.0),
        AppNameAlias(chineseName: "飞书", englishName: "Feishu", bundleID: "com.electron.lark", confidence: 0.95),
        AppNameAlias(chineseName: "飞书", englishName: "Lark", bundleID: "com.electron.lark", confidence: 0.95),
        AppNameAlias(chineseName: "钉钉", englishName: "DingTalk", bundleID: "com.alibaba.DingTalkMac", confidence: 0.95),
        AppNameAlias(chineseName: "网易云音乐", englishName: "NeteaseMusic", bundleID: "com.netease.163music", confidence: 0.95),
        AppNameAlias(chineseName: "百度网盘", englishName: "BaiduNetdisk", bundleID: "com.baidu.netdisk", confidence: 0.95),
        AppNameAlias(chineseName: "夸克网盘", englishName: "Quark Cloud Drive", bundleID: "com.quark.desktop", confidence: 0.9),
        AppNameAlias(chineseName: "有道词典", englishName: "Youdao Dict", bundleID: "com.youdao.YoudaoDict", confidence: 0.9),
        AppNameAlias(chineseName: "剪映", englishName: "CapCut", bundleID: "com.lemon.lvpro", confidence: 0.95),
        AppNameAlias(chineseName: "抖音", englishName: "TikTok", bundleID: "com.ss.iphone.ugc.AwemeMac", confidence: 0.85),
        AppNameAlias(chineseName: "小红书", englishName: "RedNote", bundleID: "com.xingin.discover", confidence: 0.9),
        AppNameAlias(chineseName: "哔哩哔哩", englishName: "Bilibili", bundleID: "tv.danmaku.bili", confidence: 0.95),
        AppNameAlias(chineseName: "京东", englishName: "JD", bundleID: "com.jd.JDMobileMac", confidence: 0.85),
        AppNameAlias(chineseName: "淘宝", englishName: "Taobao", bundleID: "com.taobao.taobao4mac", confidence: 0.85),
        AppNameAlias(chineseName: "支付宝", englishName: "Alipay", bundleID: "com.alipay.mac", confidence: 0.9),
        AppNameAlias(chineseName: "高德地图", englishName: "Amap", bundleID: "com.autonavi.amap", confidence: 0.9),
        AppNameAlias(chineseName: "百度地图", englishName: "Baidu Maps", bundleID: "com.baidu.map", confidence: 0.85)
    ]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AppDockAuditEngine")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fileURL = dir.appendingPathComponent("app_name_aliases.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let loaded = try? JSONDecoder().decode([AppNameAlias].self, from: data) {
            aliases = loaded
            print("[NameAlias] Loaded \(aliases.count) name aliases")
        }
    }

    func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(aliases) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func getAliases() -> [AppNameAlias] { mergedAliases() }

    /// 查询名称对应的别名名称列表（用于搜索扩展）
    func aliases(for name: String) -> [String] {
        matchingAliases(for: name).flatMap { [$0.chineseName, $0.englishName] }
            .deduplicated()
            .filter { normalized($0) != normalized(name) }
    }

    /// 查询命中的完整别名记录，供搜索按 BundleID 反向匹配。
    func matchingAliases(for name: String) -> [AppNameAlias] {
        let lower = normalized(name)
        var matchedAliases: [AppNameAlias] = []
        for alias in mergedAliases() {
            let chinese = normalized(alias.chineseName)
            let english = normalized(alias.englishName)
            if chinese == lower || english == lower {
                matchedAliases.append(alias)
            }
            // 也匹配 bundleID
            if let bid = alias.bundleID {
                let bundle = normalized(bid)
                if lower.contains(bundle) || bundle.contains(lower) {
                    matchedAliases.append(alias)
                }
            }
        }
        return matchedAliases.deduplicated { "\($0.chineseName)|\($0.englishName)|\($0.bundleID ?? "")" }
    }

    /// 查询某个应用自身可展开出的中英文别名。
    func aliases(forAppName name: String, bundleID: String?) -> [String] {
        let appName = normalized(name)
        let appBundle = bundleID.map { normalized($0) }
        var results: [String] = []
        for alias in mergedAliases() {
            let chinese = normalized(alias.chineseName)
            let english = normalized(alias.englishName)
            let bundle = alias.bundleID.map { normalized($0) }
            let nameMatched = chinese == appName || english == appName
            let bundleMatched = appBundle != nil && bundle != nil && appBundle == bundle
            if nameMatched || bundleMatched {
                results.append(alias.chineseName)
                results.append(alias.englishName)
            }
        }
        return results.deduplicated().filter { normalized($0) != appName }
    }

    /// 强化或弱化某对映射的置信度
    func reinforce(_ chineseName: String, _ englishName: String, positive: Bool) {
        if let idx = aliases.firstIndex(where: {
            $0.chineseName == chineseName && $0.englishName == englishName
        }) {
            let delta = positive ? 0.05 : -0.1
            aliases[idx] = AppNameAlias(
                chineseName: chineseName,
                englishName: englishName,
                bundleID: aliases[idx].bundleID,
                confidence: max(0.1, min(1.0, aliases[idx].confidence + delta))
            )
        } else if positive {
            // 新映射
            aliases.append(AppNameAlias(chineseName: chineseName, englishName: englishName, bundleID: nil))
        }
        save()
    }

    /// 添加新的名称对
    func addAlias(_ alias: AppNameAlias) {
        if !aliases.contains(where: { $0.chineseName == alias.chineseName && $0.englishName == alias.englishName }) {
            aliases.append(alias)
            save()
        }
    }

    /// 批量更新
    func updateAliases(_ newAliases: [AppNameAlias]) {
        var existing = Dictionary(uniqueKeysWithValues: aliases.map { ($0.chineseName + "|" + $0.englishName, $0) })
        for new in newAliases {
            let key = new.chineseName + "|" + new.englishName
            if let old = existing[key] {
                // 保留高置信度
                let merged = AppNameAlias(
                    chineseName: new.chineseName,
                    englishName: new.englishName,
                    bundleID: new.bundleID ?? old.bundleID,
                    confidence: max(old.confidence, new.confidence)
                )
                existing[key] = merged
            } else {
                existing[key] = new
            }
        }
        aliases = Array(existing.values)
        save()
    }

    func clear() {
        aliases.removeAll()
        save()
    }

    private func mergedAliases() -> [AppNameAlias] {
        (Self.builtInAliases + aliases).deduplicated { "\($0.chineseName)|\($0.englishName)|\($0.bundleID ?? "")" }
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AI 生成

    func generateAliases(for apps: [AppRecord], config: AIProviderConfig) async throws -> [AppNameAlias] {
        let adapter = OpenAICompatibleAdapter()

        let appList = apps.filter { $0.source != .system }
            .map { app in
                let bid = app.bundleID ?? "unknown"
                return "\"\(app.name)\" (BundleID: \(bid))"
            }.joined(separator: ", ")

        let prompt = """
        你是一位 macOS 应用专家。请分析以下应用，为每个应用生成中英文名称对。

        ## 要求
        1. 只返回有明确中英文对应关系的应用
        2. chineseName 是应用的中文显示名
        3. englishName 是对应的英文名称或英文名缩写
        4. 包含 BundleID 以便精确匹配

        ## 应用列表
        \(appList)

        ## 输出格式（纯 JSON 数组）
        [
          {"chineseName": "微信", "englishName": "WeChat", "bundleID": "com.tencent.xinWeChat", "confidence": 0.95},
          {"chineseName": "网易云音乐", "englishName": "NeteaseMusic", "bundleID": "com.netease.163music", "confidence": 0.9}
        ]

        只返回 JSON 数组，不要其他文字。
        """

        let payload = Data("[]".utf8)
        let result = try await adapter.complete(prompt: prompt, payload: payload, config: config)

        var cleanResponse = result.content
        if let fenceStart = cleanResponse.range(of: "```") {
            let after = cleanResponse[fenceStart.upperBound...]
            if let fenceEnd = after.range(of: "```") {
                cleanResponse = String(after[after.startIndex..<fenceEnd.lowerBound])
                if cleanResponse.hasPrefix("json") { cleanResponse = String(cleanResponse.dropFirst(4)) }
            }
        }

        guard let data = cleanResponse.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([AppNameAlias].self, from: data) else {
            print("[NameAlias] Failed to parse AI response")
            return []
        }

        print("[NameAlias] Generated \(parsed.count) name aliases from AI")
        return parsed
    }
}

private extension Array {
    func deduplicated<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        var result: [Element] = []
        for element in self {
            let value = key(element)
            if seen.insert(value).inserted {
                result.append(element)
            }
        }
        return result
    }
}

private extension Array where Element: Hashable {
    func deduplicated() -> [Element] {
        deduplicated { $0 }
    }
}
