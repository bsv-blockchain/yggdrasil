import Foundation

/// Moves a tab between this Mac and a host: its branch (committed work only),
/// its worktree, and its Claude conversation. The tab row is repointed only
/// once everything is in place on the destination; a failure before that
/// restarts the agent where it was. The source worktree is never deleted.
///
///     check → stop agent → move branch → worktree → transcript → switch → start
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
        /// Marks the tab as busy so nothing spawns an agent mid-move.
        var setMoving: (_ moving: Bool) async -> Void
        var stopAgent: (_ host: RemoteHost?) async -> Void
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
        guard try await environment.isClean(request.source, request.sourcePath) else {
            throw MigrationError.dirtyWorktree(request.sourcePath)
        }

        await environment.setMoving(true)
        await environment.stopAgent(request.source)
        let destinationPath: String
        do {
            try await environment.moveBranch(request)
            destinationPath = try await environment.ensureWorktree(request)
            if request.sessionID != nil {
                try await environment.copyTranscript(request, destinationPath)
            }
            try await environment.switchTab(request, destinationPath)
        } catch {
            // Nothing points at the destination yet: put the agent back.
            await environment.setMoving(false)
            await environment.startAgent()
            throw error
        }
        await environment.setMoving(false)
        await environment.startAgent()
        return destinationPath
    }
}
