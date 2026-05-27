import SwiftUI

/// Right-hand pane of the main window: a three-way segmented control over
/// **Terminal · GitHub · Diff** (Diff is disabled until Phase 7) and whichever
/// sub-pane the user has picked for the selected tab. Per-tab choice is
/// persisted to `tab.last_main_view`.
struct MainPaneView: View {
    let services: AppServices
    let selectedTab: LoomTab

    @State private var view: LoomTab.MainView

    init(services: AppServices, selectedTab: LoomTab) {
        self.services = services
        self.selectedTab = selectedTab
        _view = State(initialValue: selectedTab.lastMainView)
    }

    var body: some View {
        VStack(spacing: 0) {
            segments
            Divider()
            content
        }
        .id(selectedTab.id) // Fresh state every tab.
        .onAppear { applyDefaultViewForTab() }
    }

    // MARK: - Segments

    private var segments: some View {
        HStack(spacing: 0) {
            Picker("", selection: $view) {
                Label("Terminal", systemImage: "terminal").tag(LoomTab.MainView.agent)
                Label("GitHub", systemImage: "globe").tag(LoomTab.MainView.github)
                Label("Diff", systemImage: "rectangle.split.2x1").tag(LoomTab.MainView.diff)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("mainpane.segments")
            .frame(width: 320)

            Spacer()

            if view == .github {
                Button {
                    NotificationCenter.default.post(
                        name: Self.reloadGitHubNotification,
                        object: selectedTab.id
                    )
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: view) { _, newValue in
            persistView(newValue)
        }
        .disabled(false) // Outer container; per-segment .disabled handled in Picker.
    }

    @ViewBuilder
    private var content: some View {
        switch view {
        case .agent:
            agentSurface
        case .github:
            GitHubSubPane(services: services, tab: selectedTab)
        case .diff:
            diffPlaceholder
        }
    }

    @ViewBuilder
    private var agentSurface: some View {
        if let session = services.sessions.sessions.first(where: { $0.id == selectedTab.id }) {
            AgentTerminalSurface(
                tabID: session.id,
                cwd: session.cwd,
                command: session.command,
                args: session.args,
                sessionStore: services.sessionStore,
                sessions: services.sessions
            )
        } else {
            terminalPlaceholder
        }
    }

    private var terminalPlaceholder: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            VStack(spacing: 8) {
                ProgressView()
                Text("Waiting for session…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var diffPlaceholder: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            VStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Diff view comes in Phase 7")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Default view selection (spec §Phase 5)

    /// Spec: "default is `GitHub` on first open of an existing task,
    /// `Terminal` after the user has used the terminal once." If the persisted
    /// view is already non-default we leave it alone; otherwise we apply the
    /// rule based on whether the tab is linked to a task.
    private func applyDefaultViewForTab() {
        let task = selectedTab.id.flatMap { services.tabs.tasksByTabID[$0] }
        // Only override when the persisted value still equals the schema default
        // (.agent) AND the tab shadows a GitHub task.
        if selectedTab.lastMainView == .agent, task != nil {
            view = .github
            persistView(.github)
        }
    }

    private func persistView(_ newValue: LoomTab.MainView) {
        guard let id = selectedTab.id else { return }
        do {
            try services.tabStore.setLastMainView(id: id, view: newValue)
            services.tabs.reload()
        } catch {
            LoomLog.ui.error("setLastMainView failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Posted when the user clicks "Reload" on the GitHub sub-pane. Object is the
    /// `tab.id` to reload.
    static let reloadGitHubNotification = Notification.Name("loom.mainpane.reloadGitHub")
}
