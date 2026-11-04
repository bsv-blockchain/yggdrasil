import XCTest
@testable import Yggdrasil

/// Claude state for tabs on an ssh host: the transcript lives on the host, so
/// the probe asks the `ygg` helper for it in one round trip per tick.
final class RemoteTranscriptProbeTests: XCTestCase {
    private let host = RemoteHost(id: 1, name: "devbox", sshTarget: "me@devbox", reposRoot: "/src", createdAt: Date())
    private let path = "/home/me/.claude/projects/-src-r/s.jsonl"

    private func ok(_ stdout: String) -> SubprocessResult {
        SubprocessResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func line(_ type: String, _ seconds: TimeInterval, extra: String = "") -> String {
        let stamp = ISO8601DateFormatter().string(from: date(seconds))
        return #"{"type":"\#(type)","timestamp":"\#(stamp)"\#(extra)}"#
    }

    // MARK: - SSH source

    func testParsesHeaderAndBody() throws {
        XCTAssertEqual(
            try SSHTranscriptSource.parse("1700000000 6 /home/my dir/s.jsonl\nl1\nl2\n"),
            RemoteTranscript(
                file: TranscriptFile(path: "/home/my dir/s.jsonl", modified: date(1_700_000_000), size: 6),
                tail: Data("l1\nl2\n".utf8)
            )
        )
    }

    func testParsesHeaderOnly() throws {
        XCTAssertEqual(
            try SSHTranscriptSource.parse("1700000000 6 /p/s.jsonl\n"),
            RemoteTranscript(file: TranscriptFile(path: "/p/s.jsonl", modified: date(1_700_000_000), size: 6),
                             tail: Data())
        )
    }

    func testParsesNoneAsNoTranscript() throws {
        XCTAssertNil(try SSHTranscriptSource.parse("none\n"))
    }

    /// `ProcessRunner` hands back "" when stdout isn't valid UTF-8 — e.g. a
    /// tick that caught Claude mid-write through a multibyte character. That
    /// must fail (keeping the last state), not read as "no transcript".
    func testUnreadableReplyThrows() {
        XCTAssertThrowsError(try SSHTranscriptSource.parse(""))
        XCTAssertThrowsError(try SSHTranscriptSource.parse("garbage\n"))
    }

    func testSendsHelperTranscriptCommandWithUnchangedFile() async throws {
        let stub = StubSubprocessRunner(responses: [ok("1700000000 6 \(path)\n")])
        let source = SSHTranscriptSource(runner: SSHSubprocessRunner(host: host, transport: stub))
        let reply = try await source.transcript(
            projectDirectory: "-src-r", maxBytes: 131_072,
            unchangedFrom: TranscriptFile(path: path, modified: date(1_700_000_000), size: 6)
        )
        XCTAssertEqual(reply?.file.size, 6)
        let calls = await stub.recordedCalls()
        XCTAssertEqual(
            SSHCommand.decodePosixRemote(calls[0].arguments.last ?? ""),
            "~/.yggdrasil/bin/ygg transcript '-src-r' 131072 1700000000 6 '\(path)'"
        )
    }

    func testFirstRequestOmitsUnchangedFile() async throws {
        let stub = StubSubprocessRunner(responses: [ok("none\n")])
        let source = SSHTranscriptSource(runner: SSHSubprocessRunner(host: host, transport: stub))
        let reply = try await source.transcript(projectDirectory: "-src-r", maxBytes: 10, unchangedFrom: nil)
        XCTAssertNil(reply)
        let calls = await stub.recordedCalls()
        XCTAssertEqual(SSHCommand.decodePosixRemote(calls[0].arguments.last ?? ""),
                       "~/.yggdrasil/bin/ygg transcript '-src-r' 10")
    }

    /// The poller reaches hosts still running an older helper (no
    /// `transcript`) before any respawn upgrades them.
    func testInstallsCurrentHelperAndRetries() async throws {
        let stub = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "usage: ygg version|check|attach|kill|alive|list|run", exitCode: 2),
            ok(""),
            ok("1700000000 6 \(path)\nl1\nl2\n")
        ])
        let source = SSHTranscriptSource(runner: SSHSubprocessRunner(host: host, transport: stub))
        let reply = try await source.transcript(projectDirectory: "-src-r", maxBytes: 10, unchangedFrom: nil)
        XCTAssertEqual(reply?.tail, Data("l1\nl2\n".utf8))
        let calls = await stub.recordedCalls()
        XCTAssertEqual(SSHCommand.decodePosixRemote(calls[1].arguments.last ?? ""), RemoteHelper.installCommand)
    }

    func testSSHFailureThrows() async {
        let stub = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "Connection refused", exitCode: 255)
        ])
        let source = SSHTranscriptSource(runner: SSHSubprocessRunner(host: host, transport: stub))
        do {
            _ = try await source.transcript(projectDirectory: "-src-r", maxBytes: 10, unchangedFrom: nil)
            XCTFail("expected throw")
        } catch {}
    }

    // MARK: - probeRemote

    func testRemoteProbeReadsAwaitingInput() async {
        let body = line("assistant", 1_700_000_000, extra: Self.askUserQuestion) + "\n"
        let file = TranscriptFile(path: path, modified: date(1_700_000_000), size: UInt64(body.utf8.count))
        let source = StubTranscriptSource(replies: [RemoteTranscript(file: file, tail: Data(body.utf8))])
        let (sample, cache) = await AgentSessionProbe().probeRemote(
            worktreePath: "/src/r", agent: .claude, previous: nil, source: source
        )
        XCTAssertEqual(sample?.activity, .awaitingAnswer)
        XCTAssertEqual(cache?.path, path)
        let calls = await source.calls
        XCTAssertEqual(calls.first?.projectDirectory, "-src-r")
        XCTAssertNil(calls.first?.unchangedFrom)
    }

    func testRemoteProbeReusesPreviousWhenUnchanged() async {
        let file = TranscriptFile(path: path, modified: date(1_700_000_000), size: 6)
        let previousSample = AgentActivitySample(activity: .awaitingAnswer, timestamp: date(1_700_000_000))
        let previous = AgentSessionProbe.Cache(path: path, modified: file.modified, size: 6, sample: previousSample)
        let source = StubTranscriptSource(replies: [RemoteTranscript(file: file, tail: Data())])
        let (sample, cache) = await AgentSessionProbe().probeRemote(
            worktreePath: "/src/r", agent: .claude, previous: previous, source: source
        )
        XCTAssertEqual(sample, previousSample)
        XCTAssertEqual(cache, previous)
        let calls = await source.calls
        XCTAssertEqual(calls.first?.unchangedFrom, file)
    }

    /// Tail held only bookkeeping: one retry with the bigger window.
    func testRemoteProbeEscalatesOnceForOversizeFile() async {
        let big = UInt64(AgentSessionProbe.initialTailBytes + 1)
        let file = TranscriptFile(path: path, modified: date(1_700_000_000), size: big)
        let body = line("assistant", 1_700_000_000, extra: Self.askUserQuestion) + "\n"
        let source = StubTranscriptSource(replies: [
            RemoteTranscript(file: file, tail: Data("{\"type\":\"summary\"}\n".utf8)),
            RemoteTranscript(file: file, tail: Data(body.utf8))
        ])
        let (sample, _) = await AgentSessionProbe().probeRemote(
            worktreePath: "/src/r", agent: .claude, previous: nil, source: source
        )
        XCTAssertEqual(sample?.activity, .awaitingAnswer)
        let calls = await source.calls
        XCTAssertEqual(calls.map(\.maxBytes), [AgentSessionProbe.initialTailBytes, AgentSessionProbe.maxTailBytes])
        XCTAssertNil(calls.last?.unchangedFrom)
    }

    func testRemoteProbeDoesNotEscalateWhenWholeFileWasSent() async {
        let file = TranscriptFile(path: path, modified: date(1_700_000_000), size: 20)
        let source = StubTranscriptSource(replies: [
            RemoteTranscript(file: file, tail: Data("{\"type\":\"summary\"}\n".utf8))
        ])
        let (sample, cache) = await AgentSessionProbe().probeRemote(
            worktreePath: "/src/r", agent: .claude, previous: nil, source: source
        )
        XCTAssertNil(sample)
        XCTAssertNotNil(cache)
        let calls = await source.calls
        XCTAssertEqual(calls.count, 1)
    }

    /// A dropped connection must not blank the tab's state: that's the exact
    /// symptom (no "awaiting input") this probe exists to fix.
    func testRemoteProbeKeepsPreviousOnFailure() async {
        let previousSample = AgentActivitySample(activity: .awaitingAnswer, timestamp: date(1_700_000_000))
        let previous = AgentSessionProbe.Cache(
            path: path,
            modified: date(1_700_000_000),
            size: 6,
            sample: previousSample
        )
        let source = StubTranscriptSource(replies: [])
        let (sample, cache) = await AgentSessionProbe().probeRemote(
            worktreePath: "/src/r", agent: .claude, previous: previous, source: source
        )
        XCTAssertEqual(sample, previousSample)
        XCTAssertEqual(cache, previous)
    }

    func testRemoteProbeNoTranscriptGivesNothing() async {
        let source = StubTranscriptSource(replies: [nil])
        let (sample, cache) = await AgentSessionProbe().probeRemote(
            worktreePath: "/src/r", agent: .claude, previous: nil, source: source
        )
        XCTAssertNil(sample)
        XCTAssertNil(cache)
    }

    func testRemoteProbeSkipsCodex() async {
        let source = StubTranscriptSource(replies: [])
        let (sample, _) = await AgentSessionProbe().probeRemote(
            worktreePath: "/src/r", agent: .codex, previous: nil, source: source
        )
        XCTAssertNil(sample)
        let calls = await source.calls
        XCTAssertTrue(calls.isEmpty)
    }

    private static let askUserQuestion =
        #","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}"#
}

private actor StubTranscriptSource: RemoteTranscriptSource {
    struct Call: Equatable {
        let projectDirectory: String
        let maxBytes: Int
        let unchangedFrom: TranscriptFile?
    }

    private(set) var calls: [Call] = []
    private var replies: [RemoteTranscript?]

    init(replies: [RemoteTranscript?]) {
        self.replies = replies
    }

    func transcript(
        projectDirectory: String, maxBytes: Int, unchangedFrom: TranscriptFile?
    ) async throws -> RemoteTranscript? {
        calls.append(Call(projectDirectory: projectDirectory, maxBytes: maxBytes, unchangedFrom: unchangedFrom))
        guard !replies.isEmpty else { throw NSError(domain: "StubTranscriptSource", code: -1) }
        return replies.removeFirst()
    }
}
