import AppKit
import XCTest
@testable import Yggdrasil

/// Guards the invariants that turned dangerous the moment the View-menu tab
/// group actually started dispatching: the remove-tab prompt must not put the
/// destructive option on the Return key, and the commands must only act when
/// the main sessions window is the one in front.
final class TabCommandsTests: XCTestCase {
    // MARK: - Remove-tab prompt ordering

    /// NSAlert binds Return to the first button it was given. Whatever the
    /// order ends up being, the leading choice must never be the one that runs
    /// `git worktree remove --force`.
    func testDefaultChoiceIsNotDestructive() throws {
        let first = try XCTUnwrap(SidebarActions.RemoveTabChoice.allCases.first)
        XCTAssertFalse(first.isDestructive, "Return must not trigger worktree deletion")
        XCTAssertEqual(first, .tabOnly)
    }

    func testWorktreeDeletionIsOfferedButNeverFirst() throws {
        let cases = SidebarActions.RemoveTabChoice.allCases
        let index = try XCTUnwrap(cases.firstIndex(of: .tabAndWorktree))
        XCTAssertGreaterThan(index, 0)
        XCTAssertTrue(SidebarActions.RemoveTabChoice.tabAndWorktree.isDestructive)
    }

    func testCancelIsTheOnlyOtherNonDestructiveChoice() {
        let destructive = SidebarActions.RemoveTabChoice.allCases.filter(\.isDestructive)
        XCTAssertEqual(destructive, [.tabAndWorktree])
    }

    /// The alert adds its buttons by iterating `allCases`, so the response
    /// mapping has to read back in that same order — otherwise "Remove Tab
    /// Only" would silently perform the deletion.
    func testResponseMappingFollowsButtonOrder() {
        let cases = SidebarActions.RemoveTabChoice.allCases
        XCTAssertEqual(SidebarActions.RemoveTabChoice.from(response: .alertFirstButtonReturn), cases[0])
        XCTAssertEqual(SidebarActions.RemoveTabChoice.from(response: .alertSecondButtonReturn), cases[1])
        XCTAssertEqual(SidebarActions.RemoveTabChoice.from(response: .alertThirdButtonReturn), .cancel)
    }

    /// Anything unexpected coming back from the modal must land on Cancel, not
    /// on a removal.
    func testUnknownResponseCancels() {
        XCTAssertEqual(SidebarActions.RemoveTabChoice.from(response: .abort), .cancel)
        XCTAssertEqual(SidebarActions.RemoveTabChoice.from(response: .stop), .cancel)
    }

    func testChoiceTitlesMatchMenuCopy() {
        XCTAssertEqual(SidebarActions.RemoveTabChoice.tabOnly.title, "Remove Tab Only")
        XCTAssertEqual(SidebarActions.RemoveTabChoice.tabAndWorktree.title, "Remove Tab + Worktree")
        XCTAssertEqual(SidebarActions.RemoveTabChoice.cancel.title, "Cancel")
    }

    // MARK: - Window scoping

    func testMainWindowPredicateAcceptsOnlyTheSessionsWindow() {
        XCTAssertTrue(WindowFrameAutosave.isMainWindow(autosaveName: WindowFrameAutosave.mainWindowName))
        XCTAssertFalse(WindowFrameAutosave.isMainWindow(autosaveName: nil))
        XCTAssertFalse(WindowFrameAutosave.isMainWindow(autosaveName: ""))
        XCTAssertFalse(WindowFrameAutosave.isMainWindow(autosaveName: "ReviewPickerWindow"))
    }

    /// `enable` has to actually stamp the name onto the window — that stamp is
    /// what the gate reads back off `NSApp.keyWindow`. Uses a throwaway name:
    /// autosave names are unique per app and the test bundle is hosted in the
    /// real app, whose main window may already hold the production one.
    @MainActor
    func testEnableStampsAutosaveNameAndAuxWindowsAreNotMain() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        // NSWindow still defaults to release-on-close, which double-frees under ARC.
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertFalse(
            WindowFrameAutosave.isMainWindow(autosaveName: window.frameAutosaveName),
            "a bare window must not pass the gate"
        )

        let name = "YggdrasilTestWindow-\(UUID().uuidString)"
        WindowFrameAutosave.enable(on: window, name: name)
        XCTAssertEqual(window.frameAutosaveName, name)
        XCTAssertFalse(WindowFrameAutosave.isMainWindow(autosaveName: window.frameAutosaveName))
    }
}
