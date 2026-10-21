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
    /// `--resume` looks in all of them, so a moved worktree doesn't matter. A
    /// tab that has moved around leaves older copies behind; the most recently
    /// written one is the live conversation.
    static func localTranscript(sessionID: String, home: String) -> Local? {
        let root = "\(home)/.claude/projects"
        let files = FileManager.default
        let copies = ((try? files.contentsOfDirectory(atPath: root)) ?? [])
            .map { URL(fileURLWithPath: "\(root)/\($0)/\(sessionID).jsonl") }
            .compactMap { file -> (URL, Date)? in
                guard let modified = try? files.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
                else { return nil }
                return (file, modified)
            }
        guard let file = copies.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        var isDir: ObjCBool = false
        let sidecar = file.deletingPathExtension()
        let hasSidecar = files.fileExists(atPath: sidecar.path, isDirectory: &isDir) && isDir.boolValue
        return Local(jsonl: file, sidecar: hasSidecar ? sidecar : nil)
    }

    /// The most recently written conversation in one project dir, by id.
    static func newestSessionID(inProjectDirectory dir: String) -> String? {
        let files = FileManager.default
        return ((try? files.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> (String, Date)? in
                guard let modified = try? files.attributesOfItem(atPath: "\(dir)/\(name)")[.modificationDate] as? Date
                else { return nil }
                return (String(name.dropLast(".jsonl".count)), modified)
            }
            .max { $0.1 < $1.1 }?.0
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
        try await scp(sources + ["\(host.scpHost):\(remoteDir)/"])
        return true
    }

    /// Host → this Mac. Returns false when the host has no transcript.
    @discardableResult
    func download(sessionID: String, from host: RemoteHost, cwd: String) async throws -> Bool {
        // Newest copy first, for the same reason as `localTranscript`.
        let found = try await remote(host, """
        f=$(ls -t "$HOME"/.claude/projects/*/"$1".jsonl 2>/dev/null | head -n 1)
        [ -n "$f" ] || exit 0
        echo "$f"
        if [ -d "${f%.jsonl}" ]; then echo "${f%.jsonl}"; fi
        """, sessionID)
        let paths = found.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return false }
        let localDir = AgentSessionLocator.projectDirectory(forWorktreePath: cwd, home: home)
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try await scp(paths.map { "\(host.scpHost):\($0)" } + [localDir + "/"])
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
