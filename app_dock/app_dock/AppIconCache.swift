import AppKit

final class AppIconCache {
    static let shared = AppIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private let preloadQueue = DispatchQueue(label: "appdock.icon-preload", qos: .utility)

    private init() {
        cache.countLimit = 500
    }

    func icon(for path: String) -> NSImage {
        cachedOrLoadIcon(for: path, size: nil)
    }

    func icon(for path: String, size: CGFloat) async -> NSImage {
        if let cached = cachedIcon(for: path, size: size) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            preloadQueue.async {
                let image = self.cachedOrLoadIcon(for: path, size: size)
                continuation.resume(returning: image)
            }
        }
    }

    func preload(paths: [String], sizes: [CGFloat]) {
        let workItems = paths.flatMap { path in
            sizes.map { (path: path, size: $0) }
        }
        .filter { cachedIcon(for: $0.path, size: $0.size) == nil }

        guard !workItems.isEmpty else { return }
        preloadQueue.async {
            for item in workItems {
                _ = self.cachedOrLoadIcon(for: item.path, size: item.size)
            }
        }
    }

    private func cachedIcon(for path: String, size: CGFloat?) -> NSImage? {
        cache.object(forKey: cacheKey(path: path, size: size))
    }

    private func cachedOrLoadIcon(for path: String, size: CGFloat?) -> NSImage {
        let key = cacheKey(path: path, size: size)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        if let size {
            image.size = NSSize(width: size, height: size)
        }
        cache.setObject(image, forKey: key)
        return image
    }

    private func cacheKey(path: String, size: CGFloat?) -> NSString {
        guard let size else { return path as NSString }
        return "\(path)#\(Int(size.rounded()))" as NSString
    }
}
