import SwiftUI

/// The sidebar. Renders the persistent tab list with selection driving the main
/// pane. Empty state nudges the user toward "Add tracked repo".
struct SidebarView: View {
    let tabsModel: TabsModel
    let onSelect: (Int64) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if tabsModel.tabs.isEmpty {
                emptyState
            } else {
                tabList
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var tabList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
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
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
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
