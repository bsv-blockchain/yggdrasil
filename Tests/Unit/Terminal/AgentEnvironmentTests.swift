import XCTest
@testable import Yggdrasil

final class AgentEnvironmentTests: XCTestCase {
    // MARK: - parse

    func testParseReadsOneKeyValuePairPerLine() {
        let parsed = AgentEnvironment.parse("ANTHROPIC_BASE_URL=https://work.example\nCLAUDE_PROFILE=work")
        XCTAssertEqual(parsed, ["ANTHROPIC_BASE_URL": "https://work.example", "CLAUDE_PROFILE": "work"])
    }

    func testParseSplitsOnTheFirstEqualsOnly() {
        XCTAssertEqual(AgentEnvironment.parse("TOKEN=a=b=c"), ["TOKEN": "a=b=c"])
    }

    func testParseTrimsWhitespaceAroundKeyAndValue() {
        XCTAssertEqual(AgentEnvironment.parse("  KEY  =  value  "), ["KEY": "value"])
    }

    func testParseSkipsBlankLinesAndComments() {
        let text = """
        # which account this profile signs in with
        CLAUDE_PROFILE=work

        # trailing note, no pair
        """
        XCTAssertEqual(AgentEnvironment.parse(text), ["CLAUDE_PROFILE": "work"])
    }

    func testParseDropsLinesThatArentAUsablePair() {
        // No '=', empty key, and a key with a space in it are all unusable as
        // environment variables — drop them rather than spawn with junk.
        XCTAssertEqual(AgentEnvironment.parse("novalue\n=orphan\nBAD KEY=x\nOK=1"), ["OK": "1"])
    }

    func testParseKeepsAnEmptyValue() {
        // `FOO=` is meaningful: it defines FOO as the empty string, which is
        // distinct from leaving it unset.
        XCTAssertEqual(AgentEnvironment.parse("EMPTY="), ["EMPTY": ""])
    }

    func testParseOfBlankTextIsEmpty() {
        XCTAssertEqual(AgentEnvironment.parse("   \n\n"), [:])
    }

    func testParseStripsCarriageReturnsFromCRLFText() {
        // Pasting from a CRLF source (a .env from a Windows checkout, a copied
        // mail/wiki block) must not leave a \r on the tail of the value — that
        // spawns the agent with a trailing control byte and an opaque auth error.
        let parsed = AgentEnvironment.parse("ANTHROPIC_AUTH_TOKEN=sk-ant-123\r\nCLAUDE_PROFILE=work\r\n")
        XCTAssertEqual(parsed, ["ANTHROPIC_AUTH_TOKEN": "sk-ant-123", "CLAUDE_PROFILE": "work"])
    }

    func testParseStripsMatchedSurroundingQuotesFromTheValue() {
        // `.env` files quote values; pasting one shouldn't export the quotes.
        XCTAssertEqual(AgentEnvironment.parse("FOO=\"bar\""), ["FOO": "bar"])
        XCTAssertEqual(AgentEnvironment.parse("FOO='bar'"), ["FOO": "bar"])
        XCTAssertEqual(AgentEnvironment.parse("FOO=\"\""), ["FOO": ""])
    }

    func testParseKeepsQuotesThatArentAMatchedPair() {
        XCTAssertEqual(AgentEnvironment.parse("FOO=\"bar"), ["FOO": "\"bar"])
        XCTAssertEqual(AgentEnvironment.parse("FOO=a\"b"), ["FOO": "a\"b"])
        XCTAssertEqual(AgentEnvironment.parse("FOO='bar\""), ["FOO": "'bar\""])
        XCTAssertEqual(AgentEnvironment.parse("FOO=\""), ["FOO": "\""])
    }

    // MARK: - render

    func testRenderSortsByKeySoTheEditorDoesntReshuffle() {
        XCTAssertEqual(AgentEnvironment.render(["B": "2", "A": "1"]), "A=1\nB=2")
    }

    func testRenderOfEmptyEnvIsEmptyString() {
        XCTAssertEqual(AgentEnvironment.render([:]), "")
    }

    func testRenderRoundTripsThroughParse() {
        let env = ["ANTHROPIC_BASE_URL": "https://work.example", "CLAUDE_PROFILE": "work"]
        XCTAssertEqual(AgentEnvironment.parse(AgentEnvironment.render(env)), env)
    }

    // MARK: - merged

    func testMergedIsNilWithNoOverridesSoSwiftTermKeepsItsOwnDefaults() {
        // nil is what `startProcess(environment:)` wants when we have nothing to
        // add — anything else would mean re-deriving SwiftTerm's default set.
        XCTAssertNil(AgentEnvironment.merged(defaults: ["TERM=xterm-256color"], overrides: [:]))
    }

    func testMergedKeepsDefaultsAndAppendsNewVariables() throws {
        let merged = try XCTUnwrap(AgentEnvironment.merged(
            defaults: ["TERM=xterm-256color", "HOME=/Users/x"],
            overrides: ["CLAUDE_PROFILE": "work"]
        ))
        XCTAssertEqual(merged, ["TERM=xterm-256color", "HOME=/Users/x", "CLAUDE_PROFILE=work"])
    }

    func testMergedReplacesADefaultOfTheSameName() throws {
        // Duplicate keys in an envp array are resolved by whichever the libc
        // lookup hits first, so the shadowed default has to be removed, not
        // just outranked by position.
        let merged = try XCTUnwrap(AgentEnvironment.merged(
            defaults: ["TERM=xterm-256color", "HOME=/Users/x"],
            overrides: ["TERM": "screen-256color"]
        ))
        XCTAssertEqual(merged, ["HOME=/Users/x", "TERM=screen-256color"])
        XCTAssertEqual(merged.filter { $0.hasPrefix("TERM=") }.count, 1)
    }

    func testMergedEmitsOverridesInStableKeyOrder() throws {
        let merged = try XCTUnwrap(AgentEnvironment.merged(
            defaults: [],
            overrides: ["B": "2", "A": "1", "C": "3"]
        ))
        XCTAssertEqual(merged, ["A=1", "B=2", "C=3"])
    }
}
