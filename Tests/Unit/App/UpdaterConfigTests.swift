import XCTest

/// The updater is configured entirely through Info.plist keys read by Sparkle
/// at runtime (`project.yml` → bundle). If those keys are missing or point at
/// the wrong repo, auto-update silently never fires — so guard them. The test
/// host is Yggdrasil.app, so `Bundle.main` is the real app bundle.
final class UpdaterConfigTests: XCTestCase {
    func testFeedURLPointsAtReleaseAppcast() throws {
        let feed = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            "SUFeedURL missing from Info.plist"
        )
        XCTAssertEqual(
            feed,
            "https://github.com/bsv-blockchain/yggdrasil/releases/latest/download/appcast.xml"
        )
    }

    func testPublicEdKeyIsPresent() throws {
        let key = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            "SUPublicEDKey missing from Info.plist"
        )
        XCTAssertFalse(key.isEmpty, "EdDSA public key must be set or signature checks can't run")
    }

    func testAutomaticChecksEnabled() {
        let enabled = Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool
        XCTAssertEqual(enabled, true)
    }
}
