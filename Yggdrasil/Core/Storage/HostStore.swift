import Foundation
import GRDB

enum HostStoreError: Error, Equatable {
    case invalidSSHTarget(String)
    case reposRootNotAbsolute(String)
    case hostInUse(Int64)
}

/// Typed CRUD over the `host` table.
struct HostStore {
    let database: YggdrasilDatabase

    func list() throws -> [RemoteHost] {
        try database.queue.read { db in
            try RemoteHost.fetchAll(db, sql: "SELECT * FROM host ORDER BY name COLLATE NOCASE")
        }
    }

    func get(id: Int64) throws -> RemoteHost? {
        try database.queue.read { db in try RemoteHost.fetchOne(db, key: id) }
    }

    func add(name: String, sshTarget: String, reposRoot: String) throws -> RemoteHost {
        try Self.validate(sshTarget: sshTarget, reposRoot: reposRoot)
        return try database.queue.write { db in
            var host = RemoteHost(
                id: nil, name: name, sshTarget: sshTarget, reposRoot: reposRoot, createdAt: Date()
            )
            try host.insert(db)
            return host
        }
    }

    /// A new repos root only applies to repos not yet used on the host; the
    /// checkouts already pinned in `host_repo` stay where they are.
    /// The ssh target can't change while tabs run on the host: they'd
    /// reattach, probe and remove worktrees on another machine.
    func update(id: Int64, name: String, sshTarget: String, reposRoot: String) throws {
        try Self.validate(sshTarget: sshTarget, reposRoot: reposRoot)
        try database.queue.write { db in
            let current = try RemoteHost.fetchOne(db, key: id)
            if let current, current.sshTarget != sshTarget {
                let tabs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tab WHERE host_id = ?", arguments: [id]) ?? 0
                guard tabs == 0 else { throw HostStoreError.hostInUse(id) }
            }
            try db.execute(
                sql: "UPDATE host SET name = ?, ssh_target = ?, repos_root = ? WHERE id = ?",
                arguments: [name, sshTarget, reposRoot, id]
            )
        }
    }

    private static func validate(sshTarget: String, reposRoot: String) throws {
        // The target is passed to ssh as an argument after `--`, but reject a
        // leading `-` anyway: it's never a valid destination.
        guard !sshTarget.isEmpty, !sshTarget.hasPrefix("-"),
              !sshTarget.contains(where: \.isWhitespace)
        else { throw HostStoreError.invalidSSHTarget(sshTarget) }
        guard reposRoot.hasPrefix("/") else { throw HostStoreError.reposRootNotAbsolute(reposRoot) }
    }

    /// Refuses while any tab runs on the host: dropping it would leave those
    /// tabs pointing at remote paths as if they were local.
    func remove(id: Int64) throws {
        try database.queue.write { db in
            let tabs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tab WHERE host_id = ?", arguments: [id]) ?? 0
            guard tabs == 0 else { throw HostStoreError.hostInUse(id) }
            try db.execute(sql: "DELETE FROM host WHERE id = ?", arguments: [id])
        }
    }
}
