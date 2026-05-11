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

    func getAliases() -> [AppNameAlias] { aliases }

    /// 查询名称对应的别名名称列表（用于搜索扩展）
    func aliases(for name: String) -> [String] {
        let lower = name.lowercased()
        var results: [String] = []
        for alias in aliases {
            if alias.chineseName.lowercased() == lower || alias.englishName.lowercased() == lower {
                results.append(alias.chineseName)
                results.append(alias.englishName)
                if alias.englishName.lowercased() != lower {
                    results.append(alias.englishName)
                }
                if alias.chineseName.lowercased() != lower {
                    results.append(alias.chineseName)
                }
            }
            // 也匹配 bundleID
            if let bid = alias.bundleID, lower.contains(bid.lowercased()) || bid.lowercased().contains(lower) {
                results.append(alias.chineseName)
                results.append(alias.englishName)
            }
        }
        return Array(Set(results)).filter { $0.lowercased() != lower }
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
