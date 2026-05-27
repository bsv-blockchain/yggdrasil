import GRDB

struct Setting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"

    var key: String
    var value: String
}
