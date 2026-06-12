import Foundation

final class AppInstallMonitor {
    private struct WatchedSource {
        let descriptor: CInt
        let source: DispatchSourceFileSystemObject
    }

    private let queue = DispatchQueue(label: "appdock.install.monitor", qos: .utility)
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void
    private var watchedSources: [WatchedSource] = []
    private var debounceWorkItem: DispatchWorkItem?

    init(debounceInterval: TimeInterval = 3.5, onChange: @escaping () -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard watchedSources.isEmpty else { return }

        for url in Self.applicationDirectories() {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleNotification()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            watchedSources.append(WatchedSource(descriptor: descriptor, source: source))
            source.resume()
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        watchedSources.forEach { $0.source.cancel() }
        watchedSources.removeAll()
    }

    private func scheduleNotification() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.onChange()
            }
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private static func applicationDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
    }
}
