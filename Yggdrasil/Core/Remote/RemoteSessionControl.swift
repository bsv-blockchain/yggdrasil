import Foundation

/// What a host is missing before tabs can run on it.
struct HostPreflightReport: Equatable {
    let missingTools: [String]
    /// True when this check (re)installed the `ygg` helper.
    let helperInstalled: Bool

    var isReady: Bool {
        missingTools.isEmpty
    }
}

/// Non-interactive calls to a host over the shared ssh connection: helper
/// install/version check and killing a tab's remote session.
struct RemoteSessionControl {
    enum Failure: Error, Equatable {
        case ssh(exitCode: Int32, stderr: String)
    }

    let runner: SubprocessRunner

    init(runner: SubprocessRunner = ProcessRunner()) {
        self.runner = runner
    }

    /// Ends the tab's agent on the host (the helper SIGTERMs, then SIGKILLs
    /// after 5s). Returns once it's gone, so a respawn can't reattach to it.
    func kill(host: RemoteHost, tabID: Int64) async throws {
        _ = try await exec(host, "\(RemoteHelper.path) kill \(tabID)")
    }

    /// Installs or updates the helper, then has it check the tools agents
    /// need on the login shell's PATH, the PATH agents get.
    func preflight(host: RemoteHost) async throws -> HostPreflightReport {
        let reported = try await exec(host, "\(RemoteHelper.path) version 2>/dev/null || echo 0")
        var installed = false
        if reported.trimmingCharacters(in: .whitespacesAndNewlines) != String(RemoteHelper.version) {
            _ = try await exec(host, RemoteHelper.installCommand)
            installed = true
        }
        let missing = try await exec(host, "\(RemoteHelper.path) check")
            .split(separator: "\n")
            .filter { $0.hasPrefix("missing:") }
            .map { String($0.dropFirst("missing:".count)) }
        return HostPreflightReport(missingTools: missing, helperInstalled: installed)
    }

    private func exec(_ host: RemoteHost, _ remoteCommand: String) async throws -> String {
        SSHCommand.prepareControlDirectory()
        let result = try await runner.run(
            executable: SSHCommand.executable,
            arguments: SSHCommand.exec(
                target: host.sshTarget, remoteCommand: SSHCommand.posixRemote(remoteCommand),
                controlDirectory: SSHCommand.defaultControlDirectory
            )
        )
        guard result.exitCode == 0 else {
            throw Failure.ssh(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }
}
