import SwiftUI

/// The sidebar. Renders the persistent tab list with selection driving the main
/// pane. Empty state nudges the user toward "Add tracked repo".
struct SidebarView: View {
    let services: AppServices
    let onSelect: (Int64) -> Void
    @State private var showingNewTabSheet = false

    private var tabsModel: TabsModel { services.tabs }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tabsModel.tabs.isEmpty {
                emptyState
            } else {
                tabList
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showingNewTabSheet) {
            NewTabSheet(services: services)
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
            ForEach(tabsModel.tabs, id: \.id) { tab in
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
            }
            .onMove { from, toOffset in
                tabsModel.move(fromOffsets: from, toOffset: toOffset)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
