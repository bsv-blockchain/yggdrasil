import Foundation
import GRDB

struct Repo: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "repo"

    var id: Int64?
    var owner: String
    var name: String
    var defaultBranch: String
    var localMainPath: String?
    var addedAt: Date
    /// For a fork, the source repo whose issues/PRs also feed this row. Nil for
    /// non-forks or repos not yet probed. `upstreamCheckedAt` distinguishes the
    /// two: set once we've asked GitHub, even when the answer is "not a fork".
    var upstreamOwner: String?
    var upstreamName: String?
    var upstreamCheckedAt: Date?
    /// Tracked repo where this repo's PRs are opened, when that differs from
    /// the repo itself (e.g. a private issue repo whose PRs go to a public
    /// one). Nil = same repo. Default target for "Link PR…".
    var prRepoID: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case defaultBranch = "default_branch"
        case localMainPath = "local_main_path"
        case addedAt = "added_at"
        case upstreamOwner = "upstream_owner"
        case upstreamName = "upstream_name"
        case upstreamCheckedAt = "upstream_checked_at"
        case prRepoID = "pr_repo_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// `owner/name` (e.g. `bsv-blockchain/teranode`). Convenience for log lines and UI.
    var fullName: String {
        "\(owner)/\(name)"
    }

    /// The repo PRs for this repo live in: the configured `prRepoID` when it
    /// is still among `repos`, else this repo itself.
    func prRepo(among repos: [Repo]) -> Repo {
        guard let prRepoID, let target = repos.first(where: { $0.id == prRepoID }) else { return self }
        return target
    }

    /// GitHub repos whose issues + PRs feed this tracked row: always the repo
    /// itself, plus its fork upstream (source) when known. Sync matches incoming
    /// tasks against every pair here and attributes them to this `repo_id`, so a
    /// fork transparently surfaces the upstream's issues.
    var issueSources: [(owner: String, name: String)] {
        var sources = [(owner: owner, name: name)]
        if let upstreamOwner, let upstreamName {
            sources.append((owner: upstreamOwner, name: upstreamName))
        }
        return sources
    }
}
