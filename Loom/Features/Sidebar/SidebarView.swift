import SwiftUI

/// The sidebar. Renders the persistent tab list with selection driving the main
/// pane. Empty state nudges the user toward "Add tracked repo".
struct SidebarView: View {
    let services: AppServices
    let onSelect: (Int64) -> Void
    @State private var showingNewTabSheet = false
    @State private var rawSearchQuery: String = ""
    @State private var debouncedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>?

    private var tabsModel: TabsModel { services.tabs }

    private var filteredTabs: [Tab] {
        tabsModel.filtered(by: debouncedQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            if tabsModel.tabs.isEmpty {
                emptyState
            } else if filteredTabs.isEmpty {
                noMatchesState
            } else {
                tabList
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showingNewTabSheet) {
            NewTabSheet(services: services)
        }
        .onChange(of: rawSearchQuery) { _, newValue in
            scheduleDebouncedQueryUpdate(to: newValue)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search", text: $rawSearchQuery)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("sidebar.search")
            if !rawSearchQuery.isEmpty {
                Button {
                    rawSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    /// 150 ms debounce per spec §Phase 4 AC #4 ("Search filters live, no UI hang
    /// on 200 tab fixture"). Cancels any in-flight delay on each keystroke.
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

    private var header: some View {
        HStack(spacing: 6) {
            Text("Tabs")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Button {
                showingNewTabSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("T", modifiers: [.command])
            .help("New Tab (⌘T)")
            .accessibilityIdentifier("sidebar.plus")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tabList: some View {
        // List on macOS uses NSTableView, which gives us native drag-to-reorder
        // via .onMove for free. Larger chrome than a LazyVStack but appropriate
        // for the sidebar.
        List {
            ForEach(filteredTabs, id: \.id) { tab in
                Button {
                    if let id = tab.id {
                        tabsModel.select(id)
                        onSelect(id)
                    }
                } label: {
                    TabRow(
                        model: tabsModel.model(for: tab),
                        isSelected: tabsModel.selectedID == tab.id
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                .listRowSeparator(.hidden)
                .contextMenu {
                    contextMenu(for: tab)
                }
            }
            .onMove { from, toOffset in
                // Only allow reorder when the visible list is the full list —
                // moving filtered indices would corrupt the canonical positions.
                guard debouncedQuery.isEmpty else { return }
                tabsModel.move(fromOffsets: from, toOffset: toOffset)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func contextMenu(for tab: Tab) -> some View {
        Button("Open in Finder") {
            SidebarActions.openInFinder(path: tab.worktreePath)
        }
        Button("Open in Terminal.app") {
            SidebarActions.openInTerminal(path: tab.worktreePath)
        }
        Divider()
        Button("Remove…", role: .destructive) {
            if let id = tab.id {
                SidebarActions.removeTab(id: id, services: services)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No tabs yet")
                .font(.headline)
            Text("Use Debug → Add Tracked Repo… to start syncing, or Debug → + New Session… to spawn an ad-hoc tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity)
    }
}
