import SwiftUI

// swiftlint:disable file_length
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
    /// 0.0 .. 1.0 — fraction of the available width given to the primary
    /// pane in a `.split` layout. Persisted per-tab so each session
    /// remembers its own divider position.
    @State private var dividerFraction: Double
    @Environment(\.colorScheme) private var scheme

    init(services: AppServices, selectedTab: YggdrasilTab) {
        self.services = services
        self.selectedTab = selectedTab
        _layout = State(initialValue: PaneLayout.load(for: selectedTab))
        _dividerFraction = State(initialValue: PaneLayout.loadDivider(for: selectedTab))
    }

    var body: some View {
        Group {
            switch layout {
            case let .solo(primary):
                paneStack(primary: primary, secondary: nil)
            case let .split(primary, secondary):
                paneStack(primary: primary, secondary: secondary)
            }
        }
        .id(selectedTab.id)
        .onAppear {
            ensureSessionForSelectedTab()
            autoResumeIfExited()
        }
        .onChange(of: layout) { _, newValue in
            newValue.persist(for: selectedTab)
            persistPrimary(newValue.primarySegment)
        }
        .onChange(of: dividerFraction) { _, newValue in
            PaneLayout.persistDivider(newValue, for: selectedTab)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func paneStack(
        primary: PaneSegment, secondary: PaneSegment?
    ) -> some View {
        if let secondary {
            DraggableHSplit(fraction: $dividerFraction) {
                pane(primary)
            } secondary: {
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
        case .diff:
            DiffSubPane(
                services: services,
                tab: selectedTab,
                // Only the foregrounded tab's diff pane runs an
                // FSEventStream. Background tabs' panes are mounted but
                // dormant — no watcher, no work.
                isActive: services.tabs.selectedID == selectedTab.id
            )
        }
    }

    // MARK: - Agent surface

    @ViewBuilder
    private var agentSurface: some View {
        if let session = services.sessions.sessions.first(where: { $0.id == selectedTab.id }) {
            VStack(spacing: 0) {
                AgentTerminalSurface(
                    tabID: session.id,
                    cwd: session.cwd,
                    command: session.command,
                    args: session.args,
                    sessionStore: services.sessionStore,
                    sessions: services.sessions,
                    isActive: services.tabs.selectedID == selectedTab.id
                )

                if services.sessions.exitedTabs[session.id] != nil {
                    TerminalExitBanner(scheme: scheme)
                }
            }
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

    private func autoResumeIfExited() {
        guard let tabID = selectedTab.id,
              services.sessions.exitedTabs[tabID] != nil
        else { return }
        SidebarActions.restartAgent(tabID: tabID, services: services)
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

/// One of six layouts: 3 solo + 3 split. Persisted per-tab in UserDefaults
/// under `yggdrasil.paneLayout.<tabID>`, with a fallback to the global
/// `yggdrasil.paneLayout` key (used as the seed when a tab is first
/// opened, so the user's overall preference still wins on first show).
enum PaneLayout: Hashable {
    case solo(PaneSegment)
    case split(PaneSegment, PaneSegment)

    var primarySegment: PaneSegment {
        switch self {
        case let .solo(seg): seg
        case let .split(first, _): first
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
        case let .split(primary, _): primary == .agent ? "agent" : primary == .github ? "github" : "diff"
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

    private static let globalKey = "yggdrasil.paneLayout"
    private static func perTabKey(_ tab: YggdrasilTab) -> String {
        "yggdrasil.paneLayout.\(tab.id.map(String.init) ?? "unknown")"
    }

    private static let globalDividerKey = "yggdrasil.paneDivider"
    private static func perTabDividerKey(_ tab: YggdrasilTab) -> String {
        "yggdrasil.paneDivider.\(tab.id.map(String.init) ?? "unknown")"
    }

    static let defaultDividerFraction: Double = 0.5

    /// Layout for `tab`: prefers a saved per-tab choice, falls back to the
    /// last globally-used layout, finally the agent+diff default.
    static func load(for tab: YggdrasilTab) -> PaneLayout {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: perTabKey(tab)),
           let parsed = PaneLayout(rawValue: raw) {
            return parsed
        }
        if let raw = defaults.string(forKey: globalKey),
           let parsed = PaneLayout(rawValue: raw) {
            return parsed
        }
        return .split(.agent, .diff)
    }

    /// Persist `self` as the layout for `tab`. Also writes the same value
    /// to the global key so a freshly-opened tab inherits the user's most
    /// recent layout choice.
    func persist(for tab: YggdrasilTab) {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.perTabKey(tab))
        defaults.set(rawValue, forKey: Self.globalKey)
    }

    /// Per-tab divider fraction (primary pane width / total width) for
    /// split layouts. 0.5 default seeds a 50/50 split when nothing is
    /// saved.
    static func loadDivider(for tab: YggdrasilTab) -> Double {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: perTabDividerKey(tab)) != nil {
            return defaults.double(forKey: perTabDividerKey(tab))
        }
        if defaults.object(forKey: globalDividerKey) != nil {
            return defaults.double(forKey: globalDividerKey)
        }
        return defaultDividerFraction
    }

    static func persistDivider(_ fraction: Double, for tab: YggdrasilTab) {
        let defaults = UserDefaults.standard
        defaults.set(fraction, forKey: perTabDividerKey(tab))
        defaults.set(fraction, forKey: globalDividerKey)
    }

    func with(primary: PaneSegment) -> PaneLayout {
        switch self {
        case .solo: .solo(primary)
        case let .split(_, secondary):
            secondary == primary ? .solo(primary) : .split(primary, secondary)
        }
    }

    func toggleSplit(with companion: PaneSegment) -> PaneLayout {
        switch self {
        case let .solo(current):
            current == companion ? .solo(current) : .split(current, companion)
        case let .split(primary, _):
            .split(primary, companion)
        }
    }

    var isSplit: Bool {
        if case .split = self { return true }
        return false
    }
}

// MARK: - DraggableHSplit

/// Two-pane horizontal splitter that exposes its divider position as a
/// `@Binding<Double>` so callers can persist it (per-tab, in our case).
///
/// SwiftUI's `HSplitView` doesn't expose its divider state — width is
/// negotiated entirely by the OS NSSplitView under the hood, and nothing
/// reaches Swift code. This view replaces it with a deterministic
/// fraction-of-width split + a drag handle on the divider.
///
/// Minimum widths: each pane is held at a floor of 200pt so the user
/// can't drag a pane closed accidentally. Clamping is also applied on
/// load so a previously-persisted out-of-range fraction lands inside
/// `[minPaneWidth/total, 1 - minPaneWidth/total]`.
struct DraggableHSplit<Primary: View, Secondary: View>: View {
    @Binding var fraction: Double
    let primary: () -> Primary
    let secondary: () -> Secondary

    /// `fraction` value at the start of the current drag. `DragGesture`
    /// reports a CUMULATIVE translation (distance from drag start, not
    /// per-event delta), so the new width has to be computed against
    /// this start value — adding translation to the live `primaryWidth`
    /// would create a feedback loop that visibly accelerates the drag.
    @State private var dragStartFraction: Double?

    private let minPaneWidth: CGFloat = 200
    private let dividerWidth: CGFloat = 1
    /// Wider invisible hit zone around the 1pt divider so the drag
    /// handle is comfortably grabbable.
    private let dividerHitZone: CGFloat = 8

    var body: some View {
        GeometryReader { geom in
            let total = geom.size.width
            let minFraction = total > 0 ? minPaneWidth / total : 0
            let maxFraction = 1 - minFraction
            let clamped = max(minFraction, min(maxFraction, fraction))
            let primaryWidth = (total - dividerWidth) * clamped
            HStack(spacing: 0) {
                primary()
                    .frame(width: primaryWidth)
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: dividerWidth)
                    .overlay(
                        Color.clear
                            .frame(width: dividerHitZone)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(coordinateSpace: .global)
                                    .onChanged { value in
                                        guard total > 0 else { return }
                                        let start = dragStartFraction ?? fraction
                                        if dragStartFraction == nil {
                                            dragStartFraction = start
                                        }
                                        let startWidth = (total - dividerWidth) * start
                                        let newWidth = startWidth + value.translation.width
                                        let newFraction = newWidth / (total - dividerWidth)
                                        fraction = max(minFraction, min(maxFraction, newFraction))
                                    }
                                    .onEnded { _ in
                                        dragStartFraction = nil
                                    }
                            )
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                secondary()
                    .frame(maxWidth: .infinity)
            }
        }
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
            case let .split(primary, secondary):
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
        .contextMenu {
            if target == .agent, let id = tab.id {
                Button("Resume Session") {
                    SidebarActions.restartAgent(tabID: id, services: services)
                }
                Button("New Shell") {
                    SidebarActions.openShell(tabID: id, services: services)
                }
            }
        }
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

// MARK: - TerminalExitBanner

struct TerminalExitBanner: View {
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("Session ended. Right-click the Claude tab to resume your session or open a shell.")
                .font(.system(size: 11))
        }
        .foregroundStyle(YggdrasilTheme.textDim(scheme))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YggdrasilTheme.bgPaneSoft(scheme))
        .overlay(
            Rectangle()
                .fill(YggdrasilTheme.border(scheme))
                .frame(height: 0.5),
            alignment: .top
        )
    }
}
