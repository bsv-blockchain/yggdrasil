import Foundation
import GRDB

/// Owns the GRDB `DatabaseQueue` for Yggdrasil. Created either against a real on-disk
/// SQLite file under `~/Library/Application Support/Yggdrasil/yggdrasil.sqlite` (production)
/// or against an in-memory database (tests).
final class YggdrasilDatabase {
    let queue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// In-memory database, fully migrated. Used by unit tests.
    static func inMemory() throws -> YggdrasilDatabase {
        let queue = try DatabaseQueue()
        try Migrations.register().migrate(queue)
        return YggdrasilDatabase(queue: queue)
    }

    /// Default on-disk database at `~/Library/Application Support/Yggdrasil/yggdrasil.sqlite`.
    /// Creates the containing directory if it doesn't exist.
    static func openDefault(fileManager: FileManager = .default) throws -> YggdrasilDatabase {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Yggdrasil", isDirectory: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let url = appSupport.appendingPathComponent("yggdrasil.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.register().migrate(queue)
        return YggdrasilDatabase(queue: queue)
    }
}
