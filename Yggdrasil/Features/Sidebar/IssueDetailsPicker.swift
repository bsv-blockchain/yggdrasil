import GRDB
import SwiftUI

/// Wide table view of every issue assigned to the current viewer. Mirrors
/// the screenshot the user shared from `github.com/orgs/<org>/projects/<n>`
/// — Title (with `#N` + repo), Status, Linked PR, Milestone, Labels,
/// Reviewer (review decision of the linked PR, if any).
///
/// Data comes from the existing `task` table — sync already filters to
/// assigned-to-me via `/issues?filter=assigned`, so the rows here are
/// guaranteed to be the viewer's. Issues only — PRs are filtered out.
/// "Linked PR" is the heuristic match: any task with `type='pr'` in the
/// same repo whose title or body contains `#<issueNumber>`.
struct IssueDetailsPicker: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var rows: [Row] = []
    @State private var search: String = ""
    @State private var error: String?
    @State private var openingIssueID: Int64?

    struct Row: Identifiable {
        let issue: YggdrasilTask
        let repo: Repo
        let linkedPR: YggdrasilTask?
        let linkedPRReviewState: String?
        var id: Int64 { issue.id ?? 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            table
            footer
        }
        .padding(22)
        .frame(width: 980, height: 620)
        .background(YggdrasilTheme.bgPane(scheme))
        .onAppear(perform: reload)
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
            Spacer()
            Button {
                Task { await syncNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
    }

    private var searchField: some View {
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
    }

    private var table: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
            if filteredRows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRows) { row in
                            IssueRow(
                                row: row,
                                isOpening: openingIssueID == row.issue.id,
                                onOpen: { Task { await open(row) } },
                                scheme: scheme
                            )
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .background(YggdrasilTheme.bgPaneSoft(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("Title").columnHeader(.title)
            Text("Status").columnHeader(.status)
            Text("Linked PR").columnHeader(.linkedPR)
            Text("Milestone").columnHeader(.milestone)
            Text("Labels").columnHeader(.labels)
            Text("Reviewer").columnHeader(.reviewer)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(YggdrasilTheme.textMute(scheme))
        .background(YggdrasilTheme.bgWindow(scheme))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No issues assigned to you")
                .font(.callout)
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
            Text("Sync hasn't found anything (yet), or you have no open issues in tracked repos.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private var footer: some View {
        HStack {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(YggdrasilTheme.statusErr(scheme))
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Data + actions

    private var filteredRows: [Row] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { row in
            row.issue.title.lowercased().contains(trimmed)
                || "\(row.repo.owner)/\(row.repo.name)".lowercased().contains(trimmed)
                || "#\(row.issue.number)".contains(trimmed)
                || row.issue.labels.contains { $0.name.lowercased().contains(trimmed) }
                || (row.issue.milestoneTitle ?? "").lowercased().contains(trimmed)
        }
    }

    private func reload() {
        do {
            rows = try services.database.queue.read { db -> [Row] in
                let allIssues = try YggdrasilTask.fetchAll(
                    db,
                    sql: """
                    SELECT task.* FROM task
                    WHERE task.type = 'issue'
                    ORDER BY task.updated_at DESC
                    """
                )
                let allPRs = try YggdrasilTask.fetchAll(
                    db,
                    sql: "SELECT * FROM task WHERE type = 'pr'"
                )
                let repos = try Repo.fetchAll(db)
                let statuses = try GitHubStatus.fetchAll(db)
                let repoByID = Dictionary(uniqueKeysWithValues: repos.compactMap { repo -> (Int64, Repo)? in
                    guard let id = repo.id else { return nil }
                    return (id, repo)
                })
                let statusByTaskID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.taskID, $0) })
                return allIssues.compactMap { issue -> Row? in
                    guard let repo = repoByID[issue.repoID] else { return nil }
                    let linked = Self.linkedPR(forIssue: issue, repoID: issue.repoID, candidatePRs: allPRs)
                    let reviewState = linked?.id.flatMap { statusByTaskID[$0]?.reviewState }
                    return Row(
                        issue: issue, repo: repo,
                        linkedPR: linked, linkedPRReviewState: reviewState
                    )
                }
            }
        } catch {
            self.error = "Failed to load issues: \(error.localizedDescription)"
        }
    }

    /// Heuristic: first open PR in the same repo whose title or body
    /// contains `#<issueNumber>`. Exact word-boundary check so `#10`
    /// doesn't match `#100`.
    static func linkedPR(forIssue issue: YggdrasilTask, repoID: Int64, candidatePRs: [YggdrasilTask]) -> YggdrasilTask? {
        let needle = "#\(issue.number)"
        let pattern = try? NSRegularExpression(pattern: "(?<![0-9])\(NSRegularExpression.escapedPattern(for: needle))(?![0-9])")
        return candidatePRs.first { pull in
            guard pull.repoID == repoID, pull.state == .open || pull.state == .merged else { return false }
            let haystack = (pull.title) + " " + (pull.body ?? "")
            guard let pattern else { return haystack.contains(needle) }
            let range = NSRange(haystack.startIndex..., in: haystack)
            return pattern.firstMatch(in: haystack, range: range) != nil
        }
    }

    private func syncNow() async {
        do {
            try await services.syncService.fullSync()
            services.tabs.reload()
            reload()
        } catch {
            self.error = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func open(_ row: Row) async {
        guard openingIssueID == nil, let taskID = row.issue.id else { return }
        openingIssueID = taskID
        defer { openingIssueID = nil }
        // Open via the existing assigned-picker flow so we get the same
        // worktree + agent wiring without duplicating logic.
        do {
            guard let agent = try (services.agentStore.getDefault() ?? services.agentStore.list().first) else {
                error = "No coding agent configured."
                return
            }
            let branch = TaskPickerMode.assigned.branchName(for: row.issue, agentName: agent.name)
            let worktreeURL = try await services.worktreeManager.ensure(
                repo: row.repo, branch: branch, baseRef: nil
            )
            let newTab = try services.tabStore.insert(
                branchName: branch,
                worktreePath: worktreeURL.path,
                agentID: agent.id,
                taskID: taskID
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
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

// MARK: - Row + column layout

private enum IssueColumn {
    case title, status, linkedPR, milestone, labels, reviewer

    var width: CGFloat {
        switch self {
        case .title: 320
        case .status: 90
        case .linkedPR: 100
        case .milestone: 130
        case .labels: 200
        case .reviewer: 110
        }
    }

    var alignment: Alignment {
        switch self {
        case .title, .milestone, .labels: .leading
        case .status, .linkedPR, .reviewer: .center
        }
    }
}

private extension Text {
    func columnHeader(_ column: IssueColumn) -> some View {
        self
            .lineLimit(1)
            .frame(width: column.width, alignment: column.alignment)
    }
}

private struct IssueRow: View {
    let row: IssueDetailsPicker.Row
    let isOpening: Bool
    let onOpen: () -> Void
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 8) {
            titleColumn
            statusBadge
                .frame(width: IssueColumn.status.width, alignment: .center)
            linkedPRColumn
                .frame(width: IssueColumn.linkedPR.width, alignment: .center)
            milestoneColumn
                .frame(width: IssueColumn.milestone.width, alignment: .leading)
            labelsColumn
                .frame(width: IssueColumn.labels.width, alignment: .leading)
            reviewerColumn
                .frame(width: IssueColumn.reviewer.width, alignment: .center)
            Spacer(minLength: 0)
            if isOpening {
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var titleColumn: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dotted")
                .foregroundStyle(YggdrasilTheme.ember)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.issue.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(YggdrasilTheme.text(scheme))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("#\(row.issue.number)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    Text("\(row.repo.owner)/\(row.repo.name)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.textMute(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(width: IssueColumn.title.width, alignment: .leading)
    }

    private var statusBadge: some View {
        let (text, tone): (String, StatusChip.Tone) = {
            switch row.issue.state {
            case .open: return ("open", .ok)
            case .closed: return ("closed", .neutral)
            case .merged: return ("merged", .info)
            }
        }()
        return StatusChip(chip: .init(symbol: nil, text: text, tone: tone))
    }

    @ViewBuilder
    private var linkedPRColumn: some View {
        if let pull = row.linkedPR {
            Text("#\(pull.number)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(YggdrasilTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(YggdrasilTheme.accentSoft(scheme)))
                .help(pull.title)
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textFaint(scheme))
        }
    }

    @ViewBuilder
    private var milestoneColumn: some View {
        if let milestone = row.issue.milestoneTitle, !milestone.isEmpty {
            Text(milestone)
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textFaint(scheme))
        }
    }

    private var labelsColumn: some View {
        let labels = row.issue.labels
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if labels.isEmpty {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(YggdrasilTheme.textFaint(scheme))
                } else {
                    ForEach(labels, id: \.name) { label in
                        LabelChip(label: label, scheme: scheme)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reviewerColumn: some View {
        if let reviewState = row.linkedPRReviewState, !reviewState.isEmpty {
            Text(reviewState.lowercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(reviewTone(reviewState))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(reviewTone(reviewState).opacity(0.16))
                )
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textFaint(scheme))
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
}

/// Coloured chip for a single GitHub label. Background uses the label's hex
/// color at low alpha so dark + light themes both read.
private struct LabelChip: View {
    let label: YggdrasilTask.Label
    let scheme: ColorScheme

    var body: some View {
        Text(label.name)
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
        // GitHub returns labels.color as 6-char hex (no leading #).
        var hex: UInt64 = 0
        Scanner(string: label.color).scanHexInt64(&hex)
        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    private var textColor: Color {
        scheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.75)
    }
}
