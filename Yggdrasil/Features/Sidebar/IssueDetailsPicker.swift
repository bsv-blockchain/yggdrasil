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
    /// Issues currently being opened. A set, not a single id, so setting one
    /// up (worktree creation, possibly a fetch) doesn't freeze the others.
    @State private var openingIssueIDs: Set<String> = []
    @State private var agents: [CodingAgent] = []
    /// nil until the user picks one, which means "use the default".
    @State private var selectedAgentID: Int64?
    @State private var hosts: [RemoteHost] = []
    /// nil = this Mac. Starts on the default host; see `HostChooser`.
    @State private var selectedHostID: Int64?
    @State private var hostsLoaded = false
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

        var repoFull: String {
            "\(owner)/\(repoName)"
        }

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
                    .disabled(openBlocker(row) != nil)
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
                // Always shown: whether the row can open depends on this choice,
                // so hiding it with the button would leave no way back.
                HostChooser(hosts: hosts, selectedHostID: $selectedHostID, scheme: scheme)
                if let blocker = openBlocker(row) {
                    Text(blocker)
                        .font(.callout)
                        .foregroundStyle(YggdrasilTheme.textMute(scheme))
                } else {
                    AgentChooser(agents: agents, selectedAgentID: $selectedAgentID, scheme: scheme)
                    Button("Open as Tab") { Task { await open(row) } }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(openingIssueIDs.contains(row.id))
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

    /// Re-read every reload, so hosts added, edited or removed in Settings
    /// while the window is open are what gets used. Only the starting
    /// selection is set once; later reloads keep the user's pick unless that
    /// host is gone, which falls back to this Mac.
    private func loadHosts() {
        hosts = (try? services.hostStore.list()) ?? []
        if !hostsLoaded {
            hostsLoaded = true
            selectedHostID = HostChooser.initialSelection(defaultHostID: services.defaultHostID, hosts: hosts)
        } else if let id = selectedHostID, !hosts.contains(where: { $0.id == id }) {
            selectedHostID = nil
        }
    }

    private var chosenHost: RemoteHost? {
        HostChooser.resolveHost(selectedID: selectedHostID, hosts: hosts)
    }

    private func reload() async {
        loadHosts()
        loading = true
        error = nil
        defer { loading = false }
        do {
            agents = (try? services.agentStore.list()) ?? []
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

    /// Open as a tab — only works for tracked repos (we need a localMainPath
    /// to create a worktree). For others, the footer surfaces a hint.
    private func open(_ row: Row) async {
        // Only guards against double-firing the same issue; others stay live.
        guard !openingIssueIDs.contains(row.id) else { return }
        openingIssueIDs.insert(row.id)
        defer { openingIssueIDs.remove(row.id) }
        do {
            let repos = try await services.database.queue.read { db in try Repo.fetchAll(db) }
            let host = chosenHost
            guard let repo = repos.first(where: { $0.owner == row.owner && $0.name == row.repoName }),
                  host != nil || repo.localMainPath != nil else {
                error = openBlocker(row)
                return
            }
            guard let agent = try AgentChooser.resolveAgent(
                selectedID: selectedAgentID,
                agents: agents,
                defaultAgent: services.agentStore.getDefault()
            ) else {
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
            // Prepared in the background, like the other two open paths.
            guard let plannedPath = try services.plannedWorktreePath(
                repo: repo, branch: branch, host: host
            ) else {
                error = "\(row.repoFull) isn't cloned on this Mac — run it on a host, or set its location in Settings → Repositories."
                return
            }
            let newTab = try services.tabStore.insert(
                branchName: branch,
                worktreePath: plannedPath,
                agentID: agent.id,
                taskID: nil,
                preparationState: .pending,
                hostID: host?.id
            )
            services.tabs.reload()
            if let tabID = newTab.id {
                services.tabs.select(tabID)
                await services.worktreePreparer.enqueue(
                    tabID: tabID, repo: repo, host: host, branch: branch, baseRef: nil
                )
            }
            services.triggerSyncNow()
            // No `dismiss()` — same reasoning as AssignedTaskPicker: opening
            // one issue usually means opening several, and a window that
            // closes itself has to be reopened for each one.
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Why the row can't open as a tab where it's set to run, or nil if it can.
    private func openBlocker(_ row: Row) -> String? {
        let repos = (try? services.database.queue.read { db in try Repo.fetchAll(db) }) ?? []
        guard let repo = repos.first(where: { $0.owner == row.owner && $0.name == row.repoName }) else {
            return "Repo not tracked — add it in Settings → Repositories to open as a tab."
        }
        guard chosenHost != nil || repo.localMainPath != nil else {
            return "Not cloned on this Mac — run it on a host, or set its location in Settings → Repositories."
        }
        return nil
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
