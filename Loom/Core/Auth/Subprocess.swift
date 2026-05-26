import Foundation

/// Result of a finished subprocess invocation. UTF-8 by convention; non-UTF-8 bytes
/// are dropped to `""` rather than failing, since `gh` and friends always emit UTF-8.
struct SubprocessResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// Protocol so tests can inject a stub without spawning a real process.
protocol SubprocessRunner: Sendable {
    func run(executable: String, arguments: [String]) async throws -> SubprocessResult
}

/// Production implementation that spawns the real binary via `Foundation.Process`.
struct ProcessRunner: SubprocessRunner {
    enum Error: Swift.Error {
        case launchFailed(underlying: Swift.Error)
    }

    func run(executable: String, arguments: [String]) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            SubprocessResult,
            Swift.Error
        >) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = SubprocessResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Error.launchFailed(underlying: error))
            }
        }
    }
}
