import Foundation

enum AppCategory: String, CaseIterable, Codable {
    case development = "开发工具"
    case design = "设计创作"
    case productivity = "办公效率"
    case communication = "沟通协作"
    case utility = "系统工具"
    case entertainment = "娱乐影音"
    case other = "其他"
}

struct AppCategoryClassifier {
    func category(for app: AppRecord) -> AppCategory {
        let name = app.name.lowercased()
        let bundle = (app.bundleID ?? "").lowercased()
        let path = app.path.lowercased()
        let haystack = [name, bundle, path].joined(separator: " ")

        if containsAny(haystack, keys: ["xcode", "cursor", "code", "terminal", "iterm", "docker", "git", "simulator"]) {
            return .development
        }
        if containsAny(haystack, keys: ["figma", "sketch", "photoshop", "illustrator", "lightroom", "pixelmator"]) {
            return .design
        }
        if containsAny(haystack, keys: ["notion", "obsidian", "excel", "word", "powerpoint", "numbers", "keynote", "calendar"]) {
            return .productivity
        }
        if containsAny(haystack, keys: ["wechat", "slack", "discord", "zoom", "teams", "telegram", "mail"]) {
            return .communication
        }
        if containsAny(haystack, keys: ["clean", "monitor", "alfred", "raycast", "finder", "system settings", "activity monitor"]) {
            return .utility
        }
        if containsAny(haystack, keys: ["music", "tv", "video", "steam", "game", "vlc", "spotify"]) {
            return .entertainment
        }
        return .other
    }

    private func containsAny(_ text: String, keys: [String]) -> Bool {
        keys.contains { text.contains($0) }
    }
}
