import Foundation

nonisolated struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var failureMessage: String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Command failed with exit code \(status)." : message
    }
}

nonisolated enum ProcessRunner {
    /// Runs an executable and collects its output. Cancelling the calling task terminates the process.
    ///
    /// Output goes to temporary files instead of pipes: an ssh ControlPersist master forks into the
    /// background and keeps the inherited stderr open, which would make reading a pipe to EOF hang.
    static func run(_ executable: String,
                    _ arguments: [String],
                    environment: [String: String] = [:]) async throws -> ProcessResult {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try runBlocking(handle, executable, arguments, environment)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func runBlocking(_ handle: ProcessHandle,
                                    _ executable: String,
                                    _ arguments: [String],
                                    _ environment: [String: String]) throws -> ProcessResult {
        let process = handle.process
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "sshmgr-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        fileManager.createFile(atPath: outURL.path, contents: nil)
        fileManager.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: outURL)
            try? fileManager.removeItem(at: errURL)
        }

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        try handle.launch()
        process.waitUntilExit()
        try handle.checkCancellation()

        // Lossy decoding: one file name that isn't valid UTF-8 mustn't discard the whole output.
        let stdout = (try? Data(contentsOf: outURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let stderr = (try? Data(contentsOf: errURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// Shares a `Process` between the worker thread and the cancellation handler.
///
/// The lock closes the gap where cancellation arrives after the task started but before
/// the process launched: either the launch sees the cancelled flag, or `cancel()` sees
/// the running process and terminates it.
private nonisolated final class ProcessHandle: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var isCancelled = false

    func launch() throws {
        try lock.withLock {
            if isCancelled { throw CancellationError() }
            try process.run()
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    func checkCancellation() throws {
        if lock.withLock({ isCancelled }) { throw CancellationError() }
    }
}
