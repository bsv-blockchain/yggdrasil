import Foundation

/// When a remote tab's ssh dies, tell a dropped connection (reattach to the
/// still-running agent) from the agent itself exiting (show the exit banner).
enum ReconnectPolicy {
    /// ssh's own exit status for connection and auth failures. The agent's
    /// exit status is passed through, and dtach exits 0 when the agent ends.
    static let sshTransportFailure: Int32 = 255

    static func shouldReconnect(isRemote: Bool, exitCode: Int32?) -> Bool {
        guard isRemote, let exitCode else { return false }
        return exitStatus(exitCode) == sshTransportFailure
    }

    /// SwiftTerm's macOS child monitor reports the raw `waitpid` status
    /// (code << 8) while its other spawn path reports the plain code. Decode
    /// either. A plain code that's a multiple of 128 would be misread, which
    /// is harmless here: none of them is 255.
    static func exitStatus(_ code: Int32) -> Int32 {
        code & 0x7F == 0 ? (code >> 8) & 0xFF : code
    }

    /// 255 also covers auth failure, a changed host key or a host that's
    /// gone, which retrying won't fix. About 2.5 minutes of tries, then the
    /// tab shows the normal exit banner (Resume Session retries by hand).
    static let maxAttempts = 8

    static func shouldGiveUp(attempt: Int) -> Bool {
        attempt >= maxAttempts
    }

    /// 1, 2, 4, 8, 16, then every 30s.
    static func delaySeconds(attempt: Int) -> Int {
        min(30, 1 << min(attempt, 5))
    }
}
