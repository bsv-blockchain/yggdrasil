import XCTest
@testable import Yggdrasil

/// The viewport "freeze" decision behind the don't-snap-to-bottom-while-reading
/// behaviour. The full integration (output not yanking the viewport down) needs
/// a live SwiftTerm + PTY and is verified by hand; this locks the pure mapping.
@MainActor
final class TerminalScrollFollowTests: XCTestCase {
    func testAtBottomFollowsTail() {
        // 1.0 == pinned to the bottom → nil means "follow new output".
        XCTAssertNil(DroppableTerminalView.frozenTarget(forScrollPosition: 1.0))
    }

    func testPastBottomStillFollowsTail() {
        XCTAssertNil(DroppableTerminalView.frozenTarget(forScrollPosition: 1.5))
    }

    func testScrolledUpPinsToThatFraction() {
        XCTAssertEqual(DroppableTerminalView.frozenTarget(forScrollPosition: 0.5), 0.5)
        XCTAssertEqual(DroppableTerminalView.frozenTarget(forScrollPosition: 0.0), 0.0)
    }
}
