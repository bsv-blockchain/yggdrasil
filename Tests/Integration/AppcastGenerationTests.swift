import XCTest

/// Exercises `Scripts/generate-appcast.sh` — the one piece of release-pipeline
/// logic with a real contract (the rendered feed must be well-formed XML and
/// carry the exact version / URL / signature / length the updater verifies).
/// The script is located relative to this source file so the test works from
/// both a dev checkout and CI.
final class AppcastGenerationTests: XCTestCase {
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/Integration/AppcastGenerationTests.swift
            .deletingLastPathComponent() // …/Tests/Integration
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Scripts/generate-appcast.sh")
    }

    private let validEnv = [
        "VERSION": "0.5.0",
        "BUILD": "6",
        "DMG_URL": "https://github.com/bsv-blockchain/yggdrasil/releases/download/v0.5.0/Yggdrasil-0.5.0.dmg",
        "DMG_LENGTH": "12345678",
        "ED_SIGNATURE": "xH+PI3hRepFEPWbtteLR+5rcjYo6h06rjDeEIy1PedLMal73PuzBMhyZfWtkP1VePby4r11z2X0w1sdwLKkvBA==",
        "MIN_SYSTEM": "14.0",
        "PUB_DATE": "Thu, 12 Jun 2026 10:00:00 +0000",
        "RELEASE_NOTES_LINK": "https://github.com/bsv-blockchain/yggdrasil/releases/tag/v0.5.0"
    ]

    /// Run the script with the given environment; returns (exitCode, stdout).
    private func run(env: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testRendersWellFormedXML() throws {
        let result = try run(env: validEnv)
        XCTAssertEqual(result.status, 0)
        let parser = XMLParser(data: Data(result.output.utf8))
        XCTAssertTrue(parser.parse(), "appcast output must be well-formed XML")
    }

    func testEnclosureCarriesVersionURLSignatureAndLength() throws {
        let xml = try run(env: validEnv).output
        XCTAssertTrue(xml.contains("sparkle:version=\"6\""), "build number drives Sparkle ordering")
        XCTAssertTrue(xml.contains("sparkle:shortVersionString=\"0.5.0\""))
        XCTAssertTrue(xml.contains("url=\"\(validEnv["DMG_URL"]!)\""))
        XCTAssertTrue(xml.contains("length=\"12345678\""))
        XCTAssertTrue(xml.contains("sparkle:edSignature=\"\(validEnv["ED_SIGNATURE"]!)\""))
        XCTAssertTrue(xml.contains("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"))
    }

    func testReleaseNotesLinkOmittedWhenUnset() throws {
        var env = validEnv
        env.removeValue(forKey: "RELEASE_NOTES_LINK")
        let xml = try run(env: env).output
        XCTAssertFalse(xml.contains("sparkle:releaseNotesLink"))
    }

    func testMissingRequiredVariableFails() throws {
        var env = validEnv
        env.removeValue(forKey: "ED_SIGNATURE")
        let result = try run(env: env)
        XCTAssertNotEqual(result.status, 0, "missing a required input must fail the build, not emit a half-signed feed")
    }
}
