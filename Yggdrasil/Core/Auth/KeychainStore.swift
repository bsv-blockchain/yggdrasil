import Foundation
import KeychainAccess

/// Persistent secret storage. Production uses `KeychainAccessStore`; tests use
/// `InMemoryKeychainStore` (lives in the test target).
protocol KeychainStore: Sendable {
    func read(_ key: String) -> String?
    func write(_ value: String, forKey key: String) throws
    func delete(_ key: String) throws
}

/// Real Keychain-backed store. Service string defaults to the app bundle id, so
/// the secret group is the same one `security` will surface under
/// `com.bsvassociation.yggdrasil`.
struct KeychainAccessStore: KeychainStore {
    let keychain: Keychain

    init(service: String = YggdrasilLog.subsystem) {
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlock)
    }

    func read(_ key: String) -> String? {
        try? keychain.get(key)
    }

    func write(_ value: String, forKey key: String) throws {
        try keychain.set(value, key: key)
    }

    func delete(_ key: String) throws {
        try keychain.remove(key)
    }
}
