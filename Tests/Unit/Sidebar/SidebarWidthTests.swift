import XCTest
@testable import Yggdrasil

/// The sidebar's width as the user drags its edge.
final class SidebarWidthTests: XCTestCase {
    func testStaysWithinItsLimits() {
        XCTAssertEqual(SidebarWidth.clamped(100, windowWidth: 1600), SidebarWidth.minimum)
        XCTAssertEqual(SidebarWidth.clamped(420, windowWidth: 1600), 420)
        XCTAssertEqual(SidebarWidth.clamped(2000, windowWidth: 3000), SidebarWidth.maximum)
    }

    func testLeavesTheMainPaneItsMinimum() {
        // A narrow window: the main pane keeps 480, the sidebar gets the rest.
        XCTAssertEqual(
            SidebarWidth.clamped(600, windowWidth: 1000),
            1000 - SidebarWidth.mainPaneMinimum - SidebarWidth.dividerWidth, "the divider counts too"
        )
        // Narrower than both minimums together: the sidebar keeps its own.
        XCTAssertEqual(SidebarWidth.clamped(600, windowWidth: 600), SidebarWidth.minimum)
    }
}
