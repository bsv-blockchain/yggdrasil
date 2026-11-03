import CryptoKit
import Foundation
import GRDB
import Security

/// A key another program uses to reach the control API.
struct APIKey: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    enum Scope: String, Codable, CaseIterable {
        /// State and screens only.
        case read
        /// Everything a user can do, including typing into agents.
        case full
    }

    static let databaseTableName = "api_key"

    var id: Int64?
    var name: String
    var scope: Scope
    /// Hex SHA-256 of the key; the key itself isn't kept.
    var sha256: String
    var createdAt: Date
    var lastUsedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, scope, sha256
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum APIKeyStoreError: Error, Equatable {
    case nameRequired
    case randomUnavailable
}

struct APIKeyStore {
    let database: YggdrasilDatabase

    /// Makes a key. `secret` is the only copy: show it once.
    func create(name: String, scope: APIKey.Scope) throws -> (key: APIKey, secret: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw APIKeyStoreError.nameRequired }
        let secret = try Self.generateSecret()
        var key = APIKey(
            id: nil,
            name: name,
            scope: scope,
            sha256: Self.hash(secret),
            createdAt: Date(),
            lastUsedAt: nil
        )
        try database.queue.write { db in try key.insert(db) }
        return (key, secret)
    }

    func list() throws -> [APIKey] {
        try database.queue.read { db in try APIKey.order(Column("created_at")).fetchAll(db) }
    }

    /// Deletes the key; anything still using it gets 401 from then on.
    func revoke(id: Int64) throws {
        _ = try database.queue.write { db in try APIKey.deleteOne(db, key: id) }
    }

    /// The key `secret` belongs to, if any, after noting that it was used.
    /// Looked up by hash, so the secret is never compared byte by byte.
    func verify(secret: String) throws -> APIKey? {
        guard secret.hasPrefix(Self.prefix) else { return nil }
        let digest = Self.hash(secret)
        return try database.queue.write { db in
            guard var key = try APIKey.filter(Column("sha256") == digest).fetchOne(db) else { return nil }
            key.lastUsedAt = Date()
            try key.update(db)
            return key
        }
    }

    static let prefix = "ygg_"

    static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `ygg_` and 32 random bytes in base62.
    static func generateSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw APIKeyStoreError.randomUnavailable
        }
        return prefix + base62(bytes)
    }

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static func base62(_ bytes: [UInt8]) -> String {
        var number = bytes.map(Int.init)
        var digits: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            var quotient: [Int] = []
            for byte in number {
                let value = remainder * 256 + byte
                let digit = value / 62
                remainder = value % 62
                if !quotient.isEmpty || digit != 0 { quotient.append(digit) }
            }
            digits.append(alphabet[remainder])
            number = quotient
        }
        return String(digits.reversed())
    }
}
