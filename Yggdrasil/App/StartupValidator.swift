import Clibgit2
import Foundation

/// libgit2 version triple. Named struct (rather than `(Int32, Int32, Int32)`)
/// to keep SwiftLint's `large_tuple` rule happy and to give the probe a
/// reusable type both prod + tests can write.
struct Libgit2Version: Equatable {
    let major: Int32
    let minor: Int32
    let revision: Int32

    /// `(0, 0, 0)` means "dyld loaded a bogus dylib that reports nothing" —
    /// treated as a failure by the validator.
    var isZero: Bool {
        major == 0 && minor == 0 && revision == 0
    }
}

/// Result of a single startup check that did not pass.
struct StartupCheckFailure: Equatable {
    /// Stable identifier for the failing dependency (`git`, `gh`,
    /// `libgit2`). Tests assert on this rather than the message string so
    /// copy edits don't break the suite.
    let tool: String
    /// User-facing message — shown in the NSAlert at app launch. Includes
    /// an install hint (`brew install …`) when applicable so the alert is
    /// actionable without further googling.
    let message: String
}

/// Runs at app launch before AppServices is built. If any required
/// dependency is missing or fails to load, AppDelegate displays a blocking
/// NSAlert and exits.
///
/// The struct is value-type with injected closures so unit tests can drive
/// every branch without touching the real filesystem or PATH.
struct StartupValidator {
    /// Calls `git_libgit2_version` (or a stub in tests). Returning `nil`
    /// represents the unreachable case of "the symbol exists but throws";
    /// returning `Libgit2Version(0,0,0)` represents a bogus dylib that
    /// loaded but reports nothing. Both are treated as failure.
    let probeLibgit2: () -> Libgit2Version?

    /// `command -v <name>` via the user's login shell in prod, injected in
    /// tests. Returning nil = tool not on PATH.
    let locateTool: (String) -> String?

    /// Production constructor — wires up the real probes against the host
    /// environment. AppDelegate calls this on the main thread before any
    /// other startup work.
    static func production() -> StartupValidator {
        StartupValidator(
            probeLibgit2: {
                var major: Int32 = 0
                var minor: Int32 = 0
                var rev: Int32 = 0
                git_libgit2_version(&major, &minor, &rev)
                return Libgit2Version(major: major, minor: minor, revision: rev)
            },
            locateTool: locateViaLoginShell
        )
    }

    /// Returns the list of failed checks. Empty array means the app is
    /// safe to start.
    func validate() -> [StartupCheckFailure] {
        var failures: [StartupCheckFailure] = []

        if let version = probeLibgit2(), !version.isZero {
            _ = version // happy path; reserved for future logging
        } else {
            failures.append(StartupCheckFailure(
                tool: "libgit2",
                message: """
                libgit2 failed to load. The application is missing or has \
                a damaged bundled libgit2.dylib. Reinstall Yggdrasil from a \
                fresh DMG.
                """
            ))
        }

        if locateTool("git") == nil {
            failures.append(StartupCheckFailure(
                tool: "git",
                message: """
                git was not found on PATH. Yggdrasil shells out to git for \
                worktrees, status, and diffs. Install Xcode Command Line \
                Tools (xcode-select --install) or:

                    brew install git
                """
            ))
        }

        if locateTool("gh") == nil {
            failures.append(StartupCheckFailure(
                tool: "gh",
                message: """
                gh (GitHub CLI) was not found on PATH. Yggdrasil reads the \
                GitHub token via `gh auth token`. Install + sign in:

                    brew install gh
                    gh auth login
                """
            ))
        }

        return failures
    }

    // MARK: - Production helpers

    /// Look up a binary via the user's login shell so brew-installed tools
    /// are found even when Yggdrasil was launched from Finder (Finder
    /// inherits a stripped PATH that doesn't include /opt/homebrew/bin).
    private static func locateViaLoginShell(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }
}
