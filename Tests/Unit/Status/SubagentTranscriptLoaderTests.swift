import XCTest
@testable import Yggdrasil

/// The transcript view's reader for a subagent on a host: one fetch at a
/// time, the known size passed back, and nothing left running after stop.
@MainActor
final class SubagentTranscriptLoaderTests: XCTestCase {
    private actor Calls {
        private(set) var knownSizes: [UInt64?] = []
        func record(_ size: UInt64?) -> Int {
            knownSizes.append(size)
            return knownSizes.count
        }
    }

    func testShowsTheHostsTranscriptAndAsksOnlyForChanges() async throws {
        let calls = Calls()
        let line = Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#.utf8)
        let loader = SubagentTranscriptLoader()
        loader.start(.remote { known in
            let count = await calls.record(known)
            return count == 1 ? .lines(line, size: 42) : .unchanged
        })
        try await waitUntil { !loader.entries.isEmpty }
        XCTAssertEqual(loader.entries, [.text("Hello")])
        XCTAssertFalse(loader.missing)

        try await waitUntil(timeout: 8) { await calls.knownSizes.count >= 2 }
        let sizes = await calls.knownSizes
        XCTAssertEqual(sizes.prefix(2), [nil, 42])
        XCTAssertEqual(loader.entries, [.text("Hello")], "unchanged keeps what's shown")

        loader.stop()
        let afterStop = await calls.knownSizes.count
        try await Task.sleep(for: .seconds(4))
        let later = await calls.knownSizes.count
        XCTAssertEqual(later, afterStop, "no fetches after stop")
    }

    func testNothingToReadSaysSo() {
        let loader = SubagentTranscriptLoader()
        loader.start(nil)
        XCTAssertTrue(loader.missing)
        XCTAssertTrue(loader.entries.isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
