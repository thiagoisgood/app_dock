import Foundation

struct UninstallPreview: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let candidates: [String]
}

struct UpdateSuggestion: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let status: String
    let sourceHint: String
}

struct UninstallService {
    private let policy = CapabilityPolicy.current

    func preview(app: AppRecord) -> UninstallPreview {
        guard policy.isEnabled(.uninstallDelete) else {
            return UninstallPreview(appName: app.name, candidates: ["unavailable: 当前构建禁用卸载残留扫描"])
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let bundleKey = app.bundleID ?? app.name
        let targets = [
            "\(home)/Library/Application Support/\(app.name)",
            "\(home)/Library/Caches/\(bundleKey)",
            "\(home)/Library/Preferences/\(bundleKey).plist",
            "\(home)/Library/Logs/\(app.name)"
        ]
        let existing = targets.filter { fm.fileExists(atPath: $0) }
        return UninstallPreview(appName: app.name, candidates: existing)
    }
}

struct UpdateAdvisorService {
    private let shell = ShellExecutor()
    private let policy = CapabilityPolicy.current

    func suggest(for apps: [AppRecord]) async -> [UpdateSuggestion] {
        guard policy.isEnabled(.updateProbe) else {
            return [UpdateSuggestion(appName: "系统策略", status: "不可用", sourceHint: "当前构建禁用更新探测")]
        }
        let thirdParty = apps.filter { $0.source == .thirdParty }
        let casksOutput = await shell.run("/bin/zsh", ["-lc", "brew list --cask 2>/dev/null || true"])
        let casks = Set(casksOutput.split(separator: "\n").map { String($0).lowercased() })

        return thirdParty.prefix(30).map { app in
            let token = app.name.lowercased().replacingOccurrences(of: " ", with: "")
            if casks.contains(token) {
                return UpdateSuggestion(appName: app.name, status: "可更新", sourceHint: "Homebrew Cask")
            }
            return UpdateSuggestion(appName: app.name, status: "需手动检查", sourceHint: "官网")
        }
    }
}
