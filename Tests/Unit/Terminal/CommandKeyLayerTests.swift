import Carbon.HIToolbox
import XCTest
@testable import Yggdrasil

/// The Command layer of real system layouts, read without switching the
/// user's active layout. ⌘ shortcuts resolve against this layer, which can
/// differ from what the key types on its own.
final class CommandKeyLayerTests: XCTestCase {
    private func layer(_ name: String) throws -> CommandKeyLayer {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.\(name)"] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        let source = try XCTUnwrap(sources?.first, "\(name) layout not installed")
        return try XCTUnwrap(CommandKeyLayer(source: source))
    }

    func testUSBracketsAreOnTheirUsualKeys() throws {
        let usLayer = try layer("US")
        XCTAssertEqual(usLayer.character(keyCode: 33), "[")
        XCTAssertEqual(usLayer.character(keyCode: 30), "]")
        XCTAssertTrue(usLayer.typesBrackets)
    }

    /// Hebrew types "]" on key 33 by itself, but ⌘ mirrors it back to "[".
    func testHebrewIsReadOnTheCommandLayer() throws {
        let hebrew = try layer("Hebrew")
        XCTAssertEqual(hebrew.character(keyCode: 33), "[")
        XCTAssertEqual(hebrew.character(keyCode: 30), "]")
    }

    /// "Dvorak - QWERTY ⌘" switches to QWERTY while ⌘ is held.
    func testDvorakQwertyCommandUsesQwertyBrackets() throws {
        let qwertyCmd = try layer("DVORAK-QWERTYCMD")
        XCTAssertEqual(qwertyCmd.character(keyCode: 33), "[")
        XCTAssertEqual(qwertyCmd.character(keyCode: 24), "=")
    }

    func testDvorakBracketsAreElsewhere() throws {
        let dvorak = try layer("Dvorak")
        XCTAssertEqual(dvorak.character(keyCode: 33), "/")
        XCTAssertEqual(dvorak.character(keyCode: 27), "[")
        XCTAssertTrue(dvorak.typesBrackets)
    }

    /// Brackets need Option, so no key types them on the Command layer.
    func testIcelandicAndGermanHaveNoBracketKeys() throws {
        XCTAssertEqual(try layer("Icelandic").character(keyCode: 33), "ð")
        XCTAssertFalse(try layer("Icelandic").typesBrackets)
        XCTAssertFalse(try layer("German").typesBrackets)
    }
}
