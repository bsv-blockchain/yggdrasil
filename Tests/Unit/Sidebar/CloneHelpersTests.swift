import Foundation
import XCTest
@testable import Yggdrasil

/// Covers the pure helpers behind the "clone an uncloned repo" flow:
/// `NewTabSheet.inferCloneParent` (suggest where to clone) and
/// `RepoPrefsPane.isValidGitRepo` (decide whether a path is already a clone).
final class CloneHelpersTests: XCTestCase {
    private func repo(_ name: String, path: String?) -> Repo {
        Repo(id: nil, owner: "acme", name: name, defaultBranch: "main",
             localMainPath: path, addedAt: Date(timeIntervalSince1970: 0))
    }

    func testInferCloneParentPicksMostCommonParent() {
        let repos = [
            repo("a", path: "/Users/x/code/a"),
            repo("b", path: "/Users/x/code/b"),
            repo("c", path: "/Users/x/other/c")
        ]
        XCTAssertEqual(NewTabSheet.inferCloneParent(from: repos), "/Users/x/code")
    }

    func testInferCloneParentIgnoresReposWithoutPaths() {
        let repos = [
            repo("a", path: nil),
            repo("b", path: "/Users/x/dev/b")
        ]
        XCTAssertEqual(NewTabSheet.inferCloneParent(from: repos), "/Users/x/dev")
    }

    func testInferCloneParentFallsBackToHomeWhenNoPaths() {
        let repos = [repo("a", path: nil), repo("b", path: nil)]
        XCTAssertEqual(
            NewTabSheet.inferCloneParent(from: repos),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    func testIsValidGitRepoDetectsDotGit() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ygg-clone-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertFalse(RepoPrefsPane.isValidGitRepo(tmp.path), "no .git yet")

        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        XCTAssertTrue(RepoPrefsPane.isValidGitRepo(tmp.path), ".git present")
    }
}
