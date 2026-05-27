import SwiftUI

/// Phase 5 placeholder for the GitHub web view. Task 3 in Phase 5 replaces
/// this with the real WKWebView; for now it shows a clear "GitHub view will
/// load here" message so the segmented control isn't blank.
struct GitHubSubPane: View {
    let services: AppServices
    let tab: YggdrasilTab

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
        guard let id = tab.id else { return nil }
        // Prefer the synced task's canonical githubURL when available.
        if let task = services.tabs.tasksByTabID[id], let url = URL(string: task.githubURL) {
            return url
        }
        // Fallback: synthesize a URL from the owning repo + the PR/issue
        // number parsed out of the branch name. Lets the user navigate to
        // their PR before the next sync tick imports it.
        guard let repo = services.tabs.repoByTabID[id],
              let number = NewTabSheet.parsePRNumber(tab.branchName)
        else { return nil }
        let path = tab.branchName.lowercased().hasPrefix("issue") ? "issues" : "pull"
        return URL(string: "https://github.com/\(repo.owner)/\(repo.name)/\(path)/\(number)")
    }
}
