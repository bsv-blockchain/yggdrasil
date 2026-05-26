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

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case defaultBranch = "default_branch"
        case localMainPath = "local_main_path"
        case addedAt = "added_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// `owner/name` (e.g. `bsv-blockchain/teranode`). Convenience for log lines and UI.
    var fullName: String {
        "\(owner)/\(name)"
    }
}
