import Foundation

/// Persistent URL → ETag map, layered on top of the `setting` table.
/// Keys are namespaced as `etag:<canonical-url>` so they never collide with other settings.
struct ETagStore {
    static let prefix = "etag:"

    let settings: SettingsStore

    init(database: YggdrasilDatabase) {
        self.settings = SettingsStore(database: database)
    }

    func get(for url: URL) throws -> String? {
        try settings.get(forKey: Self.prefix + url.absoluteString)
    }

    func set(_ etag: String, for url: URL) throws {
        try settings.set(etag, forKey: Self.prefix + url.absoluteString)
    }
}
