import Darwin
import Foundation

/// POSIX advisory file lock (`flock(2)`). Used by `WorktreeManager` to serialise
/// worktree-mutating operations on the same repo across multiple Loom instances or
/// external git tooling running concurrently. Within a single process, the actor's
/// own isolation already serialises calls.
///
/// Usage:
/// ```swift
/// let lock = try FileLock.acquireExclusive(at: lockfileURL)
/// defer { lock.release() }
/// // … critical section …
/// ```
final class FileLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Open the lockfile at `url` (creating it if missing) and acquire an exclusive
    /// advisory lock via `flock(LOCK_EX)`. Blocks until the lock is available.
    static func acquireExclusive(at url: URL) throws -> FileLock {
        // Ensure the parent directory exists; the lockfile lives at
        // `<parent>/.worktrees/.loom.lock` per spec §Phase 2.
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw FileLockError.openFailed(errno: errno, path: url.path)
        }

        let result = flock(descriptor, LOCK_EX)
        guard result == 0 else {
            close(descriptor)
            throw FileLockError.flockFailed(errno: errno, path: url.path)
        }
        return FileLock(descriptor: descriptor)
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
}
