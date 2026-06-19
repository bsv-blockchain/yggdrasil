import SwiftUI

// swiftlint:disable type_body_length
/// Sidebar — redesigned per `Yggdrasil.html`:
/// - Header: blue gradient Yggdrasil mark + workspace name + "N tabs · M active"
/// - Search field with ⌘K hint chip
/// - Filter pills (All / Active / PRs / Issues)
/// - "+" button → NewTabSheet (Phase 4) — to be replaced by AgentPicker in P9 T7
/// - Rich `TabRow` rows
struct SidebarView: View {
    let services: AppServices
    let onSelect: (Int64) -> Void
    @Environment(\.openWindow) private var openWindow
    /// Tab ID of the row currently hovered during a drag, used to render
    /// the insertion line so the user knows where the dropped tab will land.
    @State private var dropTargetTabID: Int64?
    @State private var rawSearchQuery: String = ""
    @State private var debouncedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var activeFilter: Filter = .all
    @State private var groupByRepo: Bool = false
    @Environment(\.colorScheme) private var scheme

    private var tabsModel: TabsModel {
        services.tabs
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case prs = "PRs"
        case issues = "Issues"
        var id: String {
            rawValue
        }
    }

    private var filteredTabs: [YggdrasilTab] {
        let bySearch = tabsModel.filtered(by: debouncedQuery)
        switch activeFilter {
        case .all: return bySearch
        case .active:
            return bySearch.filter {
                guard let id = $0.id else { return false }
                let icon = services.tabStatus.status(forTabID: id).icon
                return icon == .running || icon == .awaitingInput
            }
        case .prs:
            return bySearch.filter { tab in
                guard let id = tab.id, let task = tabsModel.tasksByTabID[id] else { return false }
                return task.type == .pullRequest
            }
        case .issues:
            return bySearch.filter { tab in
                guard let id = tab.id, let task = tabsModel.tasksByTabID[id] else { return false }
                return task.type == .issue
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            searchField
            filterPills
            Divider()
                .background(YggdrasilTheme.divider(scheme))
            if tabsModel.tabs.isEmpty {
                emptyState
            } else if filteredTabs.isEmpty {
                noMatchesState
            } else {
                tabList
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        .background(YggdrasilTheme.bgPane(scheme))
        .onChange(of: rawSearchQuery) { _, newValue in
            scheduleDebouncedQueryUpdate(to: newValue)
        }
        .onAppear {
            groupByRepo = AppearancePrefsPane.readGroupByRepo(services: services)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidebarGroupingChanged)) { _ in
            groupByRepo = AppearancePrefsPane.readGroupByRepo(services: services)
        }
    }

    // MARK: - Header

    private var workspaceHeader: some View {
        HStack(spacing: 8) {
            YggdrasilMark()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspaceTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(YggdrasilTheme.text(scheme))
                    .lineLimit(1)
                Text(workspaceSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
            }
            Spacer()
            Button {
                // Ellipsis menu — placeholder for now.
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.yggdrasilIcon)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var workspaceTitle: String {
        // Heuristic: most-common owner across tracked repos, else "Workspace".
        let owners = tabsModel.tabs.compactMap { tab -> String? in
            guard let id = tab.id, let task = tabsModel.tasksByTabID[id] else { return nil }
            guard let repo = try? services.database.queue.read({ db in
                try Repo.fetchOne(db, key: task.repoID)
            }) else { return nil }
            return repo.owner
        }
        let counts = Dictionary(grouping: owners, by: { $0 }).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key ?? "Workspace"
    }

    private var workspaceSubtitle: String {
        let total = tabsModel.tabs.count
        let active = tabsModel.tabs.filter { tab in
            guard let id = tab.id else { return false }
            let icon = services.tabStatus.status(forTabID: id).icon
            return icon == .running || icon == .awaitingInput
        }.count
        if total == 0 { return "no tabs" }
        return "\(total) tab\(total == 1 ? "" : "s") · \(active) active"
    }

    // MARK: - Search + filters

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
            TextField("Search tabs, branches, repos", text: $rawSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(YggdrasilTheme.text(scheme))
                .accessibilityIdentifier("sidebar.search")
            Text("⌘K")
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(YggdrasilTheme.chipBg(scheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(YggdrasilTheme.chipBd(scheme), lineWidth: 0.5)
                        )
                )
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(YggdrasilTheme.bgPaneSoft(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
    }

    private var filterPills: some View {
        HStack(spacing: 4) {
            ForEach(Filter.allCases) { filter in
                Button {
                    activeFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: activeFilter == filter ? .semibold : .medium))
                        .foregroundStyle(
                            activeFilter == filter ? YggdrasilTheme.text(scheme) : YggdrasilTheme.textMute(scheme)
                        )
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(activeFilter == filter
                                    ? YggdrasilTheme.bgActive(scheme)
                                    : Color.clear)
                        )
                }
                .buttonStyle(.yggdrasilIcon)
            }
            Spacer()
            Button {
                openWindow(id: AuxiliaryWindowID.issueDetails)
            } label: {
                Image(systemName: "tablecells")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.yggdrasilIcon)
            .keyboardShortcut("I", modifiers: [.command, .shift])
            .help("My issues — table view (⌘⇧I)")
            .accessibilityIdentifier("sidebar.issuedetails")
            Button {
                openWindow(id: AuxiliaryWindowID.assignedPicker)
            } label: {
                Image(systemName: "tray.full")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.yggdrasilIcon)
            .keyboardShortcut("O", modifiers: [.command])
            .help("Open assigned issue or PR (⌘O)")
            .accessibilityIdentifier("sidebar.openassigned")
            Button {
                openWindow(id: AuxiliaryWindowID.newTab)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.yggdrasilIcon)
            .keyboardShortcut("T", modifiers: [.command])
            .help("New session (⌘T)")
            .accessibilityIdentifier("sidebar.plus")
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 9)
    }

    // MARK: - Tab list

    private var tabList: some View {
        // .onMove on macOS SwiftUI Lists never reliably fires without an
        // explicit edit mode, so we use the modern drag-and-drop primitives
        // (.draggable + .dropDestination) instead. Each row is the drag
        // payload AND a drop target; dropping computes the new index from
        // the source/destination tab IDs and calls TabsModel.move(...) which
        // persists via TabStore.reorder.
        let reorderEnabled = debouncedQuery.isEmpty && activeFilter == .all

        return ScrollView {
            LazyVStack(spacing: 0) {
                if groupByRepo {
                    let groups = SidebarGrouping.groupByRepo(
                        tabs: filteredTabs,
                        repoByTabID: tabsModel.repoByTabID
                    )
                    ForEach(groups) { group in
                        groupHeader(title: group.title)
                        ForEach(group.tabs, id: \.id) { tab in
                            rowView(for: tab, reorderEnabled: reorderEnabled)
                        }
                    }
                } else {
                    ForEach(filteredTabs, id: \.id) { tab in
                        rowView(for: tab, reorderEnabled: reorderEnabled)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .background(YggdrasilTheme.bgPane(scheme))
    }

    private func groupHeader(title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(YggdrasilTheme.textMute(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func rowView(for tab: YggdrasilTab, reorderEnabled: Bool) -> some View {
        let row = TabRow(
            model: tabsModel.model(for: tab, status: services.tabStatus, grouped: groupByRepo),
            agent: tabsModel.agentIdentity(for: tab),
            isSelected: tabsModel.selectedID == tab.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = tab.id {
                tabsModel.select(id)
                onSelect(id)
            }
        }
        .contextMenu {
            contextMenu(for: tab)
        }

        let decorated = row
            .overlay(alignment: .top) {
                if dropTargetTabID == tab.id {
                    Rectangle()
                        .fill(YggdrasilTheme.accent)
                        .frame(height: 2)
                        .offset(y: -1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 1)

        if reorderEnabled, let id = tab.id {
            decorated
                .draggable(String(id)) {
                    // Custom drag preview: same row content on an opaque
                    // tinted background so it reads as a card under the
                    // cursor instead of the default transparent silhouette.
                    TabRow(
                        model: tabsModel.model(for: tab, status: services.tabStatus, grouped: groupByRepo),
                        agent: tabsModel.agentIdentity(for: tab),
                        isSelected: true
                    )
                    .frame(width: 280)
                    .padding(6)
                    .background(YggdrasilTheme.bgElev(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(YggdrasilTheme.borderStrong(scheme), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                }
                .dropDestination(for: String.self) { items, _ in
                    let result = handleDrop(items: items, ontoTabID: id)
                    dropTargetTabID = nil
                    return result
                } isTargeted: { targeted in
                    if targeted {
                        dropTargetTabID = id
                    } else if dropTargetTabID == id {
                        dropTargetTabID = nil
                    }
                }
        } else {
            decorated
        }
    }

    /// SwiftUI's `.dropDestination` payload is the dragged tab id (as String).
    /// Compute the source + target indices in the filtered list and ask
    /// `TabsModel.move(fromOffsets:toOffset:)` to reorder; persistence runs
    /// through `TabStore.reorder(ids:)`.
    private func handleDrop(items: [String], ontoTabID: Int64) -> Bool {
        guard let sourceIDString = items.first,
              let sourceID = Int64(sourceIDString),
              sourceID != ontoTabID else { return false }
        // Reject cross-group drops when grouping by repo is enabled.
        guard SidebarGrouping.dropAllowed(
            sourceTabID: sourceID, targetTabID: ontoTabID,
            repoByTabID: tabsModel.repoByTabID,
            grouped: groupByRepo
        ) else { return false }
        let tabs = tabsModel.tabs
        guard let from = tabs.firstIndex(where: { $0.id == sourceID }),
              let onto = tabs.firstIndex(where: { $0.id == ontoTabID }) else { return false }
        // .move semantics: toOffset is the index BEFORE which the source goes.
        // Drop-on-row-N means "place me just before row N" when moving up,
        // and "place me just after row N" when moving down. Match the user's
        // expectation by computing toOffset = onto when sourceIndex > onto,
        // else onto + 1.
        let toOffset = from > onto ? onto : onto + 1
        tabsModel.move(fromOffsets: IndexSet(integer: from), toOffset: toOffset)
        return true
    }

    @ViewBuilder
    private func contextMenu(for tab: YggdrasilTab) -> some View {
        Button("Resume Session") {
            if let id = tab.id { SidebarActions.restartAgent(tabID: id, services: services) }
        }
        Button("New Shell") {
            if let id = tab.id { SidebarActions.openShell(tabID: id, services: services) }
        }
        Divider()
        Button("Open in Finder") { SidebarActions.openInFinder(path: tab.worktreePath) }
        Button("Open in Terminal.app") { SidebarActions.openInTerminal(path: tab.worktreePath) }
        Divider()
        if let id = tab.id {
            if tabsModel.tasksByTabID[id] == nil {
                Button("Link PR…") {
                    SidebarActions.linkPR(tab: tab, services: services)
                }
            } else {
                Button("Unlink PR") {
                    SidebarActions.unlinkPR(id: id, services: services)
                }
            }
        }
        Divider()
        Button("Remove…", role: .destructive) {
            if let id = tab.id { SidebarActions.removeTab(id: id, services: services) }
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(YggdrasilTheme.textFaint(scheme))
            Text("No tabs yet")
                .font(.headline)
                .foregroundStyle(YggdrasilTheme.text(scheme))
            Text("Use Preferences → Repos to add a tracked repo, or click + above to spawn an ad-hoc tab.")
                .font(.callout)
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(YggdrasilTheme.textFaint(scheme))
            Text("No matches")
                .font(.callout)
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func scheduleDebouncedQueryUpdate(to value: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedQuery = value
            }
        }
    }
}

// swiftlint:enable type_body_length

/// Yggdrasil mark — the product logo (a tree silhouette). Backed by the
/// `YggdrasilMark` imageset in Assets.xcassets, generated from `Assets/logo.jpg`.
struct YggdrasilMark: View {
    var body: some View {
        Image("YggdrasilMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Yggdrasil")
    }
}
