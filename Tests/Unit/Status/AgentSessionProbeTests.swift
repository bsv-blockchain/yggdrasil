import XCTest
@testable import Yggdrasil

/// Finding the right transcript for a worktree, and reading as little of it as
/// possible. This runs for every tab on every poll tick, against a store that
/// is 1.2GB across 2472 files here, with individual transcripts up to 21MB —
/// so "read the file" is not an option, and neither is re-reading one that
/// hasn't changed.
final class AgentSessionProbeTests: XCTestCase {
    // MARK: - Locating

    /// Claude maps a working directory to a project folder by replacing every
    /// "/" and "." with "-". The `.worktrees` segment is the case most likely
    /// to regress, since it produces a double dash.
    func testEncodesAWorktreePath() {
        XCTAssertEqual(
            AgentSessionLocator.encode(cwd: "/Users/sigi/gitcheckout/deliverai/.worktrees/claude-review-pr-7"),
            "-Users-sigi-gitcheckout-deliverai--worktrees-claude-review-pr-7"
        )
    }

    /// Every non-alphanumeric is replaced, not just "/" and ".". `BranchSlug`
    /// keeps `_` in branch slugs, so this is reachable the moment a branch is
    /// named `fix/update_cache` — and getting it wrong finds no directory and
    /// reports no state, silently, forever.
    func testEncodesEveryNonAlphanumeric() {
        XCTAssertEqual(
            AgentSessionLocator.encode(cwd: "/Users/me/repo/.worktrees/fix-update_cache"),
            "-Users-me-repo--worktrees-fix-update-cache"
        )
        XCTAssertEqual(
            AgentSessionLocator.encode(cwd: "/Users/me/Dropbox (Personal)/repo+x"),
            "-Users-me-Dropbox--Personal--repo-x"
        )
    }

    /// Unicode is not alphanumeric for this purpose — the real encoder works on
    /// ASCII classes, so `é` must become a dash rather than survive.
    func testEncodesNonASCIILettersAsDashes() {
        XCTAssertEqual(AgentSessionLocator.encode(cwd: "/a/café"), "-a-caf-")
    }

    func testEncodesAPlainRepoPath() {
        XCTAssertEqual(
            AgentSessionLocator.encode(cwd: "/Users/sigi/code/thing"),
            "-Users-sigi-code-thing"
        )
    }

    func testProjectDirectoryIsUnderTheClaudeHome() {
        XCTAssertEqual(
            AgentSessionLocator.projectDirectory(forWorktreePath: "/a/b", home: "/home/me"),
            "/home/me/.claude/projects/-a-b"
        )
    }

    /// A project folder routinely holds several transcripts — each `claude`
    /// invocation opens a new session id. The live one is the newest.
    func testPicksTheNewestTranscript() {
        let files = [
            TranscriptFile(path: "/p/old.jsonl", modified: date(100), size: 10),
            TranscriptFile(path: "/p/new.jsonl", modified: date(300), size: 10),
            TranscriptFile(path: "/p/mid.jsonl", modified: date(200), size: 10)
        ]
        XCTAssertEqual(AgentSessionLocator.newest(among: files)?.path, "/p/new.jsonl")
    }

    /// Deterministic tie-break, so a tab doesn't flip between two files.
    func testBreaksModificationTiesByPath() {
        let files = [
            TranscriptFile(path: "/p/b.jsonl", modified: date(100), size: 10),
            TranscriptFile(path: "/p/a.jsonl", modified: date(100), size: 10)
        ]
        XCTAssertEqual(AgentSessionLocator.newest(among: files)?.path, "/p/a.jsonl")
    }

    func testNoTranscriptsGivesNothing() {
        XCTAssertNil(AgentSessionLocator.newest(among: []))
    }

    // MARK: - Probing

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func claudeLine(_ stop: String, when: String = "2026-09-16T09:37:10.745Z") -> String {
        #"{"type":"assistant","timestamp":"\#(when)","message":{"stop_reason":"\#(stop)","content":[]}}"#
    }

    func testReturnsNothingWhenThereIsNoSessionYet() {
        let probe = AgentSessionProbe(fileSystem: StubTranscriptFS(files: [:], contents: [:]))
        let (sample, cache) = probe.probe(worktreePath: "/w", agent: .claude, previous: nil)
        XCTAssertNil(sample)
        XCTAssertNil(cache)
    }

    func testReadsTheNewestTranscript() {
        let stub = StubTranscriptFS(
            files: [AgentSessionLocator.projectDirectory(forWorktreePath: "/w"): [TranscriptFile(
                path: "/t/a.jsonl",
                modified: date(1),
                size: 80
            )]],
            contents: ["/t/a.jsonl": claudeLine("end_turn")]
        )
        let probe = AgentSessionProbe(fileSystem: stub)
        let (sample, cache) = probe.probe(worktreePath: "/w", agent: .claude, previous: nil)
        XCTAssertEqual(sample?.activity, .turnEnded)
        XCTAssertEqual(cache?.path, "/t/a.jsonl")
        XCTAssertEqual(stub.readCount, 1)
    }

