@testable import Loom
import XCTest

final class LRUTrackerTests: XCTestCase {

    func testEmptyAfterInit() {
        let tracker = LRUTracker<Int>(capacity: 3)
        XCTAssertEqual(tracker.keysInLRUOrder, [])
    }

    func testInsertsKeepOrderUntilCapacityExceeded() {
        var tracker = LRUTracker<Int>(capacity: 3)
        XCTAssertNil(tracker.touch(1))
        XCTAssertNil(tracker.touch(2))
        XCTAssertNil(tracker.touch(3))
        XCTAssertEqual(tracker.keysInLRUOrder, [1, 2, 3])
    }

    func testEvictionWhenCapacityExceeded() {
        var tracker = LRUTracker<Int>(capacity: 3)
        _ = tracker.touch(1)
        _ = tracker.touch(2)
        _ = tracker.touch(3)
        let evicted = tracker.touch(4)
        XCTAssertEqual(evicted, 1)
        XCTAssertEqual(tracker.keysInLRUOrder, [2, 3, 4])
    }

    func testTouchingExistingKeyMovesItToMostRecent() {
        var tracker = LRUTracker<Int>(capacity: 3)
        _ = tracker.touch(1)
        _ = tracker.touch(2)
        _ = tracker.touch(3)
        // Touch 1 again — now 2 is the oldest.
        XCTAssertNil(tracker.touch(1))
        XCTAssertEqual(tracker.keysInLRUOrder, [2, 3, 1])

        let evicted = tracker.touch(4)
        XCTAssertEqual(evicted, 2)
    }

    func testRemoveDropsKey() {
        var tracker = LRUTracker<Int>(capacity: 3)
        _ = tracker.touch(1)
        _ = tracker.touch(2)
        _ = tracker.touch(3)
        tracker.remove(2)
        XCTAssertEqual(tracker.keysInLRUOrder, [1, 3])
    }

    func testEightItemPoolMatchesSpec() {
        // Spec §Phase 5: "max 8 live; LRU eviction". 9th touch evicts the first.
        var tracker = LRUTracker<Int>(capacity: 8)
        for index in 1 ... 8 { _ = tracker.touch(index) }
        let evicted = tracker.touch(9)
        XCTAssertEqual(evicted, 1)
        XCTAssertEqual(tracker.keysInLRUOrder.count, 8)
    }
}
