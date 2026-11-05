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
        .background(WindowFrameAutosaver(autosaveName: WindowFrameAutosave.mainWindowName))
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
    @AppStorage(SidebarWidth.defaultsKey) private var sidebarWidth = SidebarWidth.standard
    /// Width when the current drag began: the gesture reports the distance
    /// from there, so adding it to the live width would compound.
    @State private var dragStartWidth: Double?
    /// The width while dragging, saved to `sidebarWidth` when the drag ends
    /// rather than on every movement.
    @State private var draggedWidth: Double?

    var body: some View {
        VStack(spacing: 0) {
            WindowChromeBar(services: services)
            GeometryReader { geometry in
                let width = SidebarWidth.clamped(draggedWidth ?? sidebarWidth, windowWidth: geometry.size.width)
                HStack(spacing: 0) {
                    SidebarView(services: services) { _ in
                        services.sessions.selectedID = services.tabs.selectedID
                    }
                    .frame(width: width)
                    sidebarDivider(width: width, windowWidth: geometry.size.width)
                        // Above the main pane, which would otherwise take
                        // the right half of the grab zone.
                        .zIndex(1)
                    mainPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(YggdrasilTheme.bg(scheme))
        .onAppear { services.sessions.hasMainWindow = true }
        .onDisappear { services.sessions.hasMainWindow = false }
    }

    /// The sidebar's edge: a hairline with a wider grab zone, dragged like
    /// the panes' divider.
    private func sidebarDivider(width: Double, windowWidth: Double) -> some View {
        Rectangle()
            .fill(YggdrasilTheme.border(scheme))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? width
                                if dragStartWidth == nil { dragStartWidth = start }
                                draggedWidth = SidebarWidth.clamped(
                                    start + value.translation.width, windowWidth: windowWidth
                                )
                            }
                            .onEnded { _ in
                                if let draggedWidth { sidebarWidth = draggedWidth }
                                draggedWidth = nil
                                dragStartWidth = nil
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            )
    }

    @ViewBuilder
    private var mainPane: some View {
        let manager = services.tabs.managerTab
        let managerOpened = manager.map { services.sessions.isOpened(tabID: $0.id) } ?? false
        if services.tabs.tabs.isEmpty, !managerOpened {
            emptyMainPane
        } else {
            // Stack one MainPaneView per *opened* tab and toggle visibility via
            // opacity. An opened tab keeps its agent PTY, GitHub WebView and
            // diff view mounted across selection, so switching back is instant.
            // Tabs not opened this run aren't mounted at all: mounting every
            // tab started an agent and a WebKit process per tab at launch —
            // 44 idle agents (~11 GB) and 37 WebKit processes on a real setup.
            // Once opened, the Yggdrasil session stays mounted too, also when
            // the last tab closes: unmounting it would end its claude.
            ZStack {
                ForEach(services.tabs.tabs.filter { services.sessions.isOpened(tabID: $0.id) }, id: \.id) { tab in
                    MainPaneView(services: services, selectedTab: tab)
                        .opacity(tab.id == services.tabs.selectedID ? 1 : 0)
                        .allowsHitTesting(tab.id == services.tabs.selectedID)
                }
                if let manager, managerOpened {
                    ManagerPaneView(services: services, tab: manager)
                        .opacity(manager.id == services.tabs.selectedID ? 1 : 0)
                        .allowsHitTesting(manager.id == services.tabs.selectedID)
                }
                if services.tabs.selectedID == nil {
                    if services.tabs.tabs.isEmpty { emptyMainPane } else { selectedTabHasNoSession }
                }
            }
            .onChange(of: services.tabs.selectedID, initial: true) { _, id in
                services.sessions.markOpened(tabID: id)
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
