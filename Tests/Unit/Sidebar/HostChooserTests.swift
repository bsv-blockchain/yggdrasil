import XCTest
@testable import Yggdrasil

/// Which machine a task picker opens a tab on.
final class HostChooserTests: XCTestCase {
    private let dev = RemoteHost(id: 1, name: "dev", sshTarget: "dev", reposRoot: "/srv", createdAt: Date())
    private let build = RemoteHost(id: 2, name: "build", sshTarget: "build", reposRoot: "/srv", createdAt: Date())

    func testNoSelectionMeansThisMac() {
        XCTAssertNil(HostChooser.resolveHost(selectedID: nil, hosts: [dev, build]))
    }

    func testSelectedHostIsUsed() {
        XCTAssertEqual(HostChooser.resolveHost(selectedID: 2, hosts: [dev, build]), build)
    }

    func testHostRemovedWhileTheWindowWasOpenFallsBackToThisMac() {
        // Never open on a machine that's no longer configured.
        XCTAssertNil(HostChooser.resolveHost(selectedID: 3, hosts: [dev, build]))
    }

    func testInitialSelectionIsTheDefaultHostWhenItStillExists() {
        XCTAssertEqual(HostChooser.initialSelection(defaultHostID: 1, hosts: [dev, build]), 1)
        XCTAssertNil(HostChooser.initialSelection(defaultHostID: 9, hosts: [dev, build]))
        XCTAssertNil(HostChooser.initialSelection(defaultHostID: nil, hosts: [dev, build]))
    }
}
