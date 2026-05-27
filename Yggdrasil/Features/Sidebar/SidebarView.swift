import SwiftUI

/// Sidebar — redesigned per `Yggdrasil.html`:
/// - Header: blue gradient Yggdrasil mark + workspace name + "N tabs · M active"
/// - Search field with ⌘K hint chip
/// - Filter pills (All / Active / PRs / Issues)
/// - "+" button → NewTabSheet (Phase 4) — to be replaced by AgentPicker in P9 T7
/// - Rich `TabRow` rows
struct SidebarView: View {
    let services: AppServices
    let onSelect: (Int64) -> Void
    @State private var showingNewTabSheet = false
    @State private var showingAssignedPicker = false
    @State private var rawSearchQuery: String = ""
    @State private var debouncedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var activeFilter: Filter = .all
    @Environment(\.colorScheme) private var scheme

    private var tabsModel: TabsModel { services.tabs }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case prs = "PRs"
        case issues = "Issues"
        var id: String { rawValue }
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
        .sheet(isPresented: $showingNewTabSheet) {
            NewTabSheet(services: services)
        }
        .sheet(isPresented: $showingAssignedPicker) {
            AssignedTaskPicker(services: services)
        }
        .onChange(of: rawSearchQuery) { _, newValue in
            scheduleDebouncedQueryUpdate(to: newValue)
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
            .buttonStyle(.plain)
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
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                showingAssignedPicker = true
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
            .buttonStyle(.plain)
            .keyboardShortcut("O", modifiers: [.command])
            .help("Open assigned issue or PR (⌘O)")
            .accessibilityIdentifier("sidebar.openassigned")
            Button {
                showingNewTabSheet = true
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
            .buttonStyle(.plain)
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
        List {
            ForEach(filteredTabs, id: \.id) { tab in
                // Row is a plain View (no Button wrapper) so SwiftUI's List
                // drag-to-reorder gesture isn't swallowed by a button's
                // pointer handling. Selection runs through .onTapGesture
                // instead.
                TabRow(
                    model: tabsModel.model(for: tab, status: services.tabStatus),
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
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .contextMenu {
                    contextMenu(for: tab)
                }
            }
            .onMove { from, toOffset in
                guard debouncedQuery.isEmpty, activeFilter == .all else { return }
                tabsModel.move(fromOffsets: from, toOffset: toOffset)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(YggdrasilTheme.bgPane(scheme))
    }

    @ViewBuilder
    private func contextMenu(for tab: YggdrasilTab) -> some View {
        Button("Open in Finder") { SidebarActions.openInFinder(path: tab.worktreePath) }
        Button("Open in Terminal.app") { SidebarActions.openInTerminal(path: tab.worktreePath) }
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
