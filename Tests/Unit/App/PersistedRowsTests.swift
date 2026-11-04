import XCTest
@testable import Yggdrasil

/// `PersistedRow` exists to give a `List` row a non-optional identity. GRDB
/// records carry `id: Int64?`, and both of `List`'s selection channels — the
/// `ForEach` element identity and the `.tag` value — have to match the
/// selection's wrapped type (`Int64`) or the list silently stops selecting.
///
/// These cover the pairing only. Whether SwiftUI then matches the tag is not
/// observable from a unit test; that is verified by clicking a row in a build.
final class PersistedRowsTests: XCTestCase {
    private struct Record: Equatable {
        var id: Int64?
        var name: String
    }

    /// The invariant that actually broke: the row's identity type must be the
    /// selection's wrapped type, never the optional the record carries.
    func testRowIdentityIsNonOptionalInt64() {
        XCTAssertTrue(PersistedRow<Record>.ID.self == Int64.self)
    }

    func testPairsEachRecordWithItsUnwrappedIDInOrder() {
        let rows = PersistedRow.rows(
            from: [Record(id: 9, name: "c"), Record(id: 2, name: "a")], by: \.id
        )
        XCTAssertEqual(rows.map(\.id), [9, 2])
        XCTAssertEqual(rows.map(\.value.name), ["c", "a"])
    }

    /// Can't happen with records loaded from SQLite, but the choice is
    /// deliberate: drop rather than invent a colliding sentinel id.
    func testDropsRecordsWithNoID() {
        let rows = PersistedRow.rows(
            from: [Record(id: 1, name: "saved"), Record(id: nil, name: "unsaved")], by: \.id
        )
        XCTAssertEqual(rows.map(\.id), [1])
    }
}
