import XCTest
@testable import Yggdrasil

final class ReconnectPolicyTests: XCTestCase {
    func testSSHTransportFailureReconnects() {
        // ssh exits 255 on connection errors; SwiftTerm's macOS child monitor
        // hands over the raw waitpid status (255 << 8).
        XCTAssertTrue(ReconnectPolicy.shouldReconnect(isRemote: true, exitCode: 255))
        XCTAssertTrue(ReconnectPolicy.shouldReconnect(isRemote: true, exitCode: 255 << 8))
    }

    func testAgentExitDoesNotReconnect() {
        for code: Int32? in [0, 1, 1 << 8, 130 << 8, nil] {
            XCTAssertFalse(
                ReconnectPolicy.shouldReconnect(isRemote: true, exitCode: code),
                "\(String(describing: code))"
            )
        }
    }

    func testLocalTabsNeverReconnect() {
        XCTAssertFalse(ReconnectPolicy.shouldReconnect(isRemote: false, exitCode: 255 << 8))
    }

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual((0 ..< 8).map(ReconnectPolicy.delaySeconds(attempt:)), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testExitStatusDecodesRawAndPlainCodes() {
        XCTAssertEqual(ReconnectPolicy.exitStatus(0), 0)
        XCTAssertEqual(ReconnectPolicy.exitStatus(1), 1)
        XCTAssertEqual(ReconnectPolicy.exitStatus(1 << 8), 1)
        XCTAssertEqual(ReconnectPolicy.exitStatus(255), 255)
        XCTAssertEqual(ReconnectPolicy.exitStatus(255 << 8), 255)
    }

    func testGivesUpAfterEightFailedAttempts() {
        // ssh's 255 also means auth failure, a changed host key or a host
        // that's gone; don't retry those forever.
        XCTAssertFalse(ReconnectPolicy.shouldGiveUp(attempt: 7))
        XCTAssertTrue(ReconnectPolicy.shouldGiveUp(attempt: 8))
    }
}
