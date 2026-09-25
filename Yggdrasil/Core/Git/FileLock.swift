import Darwin
import Foundation

/// POSIX advisory file lock (`flock(2)`) wrapper. Async-friendly: uses LOCK_NB +
/// `Task.sleep` retry so a contending caller doesn't wedge a cooperative thread.
/// This matters when the lock is held across an `await` inside an actor — a
/// blocking `flock(LOCK_EX)` would deadlock the second caller against itself.
///
/// Used by `WorktreeManager` to serialise worktree-mutating operations on the
/// same repo across multiple Yggdrasil instances or external git tooling. Within a
/// single process the actor's isolation already serialises calls; the flock adds
/// cross-process protection.
///
/// **Not thread-safe.** `isReleased` is unsynchronised, which is only sound
/// because the sole consumer holds the lock in a local inside an actor method
/// and releases it in a `defer` — no second reference exists to race with. Don't
/// store one in a property or hand it across isolation domains without adding
/// synchronisation first.
final class FileLock {
    private let descriptor: Int32
    /// `WorktreeManager` releases in a `defer` and `deinit` releases again, so
    /// without this the second call ran `close()` on a descriptor number the
    /// process had already reused for something else.
    private var isReleased = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    #if DEBUG
        /// Exposed so the tests can check the descriptor's flags and whether it
        /// survives exec. Debug-only so app code can't reach for a raw fd.
        var descriptorForTesting: Int32 {
            descriptor
        }
    #endif

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

        // O_CLOEXEC is load-bearing. An flock belongs to the open file
        // description, and `fork` shares it — so an agent PTY spawned while
        // this lock was held inherited the descriptor and kept the repo locked
        // for the whole life of that session, timing out every later tab in
        // that repo. Closing on exec is what stops the child inheriting it.
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            // Captured before building the error: `url.path` allocates, and an
            // allocation can clobber errno. `flockFailed` below does the same.
            let capturedErrno = errno
            throw FileLockError.openFailed(errno: capturedErrno, path: url.path)
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
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    // Cancelled mid-poll. Nothing owns `descriptor` yet — no
                    // FileLock exists to release it — so close it here or it
                    // leaks for the life of the app. Reachable: `ensure` runs
                    // from UI-driven tasks that get cancelled, and the poll
                    // loop only runs when another holder is contending.
                    close(descriptor)
                    throw error
                }
                continue
            }
            // Other errors are fatal.
            let capturedErrno = errno
            close(descriptor)
            throw FileLockError.flockFailed(errno: capturedErrno, path: url.path)
        }
    }

    /// Release the lock and close the descriptor. Idempotent — and it has to
    /// be, since callers release in a `defer` and `deinit` releases again.
    func release() {
        guard !isReleased else { return }
        isReleased = true
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
