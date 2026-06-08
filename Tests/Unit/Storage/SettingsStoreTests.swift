import GRDB
import XCTest
@testable import Yggdrasil

final class SettingsStoreTests: XCTestCase {
    private var db: YggdrasilDatabase!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testWriteAndReadBack() throws {
        let store = SettingsStore(database: db)
        try store.set("hello", forKey: "greeting")
        XCTAssertEqual(try store.get(forKey: "greeting"), "hello")
    }

    func testMissingKeyReturnsNil() throws {
        let store = SettingsStore(database: db)
        XCTAssertNil(try store.get(forKey: "nope"))
    }

    func testOverwriteReplacesValue() throws {
        let store = SettingsStore(database: db)
        try store.set("v1", forKey: "k")
        try store.set("v2", forKey: "k")
        XCTAssertEqual(try store.get(forKey: "k"), "v2")
    }

    func testEmptyValueIsPersisted() throws {
        let store = SettingsStore(database: db)
        try store.set("", forKey: "empty")
        XCTAssertEqual(try store.get(forKey: "empty"), "")
    }
}
