import SwiftUI

/// GitHub sub-pane. Resolves which page to load for the tab and hosts the
/// pooled `WKWebView`, or an empty state when the tab isn't inside any tracked
/// repository.
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
                    Text("This tab isn't inside a tracked repository.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var githubURL: URL? {
        guard let id = tab.id else { return nil }
        return GitHubSubPane.resolveURL(
            primaryTask: services.tabs.tasksByTabID[id],
            linkedPR: services.tabs.prTasksByTabID[id],
            repo: services.tabs.repoByTabID[id],
            branchName: tab.branchName
        )
    }

    /// Which GitHub page the tab opens, in priority order:
    /// 1. the linked **PR** — an issue tab's attached PR, the tab's own PR
    ///    task, or (before the next sync) a PR number parsed from the branch;
    /// 2. the linked **issue** — the tab's issue task, or an issue branch;
    /// 3. the **repo home page** — for ad-hoc tabs inside a tracked repo;
    /// 4. `nil` — the tab isn't inside any tracked repository.
    static func resolveURL(
        primaryTask: YggdrasilTask?,
        linkedPR: YggdrasilTask?,
        repo: Repo?,
        branchName: String
    ) -> URL? {
        // 1. PR: an issue tab's linked PR wins, then a PR-primary tab.
        if let prTask = linkedPR, prTask.type == .pullRequest, let url = URL(string: prTask.githubURL) {
            return url
        }
        if let primaryTask, primaryTask.type == .pullRequest, let url = URL(string: primaryTask.githubURL) {
            return url
        }
        // 2. Issue.
        if let primaryTask, primaryTask.type == .issue, let url = URL(string: primaryTask.githubURL) {
            return url
        }
        // 3. Not yet synced: synthesize from the PR/issue number in the branch
        //    so the user can navigate before the next sync imports the task.
        if let repo, let number = NewTabSheet.parsePRNumber(branchName) {
            let path = branchName.lowercased().hasPrefix("issue") ? "issues" : "pull"
            return URL(string: "https://github.com/\(repo.owner)/\(repo.name)/\(path)/\(number)")
        }
        // 4. Ad-hoc tab inside a tracked repo → the repo home page.
        if let repo {
            return URL(string: "https://github.com/\(repo.owner)/\(repo.name)")
        }
        return nil
    }
}
