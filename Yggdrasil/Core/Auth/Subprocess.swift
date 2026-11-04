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

    /// Terminate the child and throw `CancellationError` when the calling task
    /// is cancelled. Off by default: most callers (worktree creation from a
    /// SwiftUI `.task`, say) must not have a git command killed halfway. The
    /// status poller turns it on so its probe deadline actually holds.
    var terminatesOnCancel = false

    func run(executable: String, arguments: [String]) async throws -> SubprocessResult {
        guard terminatesOnCancel else {
            return try await launch(executable: executable, arguments: arguments, cancel: nil)
        }
        let cancel = CancelHandle()
        return try await withTaskCancellationHandler {
            try await launch(executable: executable, arguments: arguments, cancel: cancel)
        } onCancel: {
            cancel.cancel()
        }
    }

    private func launch(
        executable: String, arguments: [String], cancel: CancelHandle?
    ) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            SubprocessResult,
            Swift.Error
        >) in
            // Already cancelled: don't start anything (nor the pipe readers,
            // whose final drain would wait on a write end nobody closes).
            if cancel?.isCancelled == true {
                continuation.resume(throwing: CancellationError())
                return
            }
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
            //
            // Each reader serializes the handler's `availableData` and the
            // terminationHandler's final drain under one lock, so the same
            // descriptor is never read from two threads at once. Previously the
            // terminationHandler called `readDataToEndOfFile` while an in-flight
            // readability callback was still reading the same fd — that race
            // intermittently truncated or dropped output.
            let stdoutReader = PipeReader(handle: stdoutPipe.fileHandleForReading)
            let stderrReader = PipeReader(handle: stderrPipe.fileHandleForReading)

            process.terminationHandler = { proc in
                if cancel?.isCancelled == true {
                    // Don't drain: ssh via a ControlMaster leaves its pipes
                    // with the mux master, open until the remote command ends.
                    stdoutReader.abandon()
                    stderrReader.abandon()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let result = SubprocessResult(
                    stdout: String(data: stdoutReader.finish(), encoding: .utf8) ?? "",
                    stderr: String(data: stderrReader.finish(), encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Error.launchFailed(underlying: error))
                return
            }
            // Cancelled between the check above and the launch.
            if let cancel, !cancel.register(process) {
                process.terminate()
            }
        }
    }
}

/// Links a task's cancellation to the child it's waiting on. Cancellation can
/// land before, during or after the launch; the lock orders it against
/// `register`, so whichever side comes second does the terminate.
private final class CancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    /// Records the launched child. False when the task was already cancelled,
    /// in which case the caller terminates it.
    func register(_ launched: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        process = launched
        return !cancelled
    }
}

/// Accumulates one pipe's output. Installs a `readabilityHandler` to drain
/// continuously (avoiding the 64 KB-buffer deadlock), and a `finish()` for the
/// terminationHandler to collect the remainder. Both paths take the same lock,
/// so the descriptor is never read concurrently — the readability callback and
/// the final drain can't race and truncate output.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [self] fileHandle in
            lock.lock()
            defer { lock.unlock() }
            // A callback can still be dispatched after finish() ran; ignore it.
            guard !finished else { fileHandle.readabilityHandler = nil
                return
            }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil // EOF
            } else {
                buffer.append(chunk)
            }
        }
    }

    /// Stop reading without waiting for EOF, for a cancelled run whose output
    /// is discarded anyway. Another process may still hold the write end.
    func abandon() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        handle.readabilityHandler = nil
        try? handle.close()
    }

    /// Called once from the terminationHandler. Waits out any in-flight
    /// readability callback (same lock), then drains whatever remains. The
    /// process has already exited here, so the read reaches EOF promptly.
    func finish() -> Data {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        handle.readabilityHandler = nil
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty { buffer.append(remaining) }
        return buffer
    }
}
