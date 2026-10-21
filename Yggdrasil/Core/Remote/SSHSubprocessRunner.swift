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
        SSHCommand.prepareControlDirectory()
        return try await transport.run(
            executable: SSHCommand.executable,
            arguments: SSHCommand.exec(
                target: host.sshTarget,
                remoteCommand: SSHCommand.posixRemote("\(RemoteHelper.path) run -- \(argv)"),
                controlDirectory: SSHCommand.defaultControlDirectory
            )
        )
    }
}
