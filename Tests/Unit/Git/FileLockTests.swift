import Darwin
import XCTest
@testable import Yggdrasil

/// `FileLock` guards worktree mutation per repo. Two properties matter beyond
/// "does it lock", and both were broken:
///
/// 1. The descriptor must be close-on-exec. An flock belongs to the open file
///    description, which `fork` shares — so an agent PTY spawned while the lock
///    was held inherited it and pinned the repo's lock for the life of that
///    session. Every later tab in that repo then timed out.
/// 2. `release()` must be idempotent. `WorktreeManager` releases in a `defer`
///    and `deinit` releases again, so the second call was closing a descriptor
///    number the process had already handed to something else.
final class FileLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filelock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private var lockURL: URL {
        directory.appendingPathComponent(".yggdrasil.lock")
    }

    func testAcquiresOnAFreshPath() async throws {
        let lock = try await FileLock.acquireExclusive(at: lockURL)
        defer { lock.release() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testCreatesTheParentDirectory() async throws {
        let nested = directory.appendingPathComponent("does/not/exist/.yggdrasil.lock")
        let lock = try await FileLock.acquireExclusive(at: nested)
        defer { lock.release() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    // MARK: - The inheritance bug

    /// Without FD_CLOEXEC the descriptor survives `exec`, so every agent the
    /// app spawns while the lock is held keeps holding it afterwards.
    func testDescriptorIsCloseOnExec() async throws {
        let lock = try await FileLock.acquireExclusive(at: lockURL)
        defer { lock.release() }
        let flags = fcntl(lock.descriptorForTesting, F_GETFD)
        XCTAssertNotEqual(flags, -1, "F_GETFD failed")
        XCTAssertEqual(
            flags & FD_CLOEXEC, FD_CLOEXEC,
            "lock descriptor must not survive exec into a spawned agent"
        )
    }

    // MARK: - The double-close bug

    /// The second `release()` must not close a descriptor the process has since
    /// reused. Open a sentinel after releasing, release again, and check the
    /// sentinel is still usable — that is exactly the corruption being guarded.
    func testReleaseIsIdempotentAndDoesNotCloseAReusedDescriptor() async throws {
        let lock = try await FileLock.acquireExclusive(at: lockURL)
        lock.release()

        let sentinelPath = directory.appendingPathComponent("sentinel").path
        let sentinel = open(sentinelPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(sentinel, 0)
        defer { close(sentinel) }

        // Only meaningful if the sentinel actually landed on the descriptor the
        // lock just freed. POSIX promises the lowest free fd, but the test
        // process is multithreaded, so another thread can take it first — skip
        // rather than pass vacuously and claim the bug is covered.
        try XCTSkipUnless(
            sentinel == lock.descriptorForTesting,
            "fd \(lock.descriptorForTesting) was not reused; nothing to prove here"
        )

        lock.release() // must be a no-op, not close(sentinel)

        XCTAssertNotEqual(
            fcntl(sentinel, F_GETFD), -1,
            "a second release() closed an unrelated descriptor"
        )
    }

    /// The flag test above only checks a flag. This checks the behaviour the
    /// bug was actually about: a child that fork/execs must not see the
    /// descriptor. Raw `posix_spawn` (unlike Foundation's `Process`, which sets
    /// POSIX_SPAWN_CLOEXEC_DEFAULT) inherits descriptors, which is what
    /// SwiftTerm's `forkpty` path does.
    func testDescriptorDoesNotSurviveExec() async throws {
        let lock = try await FileLock.acquireExclusive(at: lockURL)
        defer { lock.release() }

        let lockFD = lock.descriptorForTesting
        // Exits 0 when the descriptor is ABSENT in the child.
        let script = "test ! -e /dev/fd/\(lockFD)"
        var pid: pid_t = 0
        let argv: [String] = ["/bin/sh", "-c", script]
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

        let spawned = posix_spawn(&pid, "/bin/sh", nil, nil, &cArgs, environ)
        XCTAssertEqual(spawned, 0, "posix_spawn failed")

        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        let exited = (status & 0x7F) == 0
        let code = (status >> 8) & 0xFF
        XCTAssertTrue(exited, "child did not exit normally")
        XCTAssertEqual(code, 0, "the lock descriptor survived exec into the child")
    }

    // MARK: - Cancellation

    /// Cancelling while the poll loop waits throws out of `acquireExclusive`
    /// before any FileLock owns the descriptor, so nothing else can close it.
    func testCancellationWhilePollingDoesNotLeakTheDescriptor() async throws {
        let incumbent = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(incumbent, 0)
        XCTAssertEqual(flock(incumbent, LOCK_EX | LOCK_NB), 0)
        defer {
            _ = flock(incumbent, LOCK_UN)
            close(incumbent)
        }

        let before = descriptorsOpen(on: lockURL)

        let task = Task {
            try await FileLock.acquireExclusive(
                at: lockURL, timeout: .seconds(30), pollInterval: .milliseconds(10)
            )
        }
        // Let it get past `open` and into the poll loop.
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = try? await task.value

        XCTAssertEqual(
            descriptorsOpen(on: lockURL), before,
            "a cancelled acquire leaked its descriptor"
        )
    }

    /// How many descriptors in this process point at `url`, matched by inode so
    /// unrelated files opened by the test machinery don't count.
    private func descriptorsOpen(on url: URL) -> Int {
        var target = stat()
        guard stat(url.path, &target) == 0 else { return 0 }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return entries.reduce(into: 0) { count, entry in
            guard let candidate = Int32(entry) else { return }
            var info = stat()
            if fstat(candidate, &info) == 0, info.st_ino == target.st_ino, info.st_dev == target.st_dev {
                count += 1
            }
        }
    }

    func testLockIsFreeAfterRelease() async throws {
        let first = try await FileLock.acquireExclusive(at: lockURL)
        first.release()
        let second = try await FileLock.acquireExclusive(at: lockURL, timeout: .milliseconds(200))
        defer { second.release() }
        XCTAssertNotEqual(second.descriptorForTesting, -1)
    }

    // MARK: - Contention

    /// A second holder of the same file must time out rather than sail through.
    /// Uses a raw descriptor for the incumbent, because flock is re-entrant
    /// within one open file description but not across two.
    func testSecondAcquireTimesOutWhileHeld() async throws {
        let incumbent = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(incumbent, 0)
        XCTAssertEqual(flock(incumbent, LOCK_EX | LOCK_NB), 0)
        defer {
            _ = flock(incumbent, LOCK_UN)
            close(incumbent)
        }

        do {
            let lock = try await FileLock.acquireExclusive(
                at: lockURL, timeout: .milliseconds(120), pollInterval: .milliseconds(10)
            )
            lock.release()
            XCTFail("expected a timeout while the lock was held")
        } catch let FileLockError.timedOut(path) {
            XCTAssertEqual(path, lockURL.path)
        }
    }
}
