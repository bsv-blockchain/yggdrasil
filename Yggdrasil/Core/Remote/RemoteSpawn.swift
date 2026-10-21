import Foundation

/// The local process a remote tab's terminal runs: an interactive ssh that
/// attaches to (or creates) the tab's dtach session through `ygg attach`.
struct RemoteSpawn: Equatable {
    let executable: String
    let args: [String]
    /// Claude session the tab is pinned to, for `session_state`. The helper
    /// decides between `--resume` and `--session-id` on the host, where the
    /// transcript lives.
    let claudeSessionID: String?

    static func make(
        host: RemoteHost,
        session: OpenSession,
        storedSessionID: String?,
        newSessionID: String?,
        colorfgbg: String
    ) -> RemoteSpawn {
        let quote = CodingAgentRunner.shellQuote
        let sessionID = AgentTerminalSurface.pinsClaudeSession(command: session.command, args: session.args)
            ? storedSessionID ?? newSessionID
            : nil
        var parts = [
            "env", "COLORFGBG=\(quote(colorfgbg))", RemoteHelper.path,
            "attach", String(session.id), quote(session.cwd)
        ]
        if let sessionID {
            parts += ["--claude-session", quote(sessionID)]
        }
        // An empty command asks the helper for the user's login shell.
        let argv = session.command.isEmpty ? [] : [session.command] + session.args
        parts += ["--"] + argv.map(quote)
        return RemoteSpawn(
            executable: SSHCommand.executable,
            args: SSHCommand.interactive(
                target: host.sshTarget, remoteCommand: SSHCommand.posixRemote(parts.joined(separator: " ")),
                controlDirectory: SSHCommand.defaultControlDirectory
            ),
            claudeSessionID: sessionID
        )
    }
}
