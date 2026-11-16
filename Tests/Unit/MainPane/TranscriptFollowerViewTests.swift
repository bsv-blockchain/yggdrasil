import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Yggdrasil

/// The follower in a real window: SwiftUI's own scroll view and lazy stack,
/// and scroll-wheel events as a mouse sends them.
@MainActor
final class TranscriptFollowerViewTests: XCTestCase {
    @Observable
    final class Rows {
        var ids: [Int] = []
        func add(_ count: Int) {
            let start = ids.count
            ids += Array(start ..< start + count)
        }
    }

    struct Transcript: View {
        let rows: Rows
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // As in the real view: a placeholder the first rows replace.
                    if rows.ids.isEmpty { Text("Loading…") }
                    ForEach(rows.ids, id: \.self) { id in
                        Text((0 ..< id % 5 + 1).map { "row \(id) line \($0)" }.joined(separator: "\n"))
                    }
                }
                .padding(14)
                .background(TranscriptFollower(token: "agent"))
            }
        }
    }

    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private let rows = Rows()

    override func setUp() async throws {
        let host = NSHostingView(rootView: Transcript(rows: rows))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        await settle()
        scrollView = try XCTUnwrap(Self.scrollView(in: host))
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
    }

    func testOpensAtTheEndAndFollows() async {
        rows.add(300)
        await settle()
        XCTAssertLessThan(distanceFromBottom, 1, "opens at the end")
        rows.add(3)
        await settle()
        XCTAssertLessThan(distanceFromBottom, 1, "follows new rows")
    }

    func testScrollingUpHoldsTheTextAndScrollingBackFollowsAgain() async {
        rows.add(300)
        await settle()
        wheel(by: 100, times: 4)
        await settle()
        let reading = offset
        XCTAssertGreaterThan(distanceFromBottom, 100)
        rows.add(5)
        await settle()
        XCTAssertEqual(offset, reading, accuracy: 0.5, "what's being read stays put")
        wheel(by: -400, times: 20)
        await settle()
        rows.add(2)
        await settle()
        XCTAssertLessThan(distanceFromBottom, 1, "follows again once back at the end")
    }

    func testANudgeUpStopsFollowing() async {
        rows.add(300)
        await settle()
        wheel(by: 8)
        await settle()
        let reading = offset
        rows.add(2)
        await settle()
        XCTAssertEqual(offset, reading, accuracy: 0.5)
    }

    // MARK: - Helpers

    private var offset: CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    private var distanceFromBottom: CGFloat {
        (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.maxY
    }

    /// A mouse wheel's event; positive scrolls up.
    private func wheel(by pixels: Int32, times: Int = 1) {
        for _ in 0 ..< times {
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0
            ), let event = NSEvent(cgEvent: cgEvent) else { return XCTFail("no wheel event") }
            scrollView.scrollWheel(with: event)
        }
    }

    /// Lets SwiftUI lay out and the follower's notifications run.
    private func settle() async {
        for _ in 0 ..< 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            await Task.yield()
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}
