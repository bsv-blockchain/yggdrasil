import XCTest
@testable import Yggdrasil

/// Pure-logic tests for StartupValidator. The production validator wraps a
/// `command -v` lookup via the user's login shell + a libgit2 version probe;
/// here we inject both so the suite never touches the host environment.
final class StartupValidatorTests: XCTestCase {
    private func allPassValidator(tools: [String] = ["git", "gh"]) -> StartupValidator {
        StartupValidator(
            probeLibgit2: { Libgit2Version(major: 1, minor: 9, revision: 4) },
            locateTool: { name in tools.contains(name) ? "/opt/homebrew/bin/\(name)" : nil }
        )
    }

    func test_validate_allChecksPass_returnsNoFailures() {
        let failures = allPassValidator().validate()
        XCTAssertTrue(failures.isEmpty, "expected no failures, got \(failures)")
    }

    func test_validate_missingGit_reportsGit() {
        let validator = StartupValidator(
            probeLibgit2: { Libgit2Version(major: 1, minor: 9, revision: 4) },
            locateTool: { name in name == "git" ? nil : "/opt/homebrew/bin/\(name)" }
        )
        let failures = validator.validate()
        XCTAssertEqual(failures.map(\.tool), ["git"])
    }

    func test_validate_missingGh_reportsGh() {
        let validator = StartupValidator(
            probeLibgit2: { Libgit2Version(major: 1, minor: 9, revision: 4) },
            locateTool: { name in name == "gh" ? nil : "/opt/homebrew/bin/\(name)" }
        )
        let failures = validator.validate()
        XCTAssertEqual(failures.map(\.tool), ["gh"])
    }

    func test_validate_libgit2ProbeReturnsNil_reportsLibgit2() {
        let validator = StartupValidator(
            probeLibgit2: { nil },
            locateTool: { name in "/opt/homebrew/bin/\(name)" }
        )
        let failures = validator.validate()
        XCTAssertEqual(failures.map(\.tool), ["libgit2"])
    }

    func test_validate_libgit2ProbeReturnsZeros_reportsLibgit2() {
        // A "loaded but returns zeros" libgit2 means dyld resolved a bogus
        // binary. Treat that as a failure so we don't silently ship a broken
        // dylib bundle.
        let validator = StartupValidator(
            probeLibgit2: { Libgit2Version(major: 0, minor: 0, revision: 0) },
            locateTool: { name in "/opt/homebrew/bin/\(name)" }
        )
        let failures = validator.validate()
        XCTAssertEqual(failures.map(\.tool), ["libgit2"])
    }

    func test_validate_multipleMissing_reportsAll() {
        let validator = StartupValidator(
            probeLibgit2: { Libgit2Version(major: 1, minor: 9, revision: 4) },
            locateTool: { _ in nil }
        )
        let failures = validator.validate()
        // git + gh — order doesn't matter, but both must appear.
        XCTAssertEqual(Set(failures.map(\.tool)), Set(["git", "gh"]))
    }

    func test_failureMessage_includesInstallHint() {
        // The alert needs to tell the user exactly how to recover. We assert
        // the install hint is present so a future "shorten the message"
        // refactor doesn't regress the UX.
        let validator = StartupValidator(
            probeLibgit2: { Libgit2Version(major: 1, minor: 9, revision: 4) },
            locateTool: { _ in nil }
        )
        let message = validator.validate().first?.message ?? ""
        XCTAssertTrue(message.lowercased().contains("brew install") ||
                      message.lowercased().contains("xcode-select"),
                      "expected install hint, got: \(message)")
    }
}
