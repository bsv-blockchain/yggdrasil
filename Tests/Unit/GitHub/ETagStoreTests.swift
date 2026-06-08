import XCTest
@testable import Yggdrasil

final class ETagStoreTests: XCTestCase {
    private var db: YggdrasilDatabase!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testRoundTripForURL() throws {
        let store = ETagStore(database: db)
        let url = try XCTUnwrap(URL(string: "https://api.github.com/issues?filter=assigned&state=open"))
        try store.set("W/\"abc\"", for: url)
        XCTAssertEqual(try store.get(for: url), "W/\"abc\"")
    }

    func testMissingURLReturnsNil() throws {
        let store = ETagStore(database: db)
        XCTAssertNil(try store.get(for: XCTUnwrap(URL(string: "https://api.github.com/x"))))
    }

    func testDifferentURLsAreIndependent() throws {
        let store = ETagStore(database: db)
        let urlA = try XCTUnwrap(URL(string: "https://api.github.com/a"))
        let urlB = try XCTUnwrap(URL(string: "https://api.github.com/b"))
        try store.set("etag-a", for: urlA)
        try store.set("etag-b", for: urlB)
        XCTAssertEqual(try store.get(for: urlA), "etag-a")
        XCTAssertEqual(try store.get(for: urlB), "etag-b")
    }

    func testOverwriteUpdatesValue() throws {
        let store = ETagStore(database: db)
        let url = try XCTUnwrap(URL(string: "https://api.github.com/x"))
        try store.set("v1", for: url)
        try store.set("v2", for: url)
        XCTAssertEqual(try store.get(for: url), "v2")
    }

    func testIsNamespacedFromOtherSettings() throws {
        let etags = ETagStore(database: db)
        let settings = SettingsStore(database: db)
        let url = try XCTUnwrap(URL(string: "https://api.github.com/x"))
        try etags.set("etag-value", for: url)
        // A plain settings get for the raw URL must not see the etag — they're
        // stored under a namespaced key.
        XCTAssertNil(try settings.get(forKey: url.absoluteString))
    }
}
