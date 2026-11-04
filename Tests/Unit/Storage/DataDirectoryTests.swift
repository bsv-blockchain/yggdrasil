import XCTest
@testable import Yggdrasil

/// Where the database and the control socket live.
final class DataDirectoryTests: XCTestCase {
    func testDefaultsToApplicationSupport() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(
            DataDirectory.url(environment: [:]),
            support.appendingPathComponent("Yggdrasil", isDirectory: true)
        )
        XCTAssertEqual(
            DataDirectory.url(environment: ["YGGDRASIL_DATA_DIR": ""]),
            support.appendingPathComponent("Yggdrasil", isDirectory: true)
        )
    }

    func testTheEnvironmentCanMoveIt() {
        // For running a build without touching the real database.
        XCTAssertEqual(
            DataDirectory.url(environment: ["YGGDRASIL_DATA_DIR": "/tmp/ygg-e2e"]).path, "/tmp/ygg-e2e"
        )
        XCTAssertEqual(
            ControlService.socketPath(environment: ["YGGDRASIL_DATA_DIR": "/tmp/ygg-e2e"]), "/tmp/ygg-e2e/control.sock"
        )
    }
}
