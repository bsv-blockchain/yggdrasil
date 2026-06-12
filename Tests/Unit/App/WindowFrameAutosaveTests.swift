import AppKit
import XCTest
@testable import Yggdrasil

@MainActor
final class WindowFrameAutosaveTests: XCTestCase {
    private let autosaveName = "TestYggdrasilWindow"

    override func tearDown() {
        // AppKit persists the frame under "NSWindow Frame <name>"; don't leak
        // the test key into the host app's defaults.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
        super.tearDown()
    }

    func testEnableSetsFrameAutosaveName() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowFrameAutosave.enable(on: window, name: autosaveName)

        // Setting the autosave name is what makes AppKit persist + restore the
        // frame across launches; that's the whole fix.
        XCTAssertEqual(window.frameAutosaveName, autosaveName)
    }
}
