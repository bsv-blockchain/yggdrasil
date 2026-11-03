import XCTest
@testable import Yggdrasil

/// Settings → API: nothing listens until it's on, and turning it off closes
/// the socket again.
@MainActor
final class ControlServiceTests: XCTestCase {
    func testListensOnlyWhileEnabled() throws {
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        let path = NSTemporaryDirectory() + "ygg-svc-\(UUID().uuidString.prefix(6)).sock"
        let control = ControlService(services: services, socketPath: path)
        try services.settingsStore.set("0", forKey: ControlService.portKey)

        control.apply()
        XCTAssertFalse(control.isRunning, "off by default")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        control.isEnabled = true
        XCTAssertTrue(control.isRunning, control.lastError ?? "")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNil(control.boundPort, "127.0.0.1 only when asked for")

        control.listensOnLoopback = true
        XCTAssertNotNil(control.boundPort)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "a restart keeps the socket")

        control.isEnabled = false
        XCTAssertFalse(control.isRunning)
        XCTAssertNil(control.boundPort)
        // The cancel handler unlinks on the accept queue.
        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testATakenPortLeavesTheSocketWorking() throws {
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        let path = NSTemporaryDirectory() + "ygg-svc-\(UUID().uuidString.prefix(6)).sock"
        let squatter = ControlServer { _, _ in .empty(204) }
        let taken = try squatter.listen(.loopback(port: 0))
        defer { squatter.stop() }
        try services.settingsStore.set(String(taken), forKey: ControlService.portKey)
        let control = ControlService(services: services, socketPath: path)
        defer { control.stop() }
        try services.settingsStore.set("1", forKey: ControlService.loopbackKey)

        control.isEnabled = true

        XCTAssertTrue(control.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(control.lastError)
        control.isEnabled = false
        XCTAssertNil(control.lastError, "off clears it")
    }
}
