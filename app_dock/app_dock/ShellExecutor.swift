import Foundation

protocol ShellExecuting {
    func run(_ launchPath: String, _ arguments: [String]) async -> String
}

struct ShellExecutor: ShellExecuting {
    func run(_ launchPath: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.terminationHandler = { _ in
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
