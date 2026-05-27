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
            TabCommands()
            DebugMenu()
            DiagnosticsCommands()
        }

        PreferencesScene()
    }
}

/// Top-level main window. Phase 4 introduces the proper sidebar; the main pane
/// hosts whichever session matches the selected sidebar tab (or an empty state
/// when no session has been spawned for that tab yet).
struct RootView: View {

    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    @State private var showingOnboarding = false

    var body: some View {
        Group {
            if let services {
                SidebarSessionsLayout(services: services)
                    .sheet(isPresented: $showingOnboarding) {
                        OnboardingSheet(services: services)
                    }
                    .task {
                        showingOnboarding = OnboardingSheet.shouldShow(services: services)
                    }
            } else {
                placeholder
            }
        }
        .frame(minWidth: 900, minHeight: 600)
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

/// Window chrome + HSplit between the sidebar and the main pane. Selection in
/// the sidebar drives which session is hosted on the right. Layout matches
/// `Loom.html` — chrome strip on top, sidebar (resizable) + main pane below.
struct SidebarSessionsLayout: View {
    let services: AppServices
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            WindowChromeBar(services: services)
            HStack(spacing: 0) {
                SidebarView(services: services) { _ in
                    services.sessions.selectedID = services.tabs.selectedID
                }
                Rectangle()
                    .fill(LoomTheme.divider(scheme))
                    .frame(width: 0.5)
                mainPane
            }
        }
        .background(LoomTheme.bg(scheme))
    }

    @ViewBuilder
    private var mainPane: some View {
        if let selectedID = services.tabs.selectedID,
           let selectedTab = services.tabs.tabs.first(where: { $0.id == selectedID }) {
            MainPaneView(services: services, selectedTab: selectedTab)
        } else if services.tabs.tabs.isEmpty {
            emptyMainPane
        } else {
            selectedTabHasNoSession
        }
    }

    private var emptyMainPane: some View {
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
    }

    private var selectedTabHasNoSession: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            VStack(spacing: 8) {
                Image(systemName: "play.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No live session for this tab")
                    .font(.headline)
                Text("Use Debug → + New Session… or the toolbar “+” (coming) to start one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
