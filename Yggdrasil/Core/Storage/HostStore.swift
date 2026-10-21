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
        // The target is passed to ssh as an argument after `--`, but reject a
        // leading `-` anyway: it's never a valid destination.
        guard !sshTarget.isEmpty, !sshTarget.hasPrefix("-"),
              !sshTarget.contains(where: \.isWhitespace)
        else { throw HostStoreError.invalidSSHTarget(sshTarget) }
        guard reposRoot.hasPrefix("/") else { throw HostStoreError.reposRootNotAbsolute(reposRoot) }
        return try database.queue.write { db in
            var host = RemoteHost(
                id: nil, name: name, sshTarget: sshTarget, reposRoot: reposRoot, createdAt: Date()
            )
            try host.insert(db)
            return host
        }
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
