import GRDB
import SwiftUI

/// Mode toggle for the task-picker sheet. Same UI/flow, different source set:
/// `assigned` reads from `task` directly (sync filters to assignee:@me);
/// `review` reads from `pr_review_request` (PRs the user has been asked to
/// review, fetched via the search endpoint).
enum TaskPickerMode {
    case assigned
    case review

    var title: String {
        switch self {
        case .assigned: "Open Assigned"
        case .review: "PRs to Review"
        }
    }

    var emptyTitle: String {
        switch self {
        case .assigned: "Nothing to open"
        case .review: "No reviews waiting"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .assigned: "All assigned issues and PRs are already open, or nothing has been synced yet."
        case .review: "You're not currently requested as a reviewer on any open PR."
        }
    }

    /// Branch + worktree name used when opening a task in this mode. The
    /// agent slug is the leading segment so the same PR can host parallel
    /// agents — each one ends up on its own branch in its own worktree
    /// directory (`<repoParent>/.worktrees/<agent>-<base>`). The `review-`
    /// infix still lets the sidebar and chrome pick up the REVIEW badge
    /// without a schema change.
    func branchName(for task: YggdrasilTask, agentName: String) -> String {
        let prefix = TaskPickerMode.agentSlug(agentName)
        let base: String
        switch self {
        case .assigned:
            base = task.type == .pullRequest ? "pr-\(task.number)" : "issue-\(task.number)"
        case .review:
            base = "review-pr-\(task.number)"
        }
        return prefix.isEmpty ? base : "\(prefix)-\(base)"
    }

    /// Lowercase + hyphenated slug from an agent profile name. "Claude" →
    /// "claude"; "GitHub Copilot" → "github-copilot". Pure for testability.
    static func agentSlug(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits)
        var out = ""
        var lastWasDash = true
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                out.append(Character(scalar))
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Sheet that lists tasks (assigned issues/PRs, or review-requested PRs)
/// not yet open as a tab. Clicking a row opens it: ensures the worktree
/// (PR head fetched, or new branch off the default base for issues) and
/// inserts a tab linked to the task using the user's default coding agent.
///
/// Reads the relevant table directly — sync already filters server-side,
/// so we don't need an extra GitHub round-trip here.
struct AssignedTaskPicker: View {
    let services: AppServices
    var mode: TaskPickerMode = .assigned
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var rows: [Row] = []
    @State private var search: String = ""
    @State private var error: String?
    @State private var openingTaskID: Int64?

