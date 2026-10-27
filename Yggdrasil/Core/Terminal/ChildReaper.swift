import Darwin
import Foundation

/// Collects a child process we've signalled to stop.
///
/// An agent is SIGTERMed and its terminal view torn down in the same breath
/// (close, restart, move). SwiftTerm's exit watcher goes with the view, so the
/// child exited unobserved and stayed a zombie until the app quit — a week of
/// closing tabs left dozens. Polling `waitpid(pid, WNOHANG)` for that one pid
/// is safe: while the child is a zombie its pid can't be reused, and ECHILD
/// means someone else (SwiftTerm, when it was still watching) collected it.
enum ChildReaper {
    /// Polls until `pid` is collected. Returns false if it was still running
    /// at `timeout` (the caller's SIGKILL normally lands well before that).
    @discardableResult
    static func reap(_ pid: pid_t, timeout: Duration = .seconds(30)) async -> Bool {
        guard pid > 0 else { return true }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return true }
            if result == -1, errno != EINTR { return true } // ECHILD: already collected
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// SIGTERM, then SIGKILL after `grace`, collecting the child either way.
    /// The SIGKILL only goes out while `waitpid` still reports the child
    /// running, i.e. while the pid is still ours: a plain "kill after 5s"
    /// could hit an unrelated process that reused the pid of an agent that
    /// had already exited and been collected.
    @discardableResult
    static func stop(_ pid: pid_t, grace: Duration = .seconds(5)) async -> Bool {
        guard pid > 0 else { return true }
        // Already collected (an agent that exited earlier): its pid may have
        // been reused by now, so don't signal it at all.
        if collectedOrGone(pid) { return true }
        kill(pid, SIGTERM)
        if await reap(pid, timeout: grace) { return true }
        kill(pid, SIGKILL)
        return await reap(pid, timeout: .seconds(5))
    }

    /// One non-blocking `waitpid`: true once `pid` is collected (now or
    /// earlier, by anyone), false while it's still our running child.
    private static func collectedOrGone(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == pid || (result == -1 && errno != EINTR)
    }

    /// Fire-and-forget `stop`, for the UI paths that end an agent.
    static func stopInBackground(_ pid: pid_t) {
        guard pid > 0 else { return }
        Task.detached(priority: .utility) {
            if await !stop(pid) {
                YggdrasilLog.pty.warning("Child pid=\(pid, privacy: .public) survived SIGKILL; not reaped")
            }
        }
    }
}
