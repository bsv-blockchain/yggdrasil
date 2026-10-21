import Foundation
import GRDB

/// An ssh machine tabs can run on. `ssh_target` is anything `ssh` accepts as a
/// destination (a `~/.ssh/config` alias, `user@host`), so the user's own ssh
/// config, agent and ProxyJump apply unchanged.
struct RemoteHost: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Hashable {
    static let databaseTableName = "host"

    var id: Int64?
    var name: String
    var sshTarget: String
    /// Absolute path on the host under which repos live as `<owner>/<name>`.
    var reposRoot: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sshTarget = "ssh_target"
        case reposRoot = "repos_root"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The target for URLs and scp operands: an IPv6 literal gets brackets,
    /// or its colons would read as a port or a path separator.
    var scpHost: String {
        let user: Substring?
        let address: Substring
        if let separator = sshTarget.lastIndex(of: "@") {
            user = sshTarget[..<separator]
            address = sshTarget[sshTarget.index(after: separator)...]
        } else {
            user = nil
            address = sshTarget[...]
        }
        guard address.contains(":"), !address.hasPrefix("[") else { return sshTarget }
        return (user.map { "\($0)@" } ?? "") + "[\(address)]"
    }

    /// Main checkout of `owner/name` on this host. Worktrees go under its
    /// `.worktrees/`, the same layout as local checkouts.
    func repoPath(owner: String, name: String) -> String {
        var root = reposRoot
        while root.count > 1, root.hasSuffix("/") {
            root.removeLast()
        }
        return "\(root)/\(owner)/\(name)"
    }
}