    /// One picker row. Bundles the task + its owning repo so the body view
    /// doesn't have to re-query per render.
    struct Row: Identifiable {
        let task: YggdrasilTask
        let repo: Repo
        var id: Int64 { task.id ?? 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            list
            footer
        }
        .padding(22)
        .frame(
            minWidth: 600, idealWidth: 720, maxWidth: .infinity,
            minHeight: 420, idealHeight: 540, maxHeight: .infinity
        )
        .background(YggdrasilTheme.bgPane(scheme))
        .onAppear(perform: reload)
        .accessibilityIdentifier("sidebar.assignedpicker.sheet")
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(mode.title)
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(YggdrasilTheme.text(scheme))
            Text("\(filteredRows.count) available")
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
            TextField("Filter by title, repo, or number", text: $search)
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

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredRows.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredRows) { row in
                        TaskRow(row: row, isOpening: openingTaskID == row.task.id, scheme: scheme)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await open(row) } }
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YggdrasilTheme.bgPaneSoft(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: mode == .review ? "checkmark.seal" : "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(mode.emptyTitle)
                .font(.callout)
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
            Text(mode.emptySubtitle)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    private var footer: some View {
        HStack {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(YggdrasilTheme.statusErr(scheme))
                    .accessibilityIdentifier("assignedpicker.error")
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Data

    private var filteredRows: [Row] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { row in
            row.task.title.lowercased().contains(trimmed)
                || "\(row.repo.owner)/\(row.repo.name)".lowercased().contains(trimmed)
                || "#\(row.task.number)".contains(trimmed)
        }
    }

    private func reload() {
        do {
            rows = try services.database.queue.read { db -> [Row] in
                // Tasks not currently shadowed by any tab.
                let openedTaskIDs = try Int64.fetchSet(
                    db, sql: "SELECT task_id FROM tab WHERE task_id IS NOT NULL"
                )
                let candidateTasks: [YggdrasilTask]
                switch mode {
                case .assigned:
                    // Issues assigned to me + PRs I authored. The task table
                    // holds all assigned issues (from /issues?filter=assigned)
                    // plus the PRs we mirror in pr_authored.
                    candidateTasks = try YggdrasilTask.fetchAll(
                        db,
                        sql: """
                        SELECT task.* FROM task
                        WHERE task.type = 'issue'
                           OR task.id IN (SELECT task_id FROM pr_authored)
                        ORDER BY task.updated_at DESC
                        """
                    )
                case .review:
                    // PRs to review = review-requested ∪ assigned-but-not-authored.
                    // A PR I both authored and was review-requested on lands
                    // here too (rare but possible); the picker still excludes
                    // it once a tab shadows it.
                    candidateTasks = try YggdrasilTask.fetchAll(
                        db,
                        sql: """
                        SELECT task.* FROM task
                        WHERE task.type = 'pr'
                          AND (
                            task.id IN (SELECT task_id FROM pr_review_request)
                         OR (task.id IN (SELECT task_id FROM pr_assigned)
                             AND task.id NOT IN (SELECT task_id FROM pr_authored))
                          )
                        ORDER BY task.updated_at DESC
                        """
                    )
                }
                let repos = try Repo.fetchAll(db)
                let repoByID = Dictionary(uniqueKeysWithValues: repos.compactMap { repo -> (Int64, Repo)? in
                    guard let id = repo.id else { return nil }
                    return (id, repo)
                })
                return candidateTasks.compactMap { task -> Row? in
                    guard let taskID = task.id, !openedTaskIDs.contains(taskID) else { return nil }
                    guard let repo = repoByID[task.repoID] else { return nil }
                    return Row(task: task, repo: repo)
                }
            }
        } catch {
            self.error = "Failed to load tasks: \(error.localizedDescription)"
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
        guard openingTaskID == nil, let taskID = row.task.id else { return }
        openingTaskID = taskID
        error = nil
        defer { openingTaskID = nil }
        do {
            guard row.repo.localMainPath != nil else {
                error = "Repo \(row.repo.fullName) has no local clone. Set it in Preferences → Repos."
                return
            }
            guard let agent = try (services.agentStore.getDefault() ?? services.agentStore.list().first)
            else {
                error = "No coding agent configured."
                return
            }
            let branch = mode.branchName(for: row.task, agentName: agent.name)
            let baseRef: String? = row.task.type == .pullRequest
                ? "refs/pull/\(row.task.number)/head"
                : nil
            let worktreeURL = try await services.worktreeManager.ensure(
                repo: row.repo, branch: branch, baseRef: baseRef
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
            // Refresh GitHub-side state so the pending-review pill + CI
            // badges catch up immediately rather than waiting for the
            // next scheduled tick.
            services.triggerSyncNow()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// One row in the assigned-task list.
private struct TaskRow: View {
    let row: AssignedTaskPicker.Row
    let isOpening: Bool
    let scheme: ColorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            typeIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(row.task.number)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    Text(row.task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(YggdrasilTheme.text(scheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    Text("\(row.repo.owner)/\(row.repo.name)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.textMute(scheme))
                    stateBadge
                }
            }
            Spacer()
            if isOpening {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color.clear
                .contentShape(Rectangle())
        )
    }

    @ViewBuilder
    private var typeIcon: some View {
        switch row.task.type {
        case .pullRequest:
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(YggdrasilTheme.accent)
                .frame(width: 18)
        case .issue:
            Image(systemName: "circle.dotted")
                .foregroundStyle(YggdrasilTheme.ember)
                .frame(width: 18)
        }
    }

    private var stateBadge: some View {
        let (text, tone): (String, StatusChip.Tone) = {
            switch row.task.state {
            case .open: return ("open", .ok)
            case .closed: return ("closed", .neutral)
            case .merged: return ("merged", .info)
            }
        }()
        return StatusChip(chip: .init(symbol: nil, text: text, tone: tone))
    }
}
