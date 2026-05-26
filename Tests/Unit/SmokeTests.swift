import AppKit
@testable import Loom
import XCTest

final class SmokeTests: XCTestCase {
    func testAppVendsAWindowTitledLoom() {
        // The test bundle is hosted by Loom.app, so NSApplication.shared *is*
        // the running app. Wait briefly for SwiftUI to materialise its window.
        let app = NSApplication.shared
        let deadline = Date().addingTimeInterval(5)
        while app.windows.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(app.windows.isEmpty, "App must vend at least one NSWindow")

        let titles = app.windows.map(\.title)
        XCTAssertTrue(
            titles.contains(where: { $0.contains("Loom") }),
            "At least one window must have a title containing 'Loom'; got: \(titles)"
        )
    }

    func testLoggerSubsystemHasExpectedCategories() {
        XCTAssertEqual(LoomLog.subsystem, "com.bsvassociation.loom")
        XCTAssertEqual(
            LoomLog.allCategories.sorted(),
            ["auth", "db", "git", "pty", "sync", "ui"]
        )
    }

    func testDependencySmokeImportsAllFourPackages() {
        XCTAssertEqual(
            DependencySmokeImports.resolved,
            ["SwiftTerm", "GRDB", "Clibgit2", "KeychainAccess"]
        )
    }

    func testLibgit2LinksAndReportsAVersion() {
        let probe = DependencySmokeImports.liveLinkageProbe()
        XCTAssertEqual(probe.count, 1)
        XCTAssertTrue(
            probe[0].hasPrefix("libgit2 v"),
            "Expected libgit2 version string; got: \(probe[0])"
        )
    }

    func testBundleIdentifierMatchesSpec() {
        // App target's bundle ID must equal the logger subsystem so os_log
        // categories surface under the same prefix in Console.app.
        let appBundleID = Bundle.main.bundleIdentifier
        // Under XCTest the host bundle is the app under test.
        XCTAssertNotNil(appBundleID)
        XCTAssertEqual(appBundleID, LoomLog.subsystem)
    }
}
