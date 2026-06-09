import Foundation

enum GitHubClonerError: Error, Equatable {
    case cloneFailed(stderr: String, exitCode: Int32)
}

/// Clones a tracked repo via the `gh` CLI (`gh repo clone <owner>/<name> <dir>`).
///
/// We deliberately shell out to `gh` rather than `git clone https://github.com/…`
/// because gh authenticates with the same token the rest of the app already uses
/// (`AuthService` → `gh auth token`) and configures git credentials for it. A raw
/// HTTPS `git clone` has no access to that token, so a **private** repo would
/// block on an interactive credential prompt in our non-interactive subprocess
/// and hang. Going through gh makes both public and private clones work.
struct GitHubCloner {
    let runner: SubprocessRunner
    let ghExecutable: String

    init(runner: SubprocessRunner = ProcessRunner(), ghExecutable: String = GHCLIAuth.defaultExecutable) {
        self.runner = runner
        self.ghExecutable = ghExecutable
    }

    /// Clone `owner/name` into `targetPath`. Throws `GitHubClonerError.cloneFailed`
    /// (carrying gh's stderr) on a non-zero exit so callers can log the real cause.
    func clone(owner: String, name: String, to targetPath: String) async throws {
        let result = try await runner.run(
            executable: ghExecutable,
            arguments: ["repo", "clone", "\(owner)/\(name)", targetPath]
        )
        guard result.exitCode == 0 else {
            throw GitHubClonerError.cloneFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }
}
