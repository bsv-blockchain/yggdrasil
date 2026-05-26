import Foundation

/// Thin wrapper around `SubprocessRunner` that invokes the system `git` binary.
///
/// Adds:
/// - A `-C <cwd>` prefix when a working directory is specified, so all git commands
///   run against the right repo without us having to mutate the parent process's cwd.
/// - Throws `WorktreeError.gitFailed` on non-zero exit so callers can pattern-match.
struct GitRunner {
    /// Default git location on Apple Silicon Homebrew + on a system Xcode CLT install.
    /// `/usr/bin/git` resolves to Xcode's git on a stock macOS, which is fine for our
    /// use case (worktrees, status, fetch).
    static let defaultExecutable = "/usr/bin/git"

    let runner: SubprocessRunner
    let gitExecutable: String

    init(runner: SubprocessRunner = ProcessRunner(), gitExecutable: String = GitRunner.defaultExecutable) {
        self.runner = runner
        self.gitExecutable = gitExecutable
    }

    /// Run `git <args>` (optionally inside `cwd`). Throws on non-zero exit.
    @discardableResult
    func run(args: [String], cwd: URL?) async throws -> SubprocessResult {
        var fullArgs: [String] = []
        if let cwd {
            fullArgs.append("-C")
            fullArgs.append(cwd.path)
        }
        fullArgs.append(contentsOf: args)
        let result = try await runner.run(executable: gitExecutable, arguments: fullArgs)
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: result.exitCode
            )
        }
        return result
    }
}
