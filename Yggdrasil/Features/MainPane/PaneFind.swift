import AppKit
import SwiftUI

/// A pane that can run an in-place find. Cmd-F resolves the focused pane's
/// finder off the key window's first responder (see `nearestPaneFinder`), so
/// one find bar transparently drives the terminal, GitHub, or Diff pane —
/// whichever is focused.
@MainActor
protocol PaneFinder: AnyObject {
    /// Find `query`, selecting/scrolling to the next (or previous) match.
    func paneFind(_ query: String, forward: Bool)
    /// Drop any highlight/selection (find bar closed or query emptied).
    func paneClearFind()
}

extension NSResponder {
    /// Nearest `PaneFinder` walking up the responder chain (which, for views,
    /// threads through superviews) from `self`. Lets the focused WKWebView's
    /// internal content view resolve to its hosting `WebViewHost`, and the
    /// terminal view resolve to itself.
    @MainActor
    func nearestPaneFinder() -> PaneFinder? {
        var responder: NSResponder? = self
        while let current = responder {
            if let finder = current as? PaneFinder { return finder }
            responder = current.nextResponder
        }
        return nil
    }
}

enum FindCommand {
    /// Posted by the Edit ▸ Find menu item (Cmd-F); observed by the main pane.
    static let show = Notification.Name("yggdrasil.find.show")
}

/// Find-bar state for the main window. `finder` is resolved each time the bar
/// is shown, against whatever pane is focused.
@MainActor
@Observable
final class FindBarState {
    var isVisible = false
    var query = ""
    weak var finder: (any PaneFinder)?

    /// Resolve the focused pane and show the bar.
    func show() {
        finder = NSApp.keyWindow?.firstResponder?.nearestPaneFinder()
        isVisible = true
        if !query.isEmpty { finder?.paneFind(query, forward: true) }
    }

    func close() {
        finder?.paneClearFind()
        isVisible = false
    }

    func findNext() {
        if !query.isEmpty { finder?.paneFind(query, forward: true) }
    }

    func findPrevious() {
        if !query.isEmpty { finder?.paneFind(query, forward: false) }
    }
}

/// Compact find bar overlaid at the top-trailing of the main pane.
struct FindBar: View {
    @Bindable var state: FindBarState
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
            TextField("Find", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { state.findNext() }
                .onChange(of: state.query) { _, query in
                    if query.isEmpty { state.finder?.paneClearFind() } else { state.finder?.paneFind(
                        query,
                        forward: true
                    ) }
                }
                .accessibilityIdentifier("find.field")

            findButton("chevron.up", help: "Previous match") { state.findPrevious() }
            findButton("chevron.down", help: "Next match") { state.findNext() }
            findButton("xmark", help: "Close") { state.close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(YggdrasilTheme.bgElev(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(YggdrasilTheme.borderStrong(scheme), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: state.isVisible) { _, visible in if visible { focused = true } }
    }

    private func findButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(YggdrasilTheme.textDim(scheme))
        .frame(width: 20, height: 20)
        .help(help)
    }
}

/// Edit ▸ Find (Cmd-F). Posts `FindCommand.show`; the main pane resolves the
/// focused pane and reveals the find bar.
struct FindCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                NotificationCenter.default.post(name: FindCommand.show, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
