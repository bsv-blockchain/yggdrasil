import GRDB
import SwiftUI

// swiftlint:disable type_body_length
/// Wide table view of every issue assigned to the current viewer, fetched
/// directly from GitHub (`/search/issues?q=is:issue is:open assignee:@me`)
/// so it isn't limited to tracked-repo rows. Columns are native SwiftUI
/// `Table` columns — user can resize and sort.
///
/// "Linked PR" is the heuristic match: any synced PR in our local task
/// table whose title or body mentions `#<issueNumber>`. For issues in
/// untracked repos we don't have local PR data, so the column reads `—`.
struct IssueDetailsPicker: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var rows: [Row] = []
    @State private var trackedRepoKeys: Set<String> = []
    @State private var search: String = ""
    @State private var trackedOnly: Bool = false
    @State private var sortOrder: [KeyPathComparator<Row>] = [
        .init(\Row.updatedAtSort, order: .reverse)
    ]
    @State private var error: String?
    @State private var loading: Bool = false
    @State private var openingIssueID: String?
    @State private var selection: Row.ID?

    /// Local-DB snapshot needed to compute linked-PR + repo metadata.
    private struct LocalSnapshot {
        let prs: [YggdrasilTask]
        let statusByTaskID: [Int64: GitHubStatus]
        let reposByKey: [String: Repo]
    }

    struct Row: Identifiable, Hashable {
        /// `<owner>/<repo>#<number>` — stable across launches.
        let id: String
        let owner: String
        let repoName: String
        let number: Int
        let title: String
        let state: String
        let stateSort: Int
        let labels: [LabelChip.Data]
        let milestone: String
        let linkedPRNumber: Int?
        let linkedPRState: String?
        let reviewState: String?
        let updatedAtSort: Date
        let updatedAtDisplay: String
        let htmlURL: String

        var repoFull: String { "\(owner)/\(repoName)" }

        struct LabelChipData: Hashable {
            let name: String
            let color: String
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            table
            footer
        }
        .padding(20)
        // maxWidth/maxHeight = .infinity is what lets the user actually drag
        // the sheet edges to resize. Without them macOS treats the sheet as
        // a fixed-size dialog locked to idealWidth/idealHeight.
        .frame(
            minWidth: 760, idealWidth: 1100, maxWidth: .infinity,
            minHeight: 460, idealHeight: 680, maxHeight: .infinity
        )
        .background(YggdrasilTheme.bgPane(scheme))
        .onAppear { Task { await reload() } }
        .accessibilityIdentifier("sidebar.issuedetails.sheet")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("My Issues")
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(YggdrasilTheme.text(scheme))
            Text("\(filteredRows.count) of \(rows.count)")
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
            if loading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(loading)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                TextField("Filter by title, repo, label, milestone, or #number", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(YggdrasilTheme.text(scheme))
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(YggdrasilTheme.bgPaneSoft(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Toggle(isOn: $trackedOnly) {
                Text("Tracked repos only")
                    .font(.system(size: 11))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("sidebar.issuedetails.trackedOnly")
        }
    }

    private var table: some View {
        Table(filteredRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(YggdrasilTheme.text(scheme))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text("#\(row.number)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(YggdrasilTheme.textDim(scheme))
                        Text(row.repoFull)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(YggdrasilTheme.textMute(scheme))
                    }
                }
                .padding(.vertical, 4)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Status", value: \.stateSort) { row in
                StatusChip(chip: .init(symbol: nil, text: row.state, tone: tone(for: row.state)))
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("Linked PR") { row in
                if let prNumber = row.linkedPRNumber {
                    Text("#\(prNumber)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(YggdrasilTheme.accentSoft(scheme)))
                } else {
                    Text("—").foregroundStyle(YggdrasilTheme.textFaint(scheme))
                }
            }
            .width(min: 80, ideal: 100, max: 130)

            TableColumn("Milestone", value: \.milestone) { row in
                if row.milestone.isEmpty {
                    Text("—").foregroundStyle(YggdrasilTheme.textFaint(scheme))
                } else {
                    Text(row.milestone)
                        .font(.system(size: 11))
                        .foregroundStyle(YggdrasilTheme.textDim(scheme))
                        .lineLimit(1)
                }
            }
            .width(min: 80, ideal: 130)

            TableColumn("Labels") { row in
                if row.labels.isEmpty {
                    Text("—").foregroundStyle(YggdrasilTheme.textFaint(scheme))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(row.labels, id: \.self) { label in
                                LabelChip(data: label, scheme: scheme)
                            }
                        }
                    }
                }
            }
            .width(min: 120, ideal: 220)

            TableColumn("Reviewer") { row in
                if let reviewState = row.reviewState, !reviewState.isEmpty {
                    Text(reviewState.lowercased().replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(reviewTone(reviewState))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(reviewTone(reviewState).opacity(0.16)))
                } else {
                    Text("—").foregroundStyle(YggdrasilTheme.textFaint(scheme))
                }
            }
            .width(min: 80, ideal: 110, max: 140)
        }
        .onChange(of: sortOrder) { _, newOrder in
            rows.sort(using: newOrder)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Open on GitHub") {
                    if let url = URL(string: row.htmlURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Open as Tab") { Task { await open(row) } }
                    .disabled(!canOpen(row))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(YggdrasilTheme.statusErr(scheme))
            }
            Spacer()
            if let id = selection,
               let row = rows.first(where: { $0.id == id }) {
                if canOpen(row) {
                    Button("Open as Tab") { Task { await open(row) } }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(openingIssueID != nil)
                } else {
                    Text("Repo not tracked — add it in Preferences → Repos to open as a tab.")
                        .font(.callout)
                        .foregroundStyle(YggdrasilTheme.textMute(scheme))
                }
                Button("Open on GitHub") {
                    if let url = URL(string: row.htmlURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Data + actions

    private var filteredRows: [Row] {
        Self.filter(
            rows: rows, search: search,
            trackedRepoKeys: trackedRepoKeys, trackedOnly: trackedOnly
        )
    }

    /// Pure helper exposed for unit testing. The view body just renders the
    /// result, so all filter logic lives here in one place.
    static func filter(
        rows: [Row], search: String, trackedRepoKeys: Set<String>, trackedOnly: Bool
    ) -> [Row] {
        var result = rows
        if trackedOnly {
            result = result.filter { trackedRepoKeys.contains($0.repoFull) }
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return result }
        return result.filter { row in
            row.title.lowercased().contains(trimmed)
                || row.repoFull.lowercased().contains(trimmed)
                || "#\(row.number)".contains(trimmed)
                || row.labels.contains { $0.name.lowercased().contains(trimmed) }
                || row.milestone.lowercased().contains(trimmed)
        }
    }

    private func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            // GitHub-side fetch — every assigned issue across the user's
            // entire GitHub account, not limited by our tracked-repo set.
            let raws = try await services.restClient.allAssignedIssues()
            // Local PR knowledge for the linked-PR heuristic.
            let local = try await services.database.queue.read { db -> LocalSnapshot in
                let prs = try YggdrasilTask.fetchAll(db, sql: "SELECT * FROM task WHERE type = 'pr'")
                let stats = try GitHubStatus.fetchAll(db)
                let repos = try Repo.fetchAll(db)
                return LocalSnapshot(
                    prs: prs,
                    statusByTaskID: Dictionary(uniqueKeysWithValues: stats.map { ($0.taskID, $0) }),
                    reposByKey: Dictionary(uniqueKeysWithValues: repos.map { repo in
                        ("\(repo.owner)/\(repo.name)", repo)
                    })
                )
            }
            rows = raws.map { raw in
                let linked = Self.linkedPR(forIssueNumber: raw.number,
                                           repoKey: "\(raw.repoOwner)/\(raw.repoName)",
                                           candidatePRs: local.prs,
                                           repos: local.reposByKey)
                let reviewState = linked?.id.flatMap { local.statusByTaskID[$0]?.reviewState }
                let labelChips = raw.labels.map { LabelChip.Data(name: $0.name, color: $0.color) }
                let stateOrder: Int = (raw.state == .open) ? 0 : (raw.state == .merged ? 1 : 2)
                let updatedDisplay = Self.relativeDateFormatter.localizedString(for: raw.updatedAt, relativeTo: Date())
                return Row(
                    id: "\(raw.repoOwner)/\(raw.repoName)#\(raw.number)",
                    owner: raw.repoOwner,
                    repoName: raw.repoName,
                    number: raw.number,
                    title: raw.title,
                    state: raw.state.rawValue,
                    stateSort: stateOrder,
                    labels: labelChips,
                    milestone: raw.milestoneTitle ?? "",
                    linkedPRNumber: linked?.number,
                    linkedPRState: linked?.state.rawValue,
                    reviewState: reviewState,
                    updatedAtSort: raw.updatedAt,
                    updatedAtDisplay: updatedDisplay,
                    htmlURL: raw.githubURL
                )
            }
            rows.sort(using: sortOrder)
            trackedRepoKeys = Set(local.reposByKey.keys)
        } catch {
            self.error = "Failed to load issues: \(error.localizedDescription)"
        }
    }

    /// Local-DB-driven heuristic. We only know about PRs in tracked repos,
    /// so untracked-repo issues never get a linked PR — that's a known
    /// limitation, documented in the footer when the user selects one.
    static func linkedPR(
        forIssueNumber issueNumber: Int,
        repoKey: String,
        candidatePRs: [YggdrasilTask],
        repos: [String: Repo]
    ) -> YggdrasilTask? {
        guard let repoID = repos[repoKey]?.id else { return nil }
        let needle = "#\(issueNumber)"
        let pattern = try? NSRegularExpression(
            pattern: "(?<![0-9])\(NSRegularExpression.escapedPattern(for: needle))(?![0-9])"
        )
        return candidatePRs.first { pull in
            guard pull.repoID == repoID else { return false }
            let haystack = pull.title + " " + (pull.body ?? "")
            guard let pattern else { return haystack.contains(needle) }
            return pattern.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        }
    }

    /// Open as a tab — only works for tracked repos (we need a localMainPath
    /// to create a worktree). For others, the footer surfaces a hint.
    private func open(_ row: Row) async {
        guard openingIssueID == nil else { return }
        openingIssueID = row.id
        defer { openingIssueID = nil }
        do {
            let repos = try await services.database.queue.read { db in try Repo.fetchAll(db) }
            guard let repo = repos.first(where: { $0.owner == row.owner && $0.name == row.repoName }),
                  repo.localMainPath != nil else {
                error = "\(row.repoFull) isn't tracked locally. Add it in Preferences → Repos."
                return
            }
            guard let agent = try (services.agentStore.getDefault() ?? services.agentStore.list().first) else {
                error = "No coding agent configured."
                return
            }
            // Reuse the existing branchName helper. Mode .assigned for issues.
            let dummyTask = YggdrasilTask(
                id: nil, repoID: repo.id ?? 0, type: .issue, number: row.number,
                title: row.title, body: nil, state: .open, authorLogin: "",
                githubURL: row.htmlURL, apiURL: row.htmlURL,
                createdAt: Date(), updatedAt: row.updatedAtSort, lastSyncedAt: Date(),
                etag: nil, labelsJSON: "[]", milestoneTitle: nil
            )
            let branch = TaskPickerMode.assigned.branchName(for: dummyTask, agentName: agent.name)
            let worktreeURL = try await services.worktreeManager.ensure(
                repo: repo, branch: branch, baseRef: nil
            )
            let newTab = try services.tabStore.insert(
                branchName: branch,
                worktreePath: worktreeURL.path,
                agentID: agent.id,
                taskID: nil
            )
            services.tabs.reload()
            if let tabID = newTab.id {
                services.tabs.select(tabID)
                services.sessions.add(
                    OpenSession(
                        id: tabID,
                        displayName: "\(agent.name) · \(branch)",
                        cwd: worktreeURL.path,
                        command: agent.command,
                        args: agent.args
                    )
                )
            }
            services.triggerSyncNow()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func canOpen(_ row: Row) -> Bool {
        guard let repos = try? services.database.queue.read({ db in try Repo.fetchAll(db) }) else {
            return false
        }
        return repos.first(where: { $0.owner == row.owner && $0.name == row.repoName })?
            .localMainPath != nil
    }

    private func tone(for state: String) -> StatusChip.Tone {
        switch state {
        case "open": .ok
        case "closed": .neutral
        case "merged": .info
        default: .neutral
        }
    }

    private func reviewTone(_ state: String) -> Color {
        switch state.uppercased() {
        case "APPROVED": YggdrasilTheme.statusOK(scheme)
        case "CHANGES_REQUESTED": YggdrasilTheme.statusErr(scheme)
        case "REVIEW_REQUIRED": YggdrasilTheme.statusWarn(scheme)
        default: YggdrasilTheme.textDim(scheme)
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
// swiftlint:enable type_body_length

/// Coloured chip for a single GitHub label. Background uses the label's hex
/// color at low alpha so dark + light themes both read.
struct LabelChip: View {
    let data: Data
    let scheme: ColorScheme

    struct Data: Hashable {
        let name: String
        let color: String
    }

    var body: some View {
        Text(data.name)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(textColor)
            .background(
                Capsule().fill(parsedColor.opacity(0.22))
            )
            .overlay(
                Capsule().stroke(parsedColor.opacity(0.45), lineWidth: 0.5)
            )
    }

    private var parsedColor: Color {
        var hex: UInt64 = 0
        Scanner(string: data.color).scanHexInt64(&hex)
        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    private var textColor: Color {
        scheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.75)
    }
}
