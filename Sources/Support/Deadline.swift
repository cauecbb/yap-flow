import Foundation

/// Runs `operation` and returns its result, or nil once `seconds` pass first.
///
/// Not a task group: a group waits for every child before it returns, so an
/// operation stuck on an await that never resumes (Apple's speech analyzer
/// finalizing a session it never started, say) would hold it forever. Here the
/// stuck operation is left behind and its late result dropped.
@MainActor
func withDeadline<T>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        var resumed = false
        let finish: @MainActor (T?) -> Void = { value in
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
        Task { @MainActor in finish(try? await operation()) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            finish(nil)
        }
    }
}

/// A plain text log at ~/Library/Logs/Yap.log with timings and errors, never
/// what was said. The unified log is hard to get at outside Console, and this
/// is what makes "it stopped working" diagnosable.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "com.frigade.yap.diagnostic-log")
    private static let maximumBytes = 512 * 1024

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Yap.log")

    static func write(_ message: String) {
        NSLog("Yap: \(message)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maximumBytes {
                try? manager.removeItem(at: url)
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
