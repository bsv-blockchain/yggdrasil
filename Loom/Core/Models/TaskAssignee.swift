import GRDB

struct TaskAssignee: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "task_assignee"

    var taskID: Int64
    var login: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case login
    }
}
