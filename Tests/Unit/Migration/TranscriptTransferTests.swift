import XCTest
@testable import Yggdrasil

final class TranscriptTransferTests: XCTestCase {
    private var home: URL!
    private let host = RemoteHost(id: 1, name: "d", sshTarget: "me@dev", reposRoot: "/srv", createdAt: Date())
    private let sessionID = "0b9d2f0e-1111-4222-8333-444455556666"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ygg-transcripts-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeTranscript(project: String, sidecar: Bool = false) throws -> URL {
        let dir = home.appendingPathComponent(".claude/projects/\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionID).jsonl")
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        if sidecar {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sessionID, isDirectory: true), withIntermediateDirectories: true
            )
        }
        return file
    }

    private func ok(_ stdout: String = "") -> SubprocessResult {
        SubprocessResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    func testFindsLocalTranscriptInAnyProjectDir() throws {
        let file = try writeTranscript(project: "-somewhere-else")
        let found = TranscriptTransfer.localTranscript(sessionID: sessionID, home: home.path)
        XCTAssertEqual(found?.jsonl.path, file.path)
        XCTAssertNil(found?.sidecar)
    }

    func testLocalSidecarDirectoryIsIncluded() throws {
        _ = try writeTranscript(project: "-p", sidecar: true)
        XCTAssertNotNil(TranscriptTransfer.localTranscript(sessionID: sessionID, home: home.path)?.sidecar)
    }

    func testUploadCreatesDestProjectDirThenScpsFileAndSidecar() async throws {
        let file = try writeTranscript(project: "-p", sidecar: true)
        let stub = StubSubprocessRunner(responses: [
            ok("/home/me/.claude/projects/-srv-acme-widget--worktrees-b\n"),
            ok()
        ])
        let copied = try await TranscriptTransfer(runner: stub, home: home.path)
            .upload(sessionID: sessionID, to: host, cwd: "/srv/acme/widget/.worktrees/b")
        XCTAssertTrue(copied)
        let calls = await stub.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].executable, "/usr/bin/ssh")
        XCTAssertTrue(
            SSHCommand.decodePosixRemote(calls[0].arguments.last ?? "")?
                .contains("'-srv-acme-widget--worktrees-b'") ?? false
        )
        XCTAssertEqual(calls[1].executable, "/usr/bin/scp")
        XCTAssertEqual(Array(calls[1].arguments.suffix(4)), [
            "--", file.path, file.deletingLastPathComponent().appendingPathComponent(sessionID).path,
            "me@dev:/home/me/.claude/projects/-srv-acme-widget--worktrees-b/"
        ])
        XCTAssertTrue(calls[1].arguments.contains("-r"))
    }

    func testUploadWithoutTranscriptCopiesNothing() async throws {
        let stub = StubSubprocessRunner(responses: [])
        let copied = try await TranscriptTransfer(runner: stub, home: home.path)
            .upload(sessionID: sessionID, to: host, cwd: "/x")
        XCTAssertFalse(copied)
        let calls = await stub.recordedCalls()
        XCTAssertEqual(calls.count, 0)
    }

    func testDownloadScpsRemoteFileIntoLocalProjectDir() async throws {
        let stub = StubSubprocessRunner(responses: [
            ok("/home/me/.claude/projects/-x/\(sessionID).jsonl\n/home/me/.claude/projects/-x/\(sessionID)\n"), ok()
        ])
        let copied = try await TranscriptTransfer(runner: stub, home: home.path)
            .download(sessionID: sessionID, from: host, cwd: "/Users/me/src/widget/.worktrees/b")
        XCTAssertTrue(copied)
        let calls = await stub.recordedCalls()
        let localDir = AgentSessionLocator.projectDirectory(
            forWorktreePath: "/Users/me/src/widget/.worktrees/b", home: home.path
        )
        XCTAssertEqual(Array(calls[1].arguments.suffix(4)), [
            "--", "me@dev:/home/me/.claude/projects/-x/\(sessionID).jsonl",
            "me@dev:/home/me/.claude/projects/-x/\(sessionID)", localDir + "/"
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir), "local project dir must exist for scp")
    }

    func testDownloadWithoutRemoteTranscriptCopiesNothing() async throws {
        let stub = StubSubprocessRunner(responses: [ok("")])
        let copied = try await TranscriptTransfer(runner: stub, home: home.path)
            .download(sessionID: sessionID, from: host, cwd: "/x")
        XCTAssertFalse(copied)
    }

    func testScpFailureIsReported() async throws {
        _ = try writeTranscript(project: "-p")
        let stub = StubSubprocessRunner(responses: [
            ok("/home/me/.claude/projects/-x\n"), SubprocessResult(stdout: "", stderr: "Permission denied", exitCode: 1)
        ])
        do {
            _ = try await TranscriptTransfer(runner: stub, home: home.path)
                .upload(sessionID: sessionID, to: host, cwd: "/x")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? MigrationError, .transcriptCopyFailed("Permission denied"))
        }
    }
}
