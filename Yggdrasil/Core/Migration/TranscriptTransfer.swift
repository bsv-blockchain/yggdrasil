import Foundation

/// Copies a Claude conversation (`<id>.jsonl` plus its `<id>/` sidecar, when
/// there is one) between this Mac and a host, into the project dir for the
/// destination cwd. `--resume <id>` then finds it there; the transcript needs
/// no rewriting for the new cwd.
struct TranscriptTransfer {
    struct Local: Equatable {
        let jsonl: URL
        let sidecar: URL?
    }

    /// Runs ssh and scp (a `ProcessRunner` in the app).
    let runner: SubprocessRunner
    /// This Mac's home; injectable so tests don't touch ~/.claude.
    let home: String

    init(runner: SubprocessRunner = ProcessRunner(), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.home = home
    }

    /// The conversation on this Mac, in whichever project dir it lives —
    /// `--resume` looks in all of them, so a moved worktree doesn't matter.
    static func localTranscript(sessionID: String, home: String) -> Local? {
        let root = "\(home)/.claude/projects"
        let files = FileManager.default
        for dir in (try? files.contentsOfDirectory(atPath: root)) ?? [] {
            let file = URL(fileURLWithPath: "\(root)/\(dir)/\(sessionID).jsonl")
            guard files.fileExists(atPath: file.path) else { continue }
            var isDir: ObjCBool = false
            let sidecar = file.deletingPathExtension()
            let hasSidecar = files.fileExists(atPath: sidecar.path, isDirectory: &isDir) && isDir.boolValue
            return Local(jsonl: file, sidecar: hasSidecar ? sidecar : nil)
        }
        return nil
    }

    /// This Mac → host. Returns false when there's no transcript yet (a tab
    /// that never got past its first prompt), which isn't an error.
    @discardableResult
    func upload(sessionID: String, to host: RemoteHost, cwd: String) async throws -> Bool {
        guard let local = Self.localTranscript(sessionID: sessionID, home: home) else { return false }
        let remoteDir = try await remote(host, """
        mkdir -p "$HOME/.claude/projects/$1" && cd "$HOME/.claude/projects/$1" && pwd
        """, AgentSessionLocator.encode(cwd: cwd)).trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = [local.jsonl.path] + (local.sidecar.map { [$0.path] } ?? [])
        try await scp(sources + ["\(host.sshTarget):\(remoteDir)/"])
        return true
    }

    /// Host → this Mac. Returns false when the host has no transcript.
    @discardableResult
    func download(sessionID: String, from host: RemoteHost, cwd: String) async throws -> Bool {
        let found = try await remote(host, """
        for f in "$HOME"/.claude/projects/*/"$1".jsonl; do
            [ -f "$f" ] || continue
            echo "$f"
            [ -d "${f%.jsonl}" ] && echo "${f%.jsonl}"
            break
        done
        """, sessionID)
        let paths = found.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return false }
        let localDir = AgentSessionLocator.projectDirectory(forWorktreePath: cwd, home: home)
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try await scp(paths.map { "\(host.sshTarget):\($0)" } + [localDir + "/"])
        return true
    }

    private func remote(_ host: RemoteHost, _ script: String, _ arg: String) async throws -> String {
        let result = try await SSHSubprocessRunner(host: host, transport: runner)
            .run(executable: "sh", arguments: ["-c", script, "sh", arg])
        guard result.exitCode == 0 else {
            throw MigrationError.transcriptCopyFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    private func scp(_ operands: [String]) async throws {
        SSHCommand.prepareControlDirectory()
        let result = try await runner.run(
            executable: "/usr/bin/scp",
            arguments: ["-q", "-p", "-r"] + SSHCommand.options(controlDirectory: SSHCommand.defaultControlDirectory)
                + ["-o", "BatchMode=yes", "--"] + operands
        )
        guard result.exitCode == 0 else {
            throw MigrationError.transcriptCopyFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
