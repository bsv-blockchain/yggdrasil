import AppKit
import SwiftUI

@main
struct LoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Loom", id: "main") {
            RootView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            DebugMenu()
        }
    }
}

/// Top-level main window. Phase 3 replaces the placeholder with a row of session
/// tabs along the top and the active agent's terminal in the body. Phase 4 swaps
/// the row for the proper sidebar.
struct RootView: View {

    /// Pulled lazily so SwiftUI doesn't crash under XCTest where AppServices is nil.
    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    var body: some View {
        Group {
            if let services {
                SessionsView(services: services)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .accessibilityIdentifier("loom.root")
    }

    private var placeholder: some View {
        ZStack {
            Color.clear
            Text("Loom")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("loom.placeholder.title")
        }
    }
}

/// The "tabs strip + active agent terminal" UI for Phase 3.
struct SessionsView: View {
    let services: AppServices

    var body: some View {
        VStack(spacing: 0) {
            tabsStrip
            Divider()
            activeSession
        }
    }

    private var tabsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(services.sessions.sessions) { session in
                    Button {
                        services.sessions.selectedID = session.id
                    } label: {
                        Text(session.displayName)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                services.sessions.selectedID == session.id
                                    ? Color.accentColor.opacity(0.25)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(height: 38)
    }

    @ViewBuilder
    private var activeSession: some View {
        if services.sessions.sessions.isEmpty {
            ZStack {
                Color(NSColor.windowBackgroundColor)
                VStack(spacing: 12) {
                    Text("No sessions yet")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Use Debug → + New Session to start a coding agent.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            // All sessions live in the ZStack so their PTYs stay alive when
            // off-screen. Only the selected one is visible. Stable .id() per
            // session prevents SwiftUI from re-creating (and thereby tearing
            // down) the underlying LocalProcessTerminalView on selection
            // changes.
            ZStack {
                ForEach(services.sessions.sessions) { session in
                    AgentTerminalSurface(
                        tabID: session.id,
                        cwd: session.cwd,
                        command: session.command,
                        args: session.args,
                        sessionStore: services.sessionStore,
                        sessions: services.sessions
                    )
                    .id(session.id)
                    .opacity(services.sessions.selectedID == session.id ? 1 : 0)
                    .allowsHitTesting(services.sessions.selectedID == session.id)
                }
            }
        }
    }
}
