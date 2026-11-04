import XCTest
@testable import Yggdrasil

/// `ygg transcript`: the remote Claude-state probe's one round trip, run
/// against the real script with the same scratch HOME and stubs.
extension RemoteHelperTests {
    /// Writes `~/.claude/projects/<dir>/<name>` with a fixed mtime.
    @discardableResult
    private func writeTranscript(dir: String, name: String, _ body: String, mtime: TimeInterval) throws -> String {
        let folder = home.appendingPathComponent(".claude/projects/\(dir)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path
        )
        return url.path
    }

    /// Explicit, so the app can tell "no transcript" from an empty reply
    /// (which is what an undecodable one turns into).
    func testTranscriptWithoutProjectDirSaysNone() throws {
        let result = try sh(ygg("transcript -w 131072"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "none\n")
    }

    func testTranscriptSendsHeaderAndWholeSmallFile() throws {
        let path = try writeTranscript(dir: "-w", name: "s.jsonl", "l1\nl2\n", mtime: 1_700_000_000)
        let result = try sh(ygg("transcript -w 131072"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "1700000000 6 \(path)\nl1\nl2\n")
    }

    func testTranscriptPicksNewestFile() throws {
        try writeTranscript(dir: "-w", name: "old.jsonl", "old\n", mtime: 1_700_000_000)
        let newest = try writeTranscript(dir: "-w", name: "new.jsonl", "new\n", mtime: 1_700_000_500)
        XCTAssertEqual(try sh(ygg("transcript -w 131072")).stdout, "1700000500 4 \(newest)\nnew\n")
    }

    /// Over the limit, the window starts mid-line; that fragment is dropped on
    /// the host so only whole lines (valid UTF-8) cross the wire.
    func testTranscriptTailDropsLeadingFragment() throws {
        let path = try writeTranscript(dir: "-w", name: "s.jsonl", "aaaa\nbbbb\ncccc\n", mtime: 1_700_000_000)
        XCTAssertEqual(try sh(ygg("transcript -w 7")).stdout, "1700000000 15 \(path)\ncccc\n")
    }

    func testTranscriptUnchangedSendsHeaderOnly() throws {
        let path = try writeTranscript(dir: "-w", name: "s.jsonl", "l1\nl2\n", mtime: 1_700_000_000)
        let result = try sh(ygg("transcript -w 131072 1700000000 6 '\(path)'"))
        XCTAssertEqual(result.stdout, "1700000000 6 \(path)\n")
    }

    func testTranscriptChangedSinceSendsBody() throws {
        let path = try writeTranscript(dir: "-w", name: "s.jsonl", "l1\nl2\n", mtime: 1_700_000_000)
        let result = try sh(ygg("transcript -w 131072 1699999999 6 '\(path)'"))
        XCTAssertEqual(result.stdout, "1700000000 6 \(path)\nl1\nl2\n")
    }

    /// Linux: GNU `stat -c` must win. There `stat -f` *succeeds* (filesystem
    /// status) with unrelated output, so trying BSD syntax first would report
    /// garbage instead of failing over.
    func testTranscriptPrefersGNUStat() throws {
        try writeExecutable(bin, "stat", """
        #!/bin/sh
        if [ "$1" = -f ]; then echo "filesystem garbage"; exit 0; fi
        [ "$1" = -c ] || exit 1
        exec /usr/bin/stat -f '%m %z' "$3"
        """)
        let path = try writeTranscript(dir: "-w", name: "s.jsonl", "l1\n", mtime: 1_700_000_000)
        XCTAssertEqual(try sh(ygg("transcript -w 131072")).stdout, "1700000000 3 \(path)\nl1\n")
    }

    func testTranscriptRejectsUnsafeArguments() throws {
        for args in ["transcript '' 10", "transcript ../x 10", "transcript a/b 10", "transcript .x 10",
                     "transcript -w abc", "transcript -w"] {
            XCTAssertEqual(try sh(ygg(args)).exitCode, 2, args)
        }
    }
}
