import Foundation

enum GHCLIAuthError: Error, Equatable {
    case notAuthenticated
    case unexpected(String)
}

/// Wraps the `gh auth token` subprocess. Stateless — caching is `AuthService`'s job.
struct GHCLIAuth {
    /// Default Homebrew location on Apple Silicon. Override-able in tests and for Intel.
    static let defaultExecutable = "/opt/homebrew/bin/gh"

    let runner: SubprocessRunner
    let ghExecutable: String

    init(runner: SubprocessRunner = ProcessRunner(), ghExecutable: String = GHCLIAuth.defaultExecutable) {
        self.runner = runner
        self.ghExecutable = ghExecutable
    }

    func currentToken() async throws -> String {
        let result = try await runner.run(executable: ghExecutable, arguments: ["auth", "token"])
        guard result.exitCode == 0 else {
            throw GHCLIAuthError.notAuthenticated
        }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GHCLIAuthError.unexpected("gh auth token returned empty stdout; stderr=\(result.stderr)")
        }
        return token
    }
}
