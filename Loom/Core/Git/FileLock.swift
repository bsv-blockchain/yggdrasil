import Darwin
import Foundation

/// POSIX advisory file lock (`flock(2)`) wrapper. Async-friendly: uses LOCK_NB +
/// `Task.sleep` retry so a contending caller doesn't wedge a cooperative thread.
/// This matters when the lock is held across an `await` inside an actor — a
/// blocking `flock(LOCK_EX)` would deadlock the second caller against itself.
///
/// Used by `WorktreeManager` to serialise worktree-mutating operations on the
/// same repo across multiple Loom instances or external git tooling. Within a
/// single process the actor's isolation already serialises calls; the flock adds
/// cross-process protection.
final class FileLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Open the lockfile at `url` (creating it if missing) and acquire an
    /// exclusive lock. Polls every `pollInterval` until acquired or `timeout`
    /// elapses (throws `.lockTimeout` on deadline). The poll yields the thread
    /// via `Task.sleep`, so other actor messages can interleave between attempts.
    static func acquireExclusive(
        at url: URL,
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(20)
    ) async throws -> FileLock {
        // Ensure the parent directory exists.
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw FileLockError.openFailed(errno: errno, path: url.path)
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let result = flock(descriptor, LOCK_EX | LOCK_NB)
            if result == 0 {
                return FileLock(descriptor: descriptor)
            }
            // EWOULDBLOCK / EAGAIN: someone else holds the lock. Yield and retry.
            if errno == EWOULDBLOCK || errno == EAGAIN {
                if ContinuousClock.now >= deadline {
                    close(descriptor)
                    throw FileLockError.timedOut(path: url.path)
                }
                try await Task.sleep(for: pollInterval)
                continue
            }
            // Other errors are fatal.
            let capturedErrno = errno
            close(descriptor)
            throw FileLockError.flockFailed(errno: capturedErrno, path: url.path)
        }
    }

    /// Release the lock and close the descriptor. Idempotent.
    func release() {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }
}

enum FileLockError: Error, Equatable {
    case openFailed(errno: Int32, path: String)
    case flockFailed(errno: Int32, path: String)
    case timedOut(path: String)
}
