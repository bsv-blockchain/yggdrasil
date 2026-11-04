import AppKit
import SwiftUI

/// Persists the main window's frame — size *and* position, including which
/// display it's on — across launches.
///
/// SwiftUI's `WindowGroup` exposes no frame-autosave API, and macOS's default
/// "Close windows when quitting an app" setting discards SwiftUI's automatic
/// state restoration. The net effect was that a plain relaunch always reopened
/// at the default size on the primary screen. AppKit's frame autosave writes to
/// `UserDefaults` independently of that setting, so it restores reliably.
///
/// Dropped into the main window's view tree as a zero-size background; it grabs
/// the host `NSWindow` on attach and wires up autosave. Aux windows
/// (Preferences, pickers) are separate scenes and intentionally unaffected.
struct WindowFrameAutosaver: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context _: Context) -> NSView {
        AnchorView(autosaveName: autosaveName)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class AnchorView: NSView {
        let autosaveName: String

        init(autosaveName: String) {
            self.autosaveName = autosaveName
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowFrameAutosave.enable(on: window, name: autosaveName)
            // SwiftUI applies its own default size during initial layout, which
            // can land after this callback; re-apply the saved frame on the
            // next runloop tick so the restored frame wins.
            DispatchQueue.main.async { [weak window] in
                window?.setFrameUsingName(self.autosaveName)
            }
        }
    }
}

/// The frame-autosave wiring, factored out so it's unit-testable without a
/// SwiftUI hierarchy.
enum WindowFrameAutosave {
    /// Autosave name of the main sessions window. Doubles as that window's
    /// identity: the auxiliary picker scenes and Preferences share the same
    /// service graph, so window-scoped menu commands need a way to tell which
    /// window is in front.
    static let mainWindowName = "YggdrasilMainWindow"

    /// Begin autosaving `window`'s frame under `name` and apply any frame
    /// previously saved under it. `setFrameUsingName` is a no-op on first
    /// launch (nothing saved yet).
    @MainActor
    static func enable(on window: NSWindow, name: String) {
        window.setFrameAutosaveName(name)
        window.setFrameUsingName(name)
    }

    /// Whether `autosaveName` belongs to the main sessions window. Aux windows
    /// carry no autosave name, so anything else — including nil — is not it.
    static func isMainWindow(autosaveName: String?) -> Bool {
        autosaveName == mainWindowName
    }
}
