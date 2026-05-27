import SwiftUI

/// Phase 5 placeholder for the GitHub web view. Task 3 in Phase 5 replaces
/// this with the real WKWebView; for now it shows a clear "GitHub view will
/// load here" message so the segmented control isn't blank.
struct GitHubSubPane: View {
    let services: AppServices
    let tab: LoomTab

    var body: some View {
        if let url = githubURL {
            GitHubWebView(services: services, tab: tab, url: url)
        } else {
            ZStack {
                Color(NSColor.windowBackgroundColor)
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No GitHub page for this tab")
                        .font(.headline)
                    Text("Ad-hoc tabs aren't linked to a GitHub issue or PR.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var githubURL: URL? {
        guard let id = tab.id,
              let task = services.tabs.tasksByTabID[id]
        else { return nil }
        return URL(string: task.githubURL)
    }
}
