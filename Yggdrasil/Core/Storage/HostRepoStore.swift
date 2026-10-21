import Foundation
import GRDB

enum HostRepoStoreError: Error, Equatable {
    case notAbsolute(String)
    /// Tabs on the host still have worktrees under this checkout.
    case inUse(String)
    /// Another repo's checkout on the host is already at this path.
    case pathTaken(String, heldBy: String)
}

/// A repo's checkout on a host, for listing in Settings.
struct HostRepoCheckout: Equatable {
    let repo: Repo
    let path: String
}

/// Where each repo's single main checkout lives on each host (`host_repo`).
struct HostRepoStore {
    let database: YggdrasilDatabase

    /// The pinned checkout, or `<repos_root>/<owner>/<name>` if the repo hasn't
    /// been used on this host yet.
    func checkoutPath(host: RemoteHost, repo: Repo) throws -> String {
        try database.queue.read { db in try stored(db, host: host, repo: repo) }
            ?? host.repoPath(owner: repo.owner, name: repo.name)
    }

    /// Returns the checkout path, recording the default first if none is
    /// stored. Called before a repo's first tab on the host, so later changes
    /// to the host's repos root don't move (or duplicate) the checkout.
    @discardableResult
    func pin(host: RemoteHost, repo: Repo) throws -> String {
        try database.queue.write { db in
            if let path = try stored(db, host: host, repo: repo) { return path }
            let path = host.repoPath(owner: repo.owner, name: repo.name)
            try Self.ensureFree(db, host: host, repo: repo, path: path)
            try db.execute(
                sql: "INSERT INTO host_repo (host_id, repo_id, checkout_path) VALUES (?, ?, ?)",
                arguments: [host.id, repo.id, path]
            )
            return path
        }
    }

    /// Points the repo at a different checkout on the host. Refused while tabs
    /// on the host have worktrees under the current one, since those would be
    /// orphaned. Two repos can't share a checkout (unique per host).
    func setCheckoutPath(host: RemoteHost, repo: Repo, path rawPath: String) throws {
        guard rawPath.hasPrefix("/") else { throw HostRepoStoreError.notAbsolute(rawPath) }
        // One spelling per directory, so the uniqueness and in-use checks
        // can't be dodged with `//` or a trailing slash.
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        try database.queue.write { db in
            let current = try stored(db, host: host, repo: repo)
                ?? host.repoPath(owner: repo.owner, name: repo.name)
            if current != path {
                let users = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM tab WHERE host_id = ? AND worktree_path LIKE ? ESCAPE '\\'",
                    arguments: [host.id, Self.likePrefix(current) + "/%"]
                ) ?? 0
                guard users == 0 else { throw HostRepoStoreError.inUse(current) }
            }
            try Self.ensureFree(db, host: host, repo: repo, path: path)
            try db.execute(
                sql: """
                INSERT INTO host_repo (host_id, repo_id, checkout_path) VALUES (?, ?, ?)
                ON CONFLICT (host_id, repo_id) DO UPDATE SET checkout_path = excluded.checkout_path
                """,
                arguments: [host.id, repo.id, path]
            )
        }
    }

    func list(hostID: Int64) throws -> [HostRepoCheckout] {
        try database.queue.read { db in try list(hostID: hostID, in: db) }
    }

    /// Same, inside a caller's read transaction.
    func list(hostID: Int64, in db: Database) throws -> [HostRepoCheckout] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT repo_id, checkout_path FROM host_repo WHERE host_id = ? ORDER BY checkout_path",
            arguments: [hostID]
        )
        return try rows.compactMap { row in
            guard let repo = try Repo.fetchOne(db, key: row["repo_id"] as Int64) else { return nil }
            return HostRepoCheckout(repo: repo, path: row["checkout_path"])
        }
    }

    private static func ensureFree(_ db: Database, host: RemoteHost, repo: Repo, path: String) throws {
        let holder = try Int64.fetchOne(
            db,
            sql: "SELECT repo_id FROM host_repo WHERE host_id = ? AND checkout_path = ? AND repo_id != ?",
            arguments: [host.id, path, repo.id]
        )
        guard let holder else { return }
        let name = try Repo.fetchOne(db, key: holder)?.fullName ?? "another repository"
        throw HostRepoStoreError.pathTaken(path, heldBy: name)
    }

    private func stored(_ db: Database, host: RemoteHost, repo: Repo) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT checkout_path FROM host_repo WHERE host_id = ? AND repo_id = ?",
            arguments: [host.id, repo.id]
        )
    }

    private static func likePrefix(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
