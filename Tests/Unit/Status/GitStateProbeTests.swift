@testable import Yggdrasil
import XCTest

final class GitStateProbeTests: XCTestCase {

    func testParsePorcelainEmptyMeansClean() {
        XCTAssertFalse(GitStateProbe.parseDirty(porcelain: ""))
        XCTAssertFalse(GitStateProbe.parseDirty(porcelain: "\n"))
    }

    func testParsePorcelainAnyOutputMeansDirty() {
        XCTAssertTrue(GitStateProbe.parseDirty(porcelain: " M README.md\n"))
        XCTAssertTrue(GitStateProbe.parseDirty(porcelain: "?? new.txt\n"))
        XCTAssertTrue(GitStateProbe.parseDirty(porcelain: "M  staged.swift\n"))
    }

    func testParseAheadBehindHappyPath() {
        // `git rev-list --left-right --count HEAD...@{upstream}` outputs e.g. "3\t1".
        let result = GitStateProbe.parseAheadBehind("3\t1\n")
        XCTAssertEqual(result?.ahead, 3)
        XCTAssertEqual(result?.behind, 1)
    }

    func testParseAheadBehindBothZero() {
        let result = GitStateProbe.parseAheadBehind("0\t0\n")
        XCTAssertEqual(result?.ahead, 0)
        XCTAssertEqual(result?.behind, 0)
    }

    func testParseAheadBehindRejectsMalformed() {
        XCTAssertNil(GitStateProbe.parseAheadBehind(""))
        XCTAssertNil(GitStateProbe.parseAheadBehind("abc\tdef"))
        XCTAssertNil(GitStateProbe.parseAheadBehind("just-one"))
    }

    // MARK: - Probe against a real fixture repo

    private var fixture: FixtureGitRepo!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await FixtureGitRepo.create(named: "git-state")
    }

    override func tearDown() async throws {
        fixture?.cleanup()
        fixture = nil
        try await super.tearDown()
    }

    func testProbeReportsCleanAndNoRemoteForFreshRepo() async throws {
        let probe = GitStateProbe()
        let state = try await probe.probe(worktreePath: fixture.repoURL.path)
        XCTAssertFalse(state.dirty)
        XCTAssertEqual(state.remote, .noRemote, "fresh fixture has no upstream")
    }

    func testProbeReportsDirtyAfterFileWrite() async throws {
        try Data("hello".utf8).write(to: fixture.repoURL.appendingPathComponent("note.txt"))
        let probe = GitStateProbe()
        let state = try await probe.probe(worktreePath: fixture.repoURL.path)
        XCTAssertTrue(state.dirty)
    }
}
