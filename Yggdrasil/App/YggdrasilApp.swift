import AppKit
import SwiftUI

@main
struct YggdrasilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup("Yggdrasil", id: "main") {
            RootView(appDelegate: appDelegate, updater: updater)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            TabCommands(appDelegate: appDelegate)
            DiagnosticsCommands()
            FindCommands()
            UpdaterCommands(updater: updater)
            // "Coding" menu lives in AppKit (CodingMenuController) for
            // historical reasons (SwiftUI's CommandMenu used to stop
            // dispatching once MenuBarExtra was in the Scene graph). The
            // menu bar status item is gone now but the AppKit detour
            // stays to avoid churn.
        }

        PreferencesScene(appDelegate: appDelegate)

        // Auxiliary tool windows for the four user-triggered pickers. Real
        // Window scenes (not .sheet) so the user can move + resize each one.
        NewTabWindowScene(appDelegate: appDelegate)
        AssignedTaskWindowScene(appDelegate: appDelegate)
        ReviewPickerWindowScene(appDelegate: appDelegate)
        IssueDetailsWindowScene(appDelegate: appDelegate)
    }
}

/// Top-level main window. Phase 4 introduces the proper sidebar; the main pane
/// hosts whichever session matches the selected sidebar tab (or an empty state
/// when no session has been spawned for that tab yet).
struct RootView: View {
    @ObservedObject var appDelegate: AppDelegate
    let updater: UpdaterController

    @State private var showingOnboarding = false

    var body: some View {
        Group {
            if let services = appDelegate.services {
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
        .accessibilityIdentifier("yggdrasil.root")
        .background(WindowFrameAutosaver(autosaveName: "YggdrasilMainWindow"))
        .task {
            // Start Sparkle's scheduled update checks once, in production only.
            // The test bundle is hosted in the real app, so this view runs
            // under XCTest too — starting the updater there would schedule a
            // network check and the first-run permission prompt.
            if !AppDelegate.isRunningTests { updater.start() }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.clear
            Text("Yggdrasil")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("yggdrasil.placeholder.title")
        }
    }
}

/// Window chrome + HSplit between the sidebar and the main pane. Selection in
/// the sidebar drives which session is hosted on the right. Layout matches
/// `Yggdrasil.html` — chrome strip on top, sidebar (resizable) + main pane below.
struct SidebarSessionsLayout: View {
    let services: AppServices
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            WindowChromeBar(services: services)
            HSplitView {
                SidebarView(services: services) { _ in
                    services.sessions.selectedID = services.tabs.selectedID
                }
                mainPane
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(YggdrasilTheme.bg(scheme))
        .background {
            // Keep ⌥↑ / ⌥↓ tab navigation alive now that the visible View-menu
            // items carry ⌘⇧[ / ⌘⇧]. Zero-size and hidden, but present in the
            // responder chain while the window is open; same action as the menu
            // commands (SidebarActions.selectTab).
            Button("") { SidebarActions.selectTab(by: -1, services: services) }
                .keyboardShortcut(.upArrow, modifiers: [.option])
                .hidden()
            Button("") { SidebarActions.selectTab(by: 1, services: services) }
                .keyboardShortcut(.downArrow, modifiers: [.option])
                .hidden()
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        if services.tabs.tabs.isEmpty {
            emptyMainPane
        } else {
            // Stack one MainPaneView per tab and toggle visibility via opacity.
            // This keeps every tab's agent PTY, GitHub WebView, and diff view
            // mounted across selection, so switching tabs is instant — nothing
            // is torn down + respawned. Costs more RAM (one terminal +
            // WebKit per tab) but per user direction that's the trade.
            ZStack {
                ForEach(services.tabs.tabs, id: \.id) { tab in
                    MainPaneView(services: services, selectedTab: tab)
                        .opacity(tab.id == services.tabs.selectedID ? 1 : 0)
                        .allowsHitTesting(tab.id == services.tabs.selectedID)
                }
                if services.tabs.selectedID == nil {
                    selectedTabHasNoSession
                }
            }
        }
    }

    private var emptyMainPane: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            VStack(spacing: 12) {
                Text("No sessions yet")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Click the “+” in the sidebar (or Coding → New Session… ⌘N) to start a coding agent.")
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
                Text("Click the “+” in the sidebar or Coding → New Session… (⌘N).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
