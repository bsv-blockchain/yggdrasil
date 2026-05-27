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

            // Drain pipes continuously rather than only in terminationHandler.
            // A child writing > 64 KB (the macOS pipe buffer default) before
            // exiting would otherwise deadlock against the parent, which doesn't
            // read until termination.
            let stdoutAccumulator = PipeAccumulator()
            let stderrAccumulator = PipeAccumulator()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF — closing the pipe ends the read loop.
                    handle.readabilityHandler = nil
                } else {
                    stdoutAccumulator.append(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrAccumulator.append(chunk)
                }
            }

            process.terminationHandler = { proc in
                // Drain any data sitting in the pipe at the moment of termination.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingOut.isEmpty { stdoutAccumulator.append(remainingOut) }
                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErr.isEmpty { stderrAccumulator.append(remainingErr) }
                let result = SubprocessResult(
                    stdout: String(data: stdoutAccumulator.data, encoding: .utf8) ?? "",
                    stderr: String(data: stderrAccumulator.data, encoding: .utf8) ?? "",
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

/// Thread-safe Data accumulator for the pipe readability handlers, which fire
/// on a background queue.
private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
