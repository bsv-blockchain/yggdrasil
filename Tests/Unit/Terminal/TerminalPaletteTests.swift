import SwiftTerm
import XCTest
@testable import Yggdrasil

/// Verifies the ANSI palette construction for the light/dark terminal themes.
/// Each palette must hold the full 16-colour set, and the 8-bit→16-bit channel
/// conversion (`byte &* 0x101`) must map 0xff → 0xffff exactly so SwiftTerm
/// renders saturated colours without rounding drift.
final class TerminalPaletteTests: XCTestCase {
    func testPalettesHaveSixteenColors() {
        XCTAssertEqual(AgentTerminalSurface.darkPalette.count, 16)
        XCTAssertEqual(AgentTerminalSurface.lightPalette.count, 16)
    }

    func testChannelConversionScalesByteToSixteenBits() {
        // Dark red (index 1) is 0xff7b72 → (0xffff, 0x7b7b, 0x7272).
        let red = AgentTerminalSurface.darkPalette[1]
        XCTAssertEqual(red.red, 0xFFFF)
        XCTAssertEqual(red.green, UInt16(0x7B) &* 0x101)
        XCTAssertEqual(red.blue, UInt16(0x72) &* 0x101)
    }

    func testLightAndDarkBackgroundsDiffer() {
        // Index 0 is the "black"/background slot; the two themes must not match.
        XCTAssertNotEqual(AgentTerminalSurface.darkPalette[0], AgentTerminalSurface.lightPalette[0])
    }
}
