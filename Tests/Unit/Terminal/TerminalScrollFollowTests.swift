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

    // MARK: - Scroll routing (native scrollback vs forward-to-agent)

    func testMouseTrackingForwardsAsMouseWheel() {
        // The agent reads the mouse → forward the wheel, even in the normal buffer.
        XCTAssertEqual(
            TerminalScrollInterceptor.action(
                mouseTracking: true, alternateBuffer: false, upward: true, applicationCursor: false
            ),
            .mouseWheel(upward: true)
        )
        XCTAssertEqual(
            TerminalScrollInterceptor.action(
                mouseTracking: true, alternateBuffer: true, upward: false, applicationCursor: true
            ),
            .mouseWheel(upward: false)
        )
    }

    func testAlternateBufferWithoutMouseSendsArrowKeys() {
        XCTAssertEqual(
            TerminalScrollInterceptor.action(
                mouseTracking: false, alternateBuffer: true, upward: true, applicationCursor: false
            ),
            .arrowKeys(upward: true, applicationCursor: false)
        )
        XCTAssertEqual(
            TerminalScrollInterceptor.action(
                mouseTracking: false, alternateBuffer: true, upward: false, applicationCursor: true
            ),
            .arrowKeys(upward: false, applicationCursor: true)
        )
    }

    func testNormalBufferNoMouseUsesNativeScrollback() {
        // A plain shell keeps SwiftTerm's native scrollback (+ the scroll-follow).
        XCTAssertEqual(
            TerminalScrollInterceptor.action(
                mouseTracking: false, alternateBuffer: false, upward: true, applicationCursor: false
            ),
            .native
        )
    }
}
