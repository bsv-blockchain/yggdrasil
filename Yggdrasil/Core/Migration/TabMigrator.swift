import Foundation

/// Moves a tab between this Mac and a host: its branch (committed work only),
/// its worktree, and its Claude conversation. The tab row is repointed only
/// once everything is in place on the destination; a failure before that
/// restarts the agent where it was. The source worktree is never deleted.
///
///     stop agent → check (clean, on its branch) → move branch → worktree
///       → transcript → switch → start agent → settle
///
/// The agent is stopped before the checks, so nothing it writes mid-turn can
/// slip past them; it's started before the tab settles, so nothing else
/// (the main pane's auto-spawn) starts a second one.
struct TabMigrator {
    struct Request {
        let tabID: Int64
        let repo: Repo
        let branch: String
        /// The tab's pinned Claude conversation; nil skips the transcript.
        let sessionID: String?
        /// nil = this Mac.
        let source: RemoteHost?
        let sourcePath: String
        /// nil = this Mac.
        let destination: RemoteHost?
    }

    /// Every side effect, injected so the sequence is testable on its own.
    struct Environment {
        /// `git status --porcelain` is empty in the worktree (on its host).
        var isClean: (_ host: RemoteHost?, _ path: String) async throws -> Bool
        /// The branch checked out in the worktree; nil when HEAD is detached.
        var headBranch: (_ host: RemoteHost?, _ path: String) async throws -> String?
        /// Marks the tab as busy so nothing spawns an agent mid-move.
        var setMoving: (_ moving: Bool) async -> Void
        /// Throws when the agent may still be running: a twin resuming the
        /// same conversation elsewhere must never happen.
        var stopAgent: (_ host: RemoteHost?) async throws -> Void
        var moveBranch: (Request) async throws -> Void
        /// Creates (or reuses) the destination worktree; returns its path.
        var ensureWorktree: (Request) async throws -> String
        var copyTranscript: (Request, _ destinationPath: String) async throws -> Void
        var switchTab: (Request, _ destinationPath: String) async throws -> Void
        /// Starts the tab's agent wherever the tab row now points.
        var startAgent: () async -> Void
    }

    let environment: Environment

    @discardableResult
    func migrate(_ request: Request) async throws -> String {
        guard request.source?.id != request.destination?.id else { throw MigrationError.sameLocation }
        guard request.source == nil || request.destination == nil else { throw MigrationError.hostToHost }
        if request.destination == nil, request.repo.localMainPath == nil {
            throw MigrationError.noLocalClone(request.repo.fullName)
        }
        if request.destination != nil, request.branch == request.repo.defaultBranch {
            throw MigrationError.defaultBranchToHost(request.branch)
        }

        await environment.setMoving(true)
        let destinationPath: String
        do {
            try await environment.stopAgent(request.source)
            guard try await environment.isClean(request.source, request.sourcePath) else {
                throw MigrationError.dirtyWorktree(request.sourcePath)
            }
            let head = try await environment.headBranch(request.source, request.sourcePath)
            guard head == request.branch else {
                throw MigrationError.branchMismatch(expected: request.branch, actual: head)
            }
            try await environment.moveBranch(request)
            destinationPath = try await environment.ensureWorktree(request)
            if request.sessionID != nil {
                try await environment.copyTranscript(request, destinationPath)
            }
            try await environment.switchTab(request, destinationPath)
        } catch {
            // Nothing points at the destination yet: put the agent back.
            await environment.startAgent()
            await environment.setMoving(false)
            throw error
        }
        await environment.startAgent()
        await environment.setMoving(false)
        return destinationPath
    }
}
