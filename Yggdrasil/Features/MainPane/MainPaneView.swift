import SwiftUI

/// Right-hand pane of the main window. Per `Yggdrasil.html` the layout is a
/// **preset** chosen in Tweaks: Agent+Diff (default), Agent+GitHub, Diff+GitHub,
/// or any of the three solo. Each visible pane gets its own segmented header
/// (Agent name dynamically · GitHub · Diff) with a Split / Close button. The
/// per-tab "primary segment" still persists into `tab.last_main_view` so a
/// returning user sees what they had last.
struct MainPaneView: View {
    let services: AppServices
    let selectedTab: YggdrasilTab

    @State private var layout: PaneLayout
    @Environment(\.colorScheme) private var scheme

    init(services: AppServices, selectedTab: YggdrasilTab) {
        self.services = services
        self.selectedTab = selectedTab
        _layout = State(initialValue: PaneLayout.load(for: selectedTab))
    }

    var body: some View {
        Group {
            switch layout {
            case .solo(let primary):
                paneStack(primary: primary, secondary: nil)
            case .split(let primary, let secondary):
                paneStack(primary: primary, secondary: secondary)
            }
        }
        .id(selectedTab.id)
        .onAppear { ensureSessionForSelectedTab() }
        .onChange(of: layout) { _, newValue in
            newValue.persist(for: selectedTab)
            persistPrimary(newValue.primarySegment)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func paneStack(
        primary: PaneSegment, secondary: PaneSegment?
    ) -> some View {
        if let secondary {
            HSplitView {
                pane(primary)
                pane(secondary)
            }
        } else {
            pane(primary)
        }
    }

    private func pane(_ segment: PaneSegment) -> some View {
        VStack(spacing: 0) {
            PaneHeader(
                segment: segment,
                services: services,
                tab: selectedTab,
                layout: $layout
            )
            Rectangle()
                .fill(YggdrasilTheme.border(scheme))
                .frame(height: 0.5)
            content(for: segment)
        }
        .background(YggdrasilTheme.bgPane(scheme))
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for segment: PaneSegment) -> some View {
        switch segment {
        case .agent: agentSurface
        case .github: GitHubSubPane(services: services, tab: selectedTab)
        case .diff: DiffSubPane(services: services, tab: selectedTab)
        }
    }

    // MARK: - Agent surface

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
            ZStack {
                YggdrasilTheme.bgPane(scheme)
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for session…")
                        .font(.callout)
                        .foregroundStyle(YggdrasilTheme.textDim(scheme))
                }
            }
        }
    }

    // MARK: - Auto-spawn on selection (preserved from Phase 5)

    private func ensureSessionForSelectedTab() {
        guard let tabID = selectedTab.id else { return }
        if services.sessions.sessions.contains(where: { $0.id == tabID }) { return }
        guard let agentID = selectedTab.codingAgentID else {
            YggdrasilLog.ui.info("Tab \(tabID, privacy: .public) has no coding_agent_id; cannot auto-spawn")
            return
        }
        do {
            guard let agent = try services.agentStore.get(id: agentID) else {
                YggdrasilLog.ui.warning(
                    "Tab \(tabID, privacy: .public) references missing agent id=\(agentID, privacy: .public)"
                )
                return
            }
            services.sessions.add(
                OpenSession(
                    id: tabID,
                    displayName: "\(agent.name) · \(selectedTab.branchName)",
                    cwd: selectedTab.worktreePath,
                    command: agent.command,
                    args: agent.args
                )
            )
            services.sessions.selectedID = tabID
        } catch {
            YggdrasilLog.ui.error(
                "Auto-spawn failed for tab \(tabID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func persistPrimary(_ segment: PaneSegment) {
        guard let id = selectedTab.id else { return }
        try? services.tabStore.setLastMainView(id: id, view: segment.tabMainView)
    }

    /// Posted when the user clicks "Reload" on the GitHub pane.
    static let reloadGitHubNotification = Notification.Name("yggdrasil.mainpane.reloadGitHub")
}

// MARK: - PaneSegment + PaneLayout

/// One renderable surface in a pane. Distinct from `YggdrasilTab.MainView` because
/// `.agent` here also captures the dynamically-resolved agent name.
enum PaneSegment: Hashable {
    case agent
    case github
    case diff

    var tabMainView: YggdrasilTab.MainView {
        switch self {
        case .agent: .agent
        case .github: .github
        case .diff: .diff
        }
    }

    static func from(_ view: YggdrasilTab.MainView) -> PaneSegment {
        switch view {
        case .agent: .agent
        case .github: .github
        case .diff: .diff
        }
    }
}

/// One of six layouts: 3 solo + 3 split. Persisted per-app in `setting.layout`.
enum PaneLayout: Hashable {
    case solo(PaneSegment)
    case split(PaneSegment, PaneSegment)

    var primarySegment: PaneSegment {
        switch self {
        case .solo(let seg): seg
        case .split(let first, _): first
        }
    }

    var rawValue: String {
        switch self {
        case .solo(.agent): "agent"
        case .solo(.github): "github"
        case .solo(.diff): "diff"
        case .split(.agent, .diff): "agent+diff"
        case .split(.agent, .github): "agent+github"
        case .split(.diff, .github): "diff+github"
        // any other split is collapsed to its primary
        case .split(let primary, _): primary == .agent ? "agent" : primary == .github ? "github" : "diff"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "agent": self = .solo(.agent)
        case "github": self = .solo(.github)
        case "diff": self = .solo(.diff)
        case "agent+diff": self = .split(.agent, .diff)
        case "agent+github": self = .split(.agent, .github)
        case "diff+github": self = .split(.diff, .github)
        default: return nil
        }
    }

    /// Default per the design's `YGGDRASIL_DEFAULTS` ("terminal+diff"), with the
    /// per-tab `last_main_view` as a fallback when no global override is set.
    static func load(for tab: YggdrasilTab) -> PaneLayout {
        if let raw = UserDefaults.standard.string(forKey: "yggdrasil.paneLayout"),
           let parsed = PaneLayout(rawValue: raw) {
            return parsed
        }
        return .split(.agent, .diff)
    }

    func persist(for tab: YggdrasilTab) {
        UserDefaults.standard.set(rawValue, forKey: "yggdrasil.paneLayout")
    }

    func with(primary: PaneSegment) -> PaneLayout {
        switch self {
        case .solo: return .solo(primary)
        case .split(_, let secondary):
            return secondary == primary ? .solo(primary) : .split(primary, secondary)
        }
    }

    func toggleSplit(with companion: PaneSegment) -> PaneLayout {
        switch self {
        case .solo(let current):
            return current == companion ? .solo(current) : .split(current, companion)
        case .split(let primary, _):
            return .split(primary, companion)
        }
    }

    var isSplit: Bool {
        if case .split = self { return true }
        return false
    }
}

// MARK: - PaneHeader

/// One pane's header: segmented control + reload (GitHub) + Split menu + Close.
struct PaneHeader: View {
    let segment: PaneSegment
    let services: AppServices
    let tab: YggdrasilTab
    @Binding var layout: PaneLayout
    @Environment(\.colorScheme) private var scheme

    private var agentIdentity: AgentIdentity {
        services.tabs.agentIdentity(for: tab)
    }

    var body: some View {
        HStack(spacing: 10) {
            segmentedControl
            Spacer()
            if segment == .github {
                chromeButton(systemImage: "arrow.clockwise", help: "Reload") {
                    NotificationCenter.default.post(
                        name: MainPaneView.reloadGitHubNotification,
                        object: tab.id
                    )
                }
            }
            Menu {
                Button("Solo") { layout = .solo(segment) }
                Divider()
                Text("Add pane")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(splitCompanions, id: \.self) { companion in
                    Button(label(for: companion)) {
                        layout = .split(segment, companion)
                    }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 11))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Split / layout")

            if layout.isSplit {
                chromeButton(systemImage: "xmark", help: "Close pane") {
                    layout = .solo(layout.primarySegment == segment
                        ? (segment == .agent ? .diff : .agent)
                        : layout.primarySegment)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(YggdrasilTheme.bgWindow(scheme))
    }

    private var segmentedControl: some View {
        HStack(spacing: 2) {
            segmentButton(.agent, label: agentIdentity.label)
            segmentButton(.github, label: "GitHub")
            segmentButton(.diff, label: "Diff")
        }
        .padding(2)
        .background(YggdrasilTheme.bgPaneSoft(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func segmentButton(_ target: PaneSegment, label: String) -> some View {
        let isSelected = target == segment
        Button {
            // Replace the current segment in-place. If the other pane already
            // shows `target`, swap them instead of duplicating.
            switch layout {
            case .solo:
                layout = .solo(target)
            case .split(let primary, let secondary):
                if segment == primary {
                    layout = secondary == target ? .solo(target) : .split(target, secondary)
                } else {
                    layout = primary == target ? .solo(target) : .split(primary, target)
                }
            }
        } label: {
            HStack(spacing: 6) {
                segmentIcon(target)
                Text(label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .foregroundStyle(
                isSelected
                    ? (target == .agent ? agentIdentity.color : YggdrasilTheme.text(scheme))
                    : YggdrasilTheme.textMute(scheme)
            )
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? YggdrasilTheme.bgElev(scheme) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func segmentIcon(_ target: PaneSegment) -> some View {
        switch target {
        case .agent:
            AgentMark(agent: agentIdentity, size: 11)
        case .github:
            Image(systemName: "globe").font(.system(size: 10))
        case .diff:
            Image(systemName: "rectangle.split.2x1").font(.system(size: 10))
        }
    }

    private var splitCompanions: [PaneSegment] {
        [PaneSegment.agent, .github, .diff].filter { $0 != segment }
    }

    private func label(for segment: PaneSegment) -> String {
        switch segment {
        case .agent: agentIdentity.label
        case .github: "GitHub"
        case .diff: "Diff"
        }
    }

    private func chromeButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
