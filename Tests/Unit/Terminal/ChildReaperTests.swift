import Darwin
import XCTest
@testable import Yggdrasil

/// Stopped agents must be collected. The terminal view that spawned an agent
/// is torn down right after it's signalled, and with it SwiftTerm's exit
/// watcher, so without this every closed or restarted tab left a zombie.
final class ChildReaperTests: XCTestCase {
    /// A real child of this process (Foundation's Process reaps its own).
    private func spawn(_ argv: [String]) throws -> pid_t {
        var pid: pid_t = 0
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }
        // Default signal handling and an empty mask: a child inherits ignored
        // signals, and the test host ignores SIGTERM.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        guard posix_spawn(&pid, argv[0], nil, &attr, cArgs, environ) == 0 else {
            throw XCTSkip("posix_spawn failed")
        }
        return pid
    }

    private func spawnSleep() throws -> pid_t {
        try spawn(["/bin/sleep", "30"])
    }

    /// kill(pid, 0) succeeds for a zombie; only a reaped pid is gone.
    private func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    func testReapsAChildOnceItExits() async throws {
        let pid = try spawnSleep()
        kill(pid, SIGTERM)
        let reaped = await ChildReaper.reap(pid, timeout: .seconds(5))
        XCTAssertTrue(reaped)
        XCTAssertTrue(isGone(pid), "the child is still a zombie")
    }

    func testWaitsForAChildThatTakesAMomentToExit() async throws {
        let pid = try spawnSleep()
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            kill(pid, SIGKILL)
        }
        let reaped = await ChildReaper.reap(pid, timeout: .seconds(5))
        XCTAssertTrue(reaped)
        XCTAssertTrue(isGone(pid))
    }

    func testAChildReapedElsewhereIsFine() async throws {
        let pid = try spawnSleep()
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0) // someone else (SwiftTerm) got there first
        let reaped = await ChildReaper.reap(pid, timeout: .seconds(1))
        XCTAssertTrue(reaped, "already collected counts as done, without hanging")
    }

    func testGivesUpOnAChildThatNeverExits() async throws {
        let pid = try spawnSleep()
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        let reaped = await ChildReaper.reap(pid, timeout: .milliseconds(300))
        XCTAssertFalse(reaped)
    }

    func testStopEscalatesToSIGKILLForAChildThatIgnoresSIGTERM() async throws {
        let pid = try spawn(["/bin/sh", "-c", "trap '' TERM; sleep 30"])
        try? await Task.sleep(for: .milliseconds(200)) // let the trap install
        let stopped = await ChildReaper.stop(pid, grace: .milliseconds(300))
        XCTAssertTrue(stopped)
        XCTAssertTrue(isGone(pid))
    }

    func testStopOfAnAlreadyCollectedChildSignalsNothing() async throws {
        // Closing a tab whose agent exited long ago: its pid may belong to
        // something else by now, so nothing may be signalled.
        let pid = try spawnSleep()
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let started = ContinuousClock.now
        let stopped = await ChildReaper.stop(pid, grace: .seconds(5))
        XCTAssertTrue(stopped)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "returned without a SIGTERM/grace cycle")
    }
}
