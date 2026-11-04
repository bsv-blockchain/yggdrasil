import Foundation

/// Runs commands on a host instead of this Mac: each call becomes one batch
/// `ssh … ygg run -- <argv>` over the shared connection, so tools resolve on
/// the login PATH agents get. Plugs into `GitRunner`, `WorktreeManager` and
/// friends unchanged. ssh's own failures surface as exit code 255.
struct SSHSubprocessRunner: SubprocessRunner {
    let host: RemoteHost
    let transport: SubprocessRunner

    init(host: RemoteHost, transport: SubprocessRunner = ProcessRunner()) {
        self.host = host
        self.transport = transport
    }

    func run(executable: String, arguments: [String]) async throws -> SubprocessResult {
        let argv = ([executable] + arguments).map(CodingAgentRunner.shellQuote).joined(separator: " ")
        let command = "\(RemoteHelper.path) run -- \(argv)"
        let result = try await send(command)
        // A host set up before `run` existed (or never set up) gets the
        // current helper installed, then one retry. Everything remote goes
        // through here, so no caller has to remember a preflight first.
        guard Self.lacksCurrentHelper(result) else { return result }
        let install = try await send(RemoteHelper.installCommand)
        guard install.exitCode == 0 else { return result }
        return try await send(command)
    }

    /// An old helper prints its usage (no `run`) and exits 2; a missing one
    /// makes the shell exit 127.
    static func lacksCurrentHelper(_ result: SubprocessResult) -> Bool {
        (result.exitCode == 2 && result.stderr.contains("usage: ygg"))
            || (result.exitCode == 127 && result.stderr.contains(".yggdrasil/bin/ygg"))
    }

    private func send(_ script: String) async throws -> SubprocessResult {
        SSHCommand.prepareControlDirectory()
        return try await transport.run(
            executable: SSHCommand.executable,
            arguments: SSHCommand.exec(
                target: host.sshTarget,
                remoteCommand: SSHCommand.posixRemote(script),
                controlDirectory: SSHCommand.defaultControlDirectory
            )
        )
    }
}
