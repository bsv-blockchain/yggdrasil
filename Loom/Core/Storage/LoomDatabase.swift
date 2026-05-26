import Foundation
import GRDB

/// Owns the GRDB `DatabaseQueue` for Loom. Created either against a real on-disk
/// SQLite file under `~/Library/Application Support/Loom/loom.sqlite` (production)
/// or against an in-memory database (tests).
final class LoomDatabase {
    let queue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// In-memory database, fully migrated. Used by unit tests.
    static func inMemory() throws -> LoomDatabase {
        let queue = try DatabaseQueue()
        try Migrations.register().migrate(queue)
        return LoomDatabase(queue: queue)
    }

    /// Default on-disk database at `~/Library/Application Support/Loom/loom.sqlite`.
    /// Creates the containing directory if it doesn't exist.
    static func openDefault(fileManager: FileManager = .default) throws -> LoomDatabase {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Loom", isDirectory: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let url = appSupport.appendingPathComponent("loom.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.register().migrate(queue)
        return LoomDatabase(queue: queue)
    }
}