    /// The common case by far: an idle tab must cost a directory listing and
    /// no file read at all.
    func testUnchangedFileIsNotReReadAndKeepsItsResult() {
        let file = TranscriptFile(path: "/t/a.jsonl", modified: date(1), size: 80)
        let stub = StubTranscriptFS(
            files: [AgentSessionLocator.projectDirectory(forWorktreePath: "/w"): [file]],
            contents: ["/t/a.jsonl": claudeLine("end_turn")]
        )
        let probe = AgentSessionProbe(fileSystem: stub)

        let (_, cache) = probe.probe(worktreePath: "/w", agent: .claude, previous: nil)
        XCTAssertEqual(stub.readCount, 1)

        let (sample, _) = probe.probe(worktreePath: "/w", agent: .claude, previous: cache)
        XCTAssertEqual(sample?.activity, .turnEnded, "cached result is reused")
        XCTAssertEqual(stub.readCount, 1, "no second read")
    }

    func testAChangedFileIsReRead() {
        let stub = StubTranscriptFS(
            files: [AgentSessionLocator.projectDirectory(forWorktreePath: "/w"): [TranscriptFile(
                path: "/t/a.jsonl",
                modified: date(1),
                size: 80
            )]],
            contents: ["/t/a.jsonl": claudeLine("end_turn")]
        )
        let probe = AgentSessionProbe(fileSystem: stub)
        let (_, cache) = probe.probe(worktreePath: "/w", agent: .claude, previous: nil)

        stub.files[AgentSessionLocator.projectDirectory(forWorktreePath: "/w")] = [TranscriptFile(
            path: "/t/a.jsonl",
            modified: date(2),
            size: 140
        )]
        stub.contents["/t/a.jsonl"] = claudeLine("tool_use")
        let (sample, _) = probe.probe(worktreePath: "/w", agent: .claude, previous: cache)

        XCTAssertEqual(sample?.activity, .working)
        XCTAssertEqual(stub.readCount, 2)
    }

    /// A file with nothing parseable must be remembered as such, or every tick
    /// re-reads it forever.
    func testNegativeResultIsCached() {
        let stub = StubTranscriptFS(
            files: [AgentSessionLocator.projectDirectory(forWorktreePath: "/w"): [TranscriptFile(
                path: "/t/a.jsonl",
                modified: date(1),
                size: 40
            )]],
            contents: ["/t/a.jsonl": #"{"type":"cost-state"}"#]
        )
        let probe = AgentSessionProbe(fileSystem: stub)
        let (first, cache) = probe.probe(worktreePath: "/w", agent: .claude, previous: nil)
        XCTAssertNil(first)
        let (second, _) = probe.probe(worktreePath: "/w", agent: .claude, previous: cache)
        XCTAssertNil(second)
        XCTAssertEqual(stub.readCount, 1, "a known-empty file is not re-read")
    }

    /// Switching session (a new `claude` invocation) invalidates the cache even
    /// if size and mtime happened to match.
    func testADifferentFileInvalidatesTheCache() {
        let stub = StubTranscriptFS(
            files: [AgentSessionLocator.projectDirectory(forWorktreePath: "/w"): [TranscriptFile(
                path: "/t/a.jsonl",
                modified: date(1),
                size: 80
            )]],
            contents: ["/t/a.jsonl": claudeLine("end_turn"), "/t/b.jsonl": claudeLine("tool_use")]
        )
        let probe = AgentSessionProbe(fileSystem: stub)
        let (_, cache) = probe.probe(worktreePath: "/w", agent: .claude, previous: nil)

        stub.files[AgentSessionLocator.projectDirectory(forWorktreePath: "/w")] = [TranscriptFile(
            path: "/t/b.jsonl",
            modified: date(1),
            size: 80
        )]
        let (sample, _) = probe.probe(worktreePath: "/w", agent: .claude, previous: cache)
        XCTAssertEqual(sample?.activity, .working)
        XCTAssertEqual(stub.readCount, 2)
    }

    /// Codex transcripts aren't keyed by directory, so nothing can be located
    /// for them yet; it must degrade to "no information", never a wrong state.
    func testCodexIsNotLocatedYet() {
        let stub = StubTranscriptFS(
            files: [AgentSessionLocator.projectDirectory(forWorktreePath: "/w"): [TranscriptFile(
                path: "/t/a.jsonl",
                modified: date(1),
                size: 10
            )]],
            contents: [:]
        )
        let probe = AgentSessionProbe(fileSystem: stub)
        let (sample, _) = probe.probe(worktreePath: "/w", agent: .codex, previous: nil)
        XCTAssertNil(sample)
        XCTAssertEqual(stub.readCount, 0)
    }
}

/// In-memory stand-in that counts reads, so the caching claims are measurable.
private final class StubTranscriptFS: TranscriptFileSystem, @unchecked Sendable {
    var files: [String: [TranscriptFile]]
    var contents: [String: String]
    private(set) var readCount = 0

    init(files: [String: [TranscriptFile]], contents: [String: String]) {
        self.files = files
        self.contents = contents
    }

    /// Keyed on the directory the probe actually asks for. Keying on the
    /// worktree path instead let every lookup fall through to a single entry,
    /// so the tests passed regardless of whether the encoding was right.
    func transcripts(inDirectory path: String) -> [TranscriptFile] {
        files[path] ?? []
    }

    func readTail(path: String, maxBytes: Int) throws -> (data: Data, startsAtFileStart: Bool) {
        readCount += 1
        let text = contents[path] ?? ""
        let data = Data(text.utf8)
        if data.count <= maxBytes { return (data, true) }
        return (data.suffix(maxBytes), false)
    }
}
