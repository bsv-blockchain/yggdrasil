import XCTest
@testable import Yggdrasil

/// API keys: only a hash is stored, the secret is shown once, and a revoked
/// key stops working.
final class APIKeyStoreTests: XCTestCase {
    private var store: APIKeyStore!

    override func setUpWithError() throws {
        store = try APIKeyStore(database: YggdrasilDatabase.inMemory())
    }

    func testANewKeyIsShownOnceAndOnlyItsHashIsKept() throws {
        let (key, secret) = try store.create(name: "Claude Code", scope: .full)
        XCTAssertTrue(secret.hasPrefix("ygg_"))
        XCTAssertGreaterThanOrEqual(secret.count, 4 + 40, "32 random bytes in base62")
        XCTAssertEqual(key.name, "Claude Code")
        XCTAssertEqual(key.scope, .full)
        XCTAssertNotEqual(key.sha256, secret)
        XCTAssertEqual(key.sha256, APIKeyStore.hash(secret))
        XCTAssertFalse(try store.list().contains { $0.sha256.contains(secret) })
    }

    func testVerifyFindsTheKeyAndRecordsItsUse() throws {
        let (key, secret) = try store.create(name: "Grok", scope: .read)
        XCTAssertNil(key.lastUsedAt)
        let verified = try XCTUnwrap(store.verify(secret: secret))
        XCTAssertEqual(verified.id, key.id)
        XCTAssertEqual(verified.scope, .read)
        XCTAssertNotNil(try store.list().first?.lastUsedAt)
    }

    func testAWrongOrRevokedKeyIsRejected() throws {
        let (key, secret) = try store.create(name: "Grok", scope: .read)
        XCTAssertNil(try store.verify(secret: secret + "x"))
        XCTAssertNil(try store.verify(secret: ""))
        try store.revoke(id: XCTUnwrap(key.id))
        XCTAssertNil(try store.verify(secret: secret))
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testEveryKeyIsDifferent() throws {
        let secrets = try (0 ..< 20).map { try store.create(name: "k\($0)", scope: .read).secret }
        XCTAssertEqual(Set(secrets).count, 20)
    }

    func testANameIsRequired() {
        XCTAssertThrowsError(try store.create(name: "  ", scope: .read))
    }
}
