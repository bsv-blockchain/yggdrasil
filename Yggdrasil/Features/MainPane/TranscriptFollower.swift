import AppKit
import SwiftUI

/// Whether the transcript view follows new output. Only the reader's own
/// scrolling changes it: new rows push the end down, and judging "at the
/// bottom" from where it lands would stop following on every row.
struct TranscriptFollow {
    private(set) var following = true
    /// How close to the end still counts as at it.
    static let slack: CGFloat = 24

    /// Any scroll up stops following, even a nudge: with rows arriving
    /// fast, a few points up would still count as at the end and be pulled
    /// straight back. Following resumes once the reader is back at the end.
    mutating func userScrolled(distanceFromBottom: CGFloat, movedUp: Bool) {
        following = !movedUp && distanceFromBottom <= Self.slack
    }

    mutating func reset() {
        following = true
    }
}

/// Keeps the enclosing scroll view at its end while `TranscriptFollow` says
/// so. Put it in the scroll view's content. It owns the scroll offset:
/// mixing in `ScrollViewReader.scrollTo` would fight it.
///
/// AppKit, because SwiftUI on macOS 14 can't tell a reader's scroll from a
/// layout change. `scrollTo` also lands short of the end in a lazy stack,
/// whose heights are estimates; this pins again on every height change.
struct TranscriptFollower: NSViewRepresentable {
    /// A new token, such as another subagent, starts following again.
    let token: String

    func makeNSView(context _: Context) -> TranscriptFollowerView {
        TranscriptFollowerView()
    }

    func updateNSView(_ view: TranscriptFollowerView, context _: Context) {
        view.reset(token: token)
    }
}

final class TranscriptFollowerView: NSView {
    private var follow = TranscriptFollow()
    private var token: String?
    private var observers: [NSObjectProtocol] = []
    private weak var scrollView: NSScrollView?
    /// Where the last scroll left the view, to tell up from down.
    private var lastOffset: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    func reset(token: String) {
        guard token != self.token else { return }
        self.token = token
        follow.reset()
        pinIfFollowing()
    }

    private func attach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil, let scrollView = enclosingScrollView else { return }
        self.scrollView = scrollView
        let center = NotificationCenter.default
        // Posted for the reader's scrolling (wheel, trackpad, scroller), not
        // for programmatic scrolls like the pin below.
        observers.append(center.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            self?.userScrolled()
        })
        // New rows, re-estimated row heights, a resized window.
        for view in [scrollView.documentView, scrollView.contentView].compactMap(\.self) {
            view.postsFrameChangedNotifications = true
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                self?.pinIfFollowing()
            })
        }
        pinIfFollowing()
    }

    private func userScrolled() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let bounds = scrollView.contentView.bounds
        follow.userScrolled(
            distanceFromBottom: document.frame.height - bounds.maxY, movedUp: bounds.origin.y < lastOffset - 0.5
        )
        lastOffset = bounds.origin.y
    }

    /// Pins now and once more on the next turn: SwiftUI can reset the
    /// offset after the frame change that triggered this, as when the first
    /// rows replace "Loading…" or the window shrinks.
    private func pinIfFollowing() {
        pin()
        DispatchQueue.main.async { [weak self] in self?.pin() }
    }

    private func pin() {
        guard follow.following, let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let end = max(0, document.frame.height - clip.bounds.height)
        lastOffset = end
        guard abs(clip.bounds.origin.y - end) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: end))
        scrollView.reflectScrolledClipView(clip)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
