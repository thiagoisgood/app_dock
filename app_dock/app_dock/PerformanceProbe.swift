import Foundation

enum PerformanceProbe {
    @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        #if DEBUG
        let start = DispatchTime.now()
        defer { log(name, since: start) }
        return try work()
        #else
        return try work()
        #endif
    }

    static func start(_ name: String) -> DispatchTime {
        #if DEBUG
        print("[Perf] \(name) started")
        #endif
        return DispatchTime.now()
    }

    static func end(_ name: String, from start: DispatchTime) {
        #if DEBUG
        log(name, since: start)
        #endif
    }

    static func mark(_ name: String) {
        #if DEBUG
        print("[Perf] \(name)")
        #endif
    }

    private static func log(_ name: String, since start: DispatchTime) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let milliseconds = Double(elapsed) / 1_000_000
        print("[Perf] \(name): \(String(format: "%.1f", milliseconds))ms")
    }
}
