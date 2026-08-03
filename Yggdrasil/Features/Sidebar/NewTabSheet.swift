import GRDB
import SwiftUI

// swiftlint:disable file_length type_body_length
/// "+" sheet shown from the sidebar — redesigned per `Yggdrasil.html`'s agent
/// picker. Top: context strip (repo + branch). Middle: row of agent cards
/// (one per CodingAgent profile, badged with its brand identity, default
/// agent gets a "DEFAULT" pill). Bottom: branch text field + confirm.
///
/// On confirm: WorktreeManager.ensure → TabStore.insert → SessionsModel.add
/// → AgentTerminalSurface mounts and spawns.
struct NewTabSheet: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var repos: [Repo] = []
    @State private var agents: [CodingAgent] = []
    @State private var selectedRepoID: Int64?
    @State private var selectedAgentID: Int64?
    @State private var branchName: String = ""
    /// Base ref the new branch is created off (e.g. `main`, `develop`).
    /// Defaults to the picked repo's recorded default branch but is fully
    /// editable so the user can branch off any commit-ish.
    @State private var baseBranch: String = ""
    @State private var inProgress: Bool = false
    @State private var cloning: Bool = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(YggdrasilTheme.text(scheme))

            contextStrip
            agentsRow
            branchRow

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(YggdrasilTheme.statusErr(scheme))
                    .accessibilityIdentifier("newtab.error")
            }

            if cloning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cloning…")
                        .font(.callout)
                        .foregroundStyle(YggdrasilTheme.textMute(scheme))
                }
                .accessibilityIdentifier("newtab.cloning")
            }

            Spacer(minLength: 4)

            HStack {
                Text("Remember for this repo")
                    .font(.system(size: 11))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start session") {
                    Task { await confirm() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(22)
        .frame(
            minWidth: 580, idealWidth: 660, maxWidth: .infinity,
            minHeight: 440, idealHeight: 560, maxHeight: .infinity
        )
        .background(YggdrasilTheme.bgPane(scheme))
        .onAppear(perform: load)
        .onChange(of: selectedRepoID) { _, _ in
            baseBranch = selectedRepo?.defaultBranch ?? ""
        }
        .accessibilityIdentifier("sidebar.newtab.sheet")
    }

    // MARK: - Subviews

    private var contextStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
            Picker("", selection: $selectedRepoID) {
                ForEach(repos, id: \.id) { repo in
                    Text(repo.fullName).tag(repo.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if let repo = repos.first(where: { $0.id == selectedRepoID }),
               let path = repo.localMainPath {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("(no local clone)")
                    .font(.system(size: 10))
                    .foregroundStyle(YggdrasilTheme.statusWarn(scheme))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(YggdrasilTheme.bgPaneSoft(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var agentsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(YggdrasilTheme.textMute(scheme))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(agents, id: \.id) { agent in
                        AgentCard(
                            agent: agent,
                            isSelected: selectedAgentID == agent.id,
                            scheme: scheme
                        )
                        // Whole card tappable, not just its opaque pixels —
                        // an `.onTapGesture` on a view with transparent gaps
                        // otherwise only hits the rendered content.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAgentID = agent.id
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 1)
            }
        }
    }

    private var branchRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New branch")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))

                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    TextField("feat/new-thing", text: $branchName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.text(scheme))
                    Button("Auto-name") { branchName = autoBranchName() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .disabled(selectedAgentID == nil)
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(YggdrasilTheme.bgPaneSoft(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(
                    "Yggdrasil will create this branch in a new worktree under \(repoMainPath ?? "<repo>")/.worktrees/. Type `pr-N` or `issue-N` to auto-link to an existing GitHub task."
                )
                .font(.system(size: 10))
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base branch")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))

                HStack(spacing: 7) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    TextField(defaultBranchPlaceholder, text: $baseBranch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.text(scheme))
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(YggdrasilTheme.bgPaneSoft(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(YggdrasilTheme.border(scheme), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(
                    "The commit the new branch starts from. Default branch: \(defaultBranchPlaceholder) (from GitHub)."
                )
                .font(.system(size: 10))
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var defaultBranchPlaceholder: String {
        selectedRepo?.defaultBranch ?? "main"
    }

    private var repoMainPath: String? {
        selectedRepo?.localMainPath
    }

    private var selectedRepo: Repo? {
        repos.first { $0.id == selectedRepoID }
    }

    /// Build a unique-ish branch suggestion combining the picked agent's
    /// slug and a short timestamp. Helps users who just want to jump into a
    /// new session without thinking up a branch name.
    private func autoBranchName() -> String {
        let agent = agents.first { $0.id == selectedAgentID }
        let agentSlug = agent.map { TaskPickerMode.agentSlug($0.name) } ?? "session"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(agentSlug)/\(formatter.string(from: Date()))"
    }

    // MARK: - Logic (preserved)

    private var canConfirm: Bool {
        guard !inProgress else { return false }
        guard selectedRepoID != nil, selectedAgentID != nil else { return false }
        return !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        do {
            repos = try services.database.queue.read { db in try Repo.fetchAll(db) }
            agents = try services.agentStore.list()
            selectedRepoID = repos.first?.id
            selectedAgentID = (try? services.agentStore.getDefault()?.id) ?? agents.first?.id
            baseBranch = selectedRepo?.defaultBranch ?? ""
        } catch {
            self.error = "Failed to load: \(error.localizedDescription)"
        }
    }

    // swiftlint:disable:next function_body_length
    private func confirm() async {
        // If the user pasted a GitHub URL, switch the repo picker to the
        // matching tracked repo (when available) before resolving the rest
        // of the confirm path. Avoids "wrong repo" surprises.
        let interpretedSlug = Self.interpretBranchInput(branchName).repoSlug
        if let slug = interpretedSlug,
           let match = repos.first(where: { "\($0.owner)/\($0.name)".lowercased() == slug.lowercased() }) {
            selectedRepoID = match.id
        }

        guard let repoID = selectedRepoID,
              let agent = agents.first(where: { $0.id == selectedAgentID }),
              var repo = repos.first(where: { $0.id == repoID })
        else { return }

        inProgress = true
        error = nil
        defer { inProgress = false }

        guard await ensureRepoCloned(repo) else { return }

        if let updated = repos.first(where: { $0.id == repoID }) { repo = updated }
        guard repo.localMainPath != nil else {
            error = "Repo \(repo.fullName) has no local clone path on disk; set it in Settings > Repos."
            return
        }

        // Interpret whatever the user typed: GitHub URL ➜ pr-N/issue-N
        // (plus repo auto-switch), bare number ➜ pr-N, otherwise pass-
        // through. The interpretation drives both the branch name and
        // whether we treat this as a PR session (skip agent prefix, use
        // refs/pull/N/head as base) or a free-form session.
        let interpretation = Self.interpretBranchInput(branchName)
        let userBranch = interpretation.branch
        let parsedNumber = Self.parsePRNumber(userBranch)
        // PR sessions use the literal `pr-N` / `issue-N` branch — no
        // agent prefix — so the local branch matches the PR and a follow-up
        // `git push` reaches the right ref. Multi-agent parallelism stays
        // available for free-form branches (still gets the agent prefix).
        let agentSlug = TaskPickerMode.agentSlug(agent.name)
        let finalBranch: String = {
            if parsedNumber != nil { return userBranch }
            if !agentSlug.isEmpty,
               !userBranch.lowercased().hasPrefix(agentSlug.lowercased() + "-") {
                return "\(agentSlug)-\(userBranch)"
            }
            return userBranch
        }()
        // For PR-identified inputs, point WorktreeManager at the PR head
        // ref so it does `git fetch origin pull/N/head:<branch>` before
        // creating the worktree. WorktreeManager spots this prefix and
        // takes the fetch path. (For issue-N this isn't a thing, so we
        // skip.)
        let trimmedBase = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseFromInput = parsedNumber.flatMap { number -> String? in
            userBranch.lowercased().hasPrefix("pr-") ? "refs/pull/\(number)/head" : nil
        }
        let effectiveBase = baseFromInput ?? (trimmedBase.isEmpty ? nil : trimmedBase)
        do {
            let worktreeURL = try await services.worktreeManager.ensure(
                repo: repo, branch: finalBranch, baseRef: effectiveBase
            )
            // Match the branch against PR/issue patterns ("pr-643", "#643") so the
            // GitHub pane has a task to render. Falls back to nil (= no task link)
            // for free-form branch names like "feat/foo".
            let resolvedTaskID = Self.resolveTaskID(
                forBranch: finalBranch,
                repoID: repoID,
                database: services.database
            )
            let newTab = try services.tabStore.insert(
                branchName: finalBranch,
                worktreePath: worktreeURL.path,
                agentID: agent.id,
                taskID: resolvedTaskID
            )
            services.tabs.reload()
            if let tabID = newTab.id {
                services.tabs.select(tabID)
                services.sessions.add(
                    OpenSession(
                        id: tabID,
                        displayName: "\(agent.name) · \(finalBranch)",
                        cwd: worktreeURL.path,
                        command: agent.command,
                        args: agent.args,
                        env: agent.env
                    )
                )
            }
            services.triggerSyncNow()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }

    /// If the selected repo has no valid local clone, prompt the user to clone
    /// it (or pick an existing folder) and persist the resulting path. Returns
    /// `false` when the user cancels or the clone fails so `confirm()` aborts.
    /// A no-op returning `true` when the repo is already cloned.
    private func ensureRepoCloned(_ repo: Repo) async -> Bool {
        guard repo.localMainPath == nil || !RepoPrefsPane.isValidGitRepo(repo.localMainPath ?? "") else {
            return true
        }
        let parentDir = Self.inferCloneParent(from: repos)
        let defaultTarget = (parentDir as NSString).appendingPathComponent(repo.name)
        let alert = NSAlert()
        alert.messageText = "\"\(repo.fullName)\" is not cloned locally."
        alert.informativeText = "Clone it to \(defaultTarget)?"
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return false }

        var cloneTarget = defaultTarget
        if response == .alertSecondButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose a folder to clone \(repo.fullName) into. A \"\(repo.name)\" subfolder will be created."
            panel.prompt = "Clone Here"
            panel.directoryURL = URL(fileURLWithPath: parentDir, isDirectory: true)
            guard panel.runModal() == .OK, let pickedURL = panel.url else { return false }
            cloneTarget = pickedURL.appendingPathComponent(repo.name).path
        }

        if RepoPrefsPane.isValidGitRepo(cloneTarget) {
            await persistClonePath(cloneTarget, repoID: repo.id ?? 0)
            return true
        }
        if FileManager.default.fileExists(atPath: cloneTarget) {
            error = "\(cloneTarget) already exists but is not a git repository. Remove it or set the path manually in Settings > Repos."
            return false
        }

        cloning = true
        defer { cloning = false }
        do {
            try await GitHubCloner().clone(owner: repo.owner, name: repo.name, to: cloneTarget)
            await persistClonePath(cloneTarget, repoID: repo.id ?? 0)
            return true
        } catch {
            YggdrasilLog.ui
                .error(
                    "Clone failed for \(repo.fullName, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            self.error = "Could not clone \(repo.fullName). Check your network connection and that you're signed in with gh, then try again."
            return false
        }
    }

    /// Persist a repo's local clone path and refresh the in-memory `repos`.
    private func persistClonePath(_ path: String, repoID: Int64) async {
        try? await services.database.queue.write { db in
            try db.execute(
                sql: "UPDATE repo SET local_main_path = ? WHERE id = ?",
                arguments: [path, repoID]
            )
        }
        repos = await (try? services.database.queue.read { db in try Repo.fetchAll(db) }) ?? repos
    }

    /// Extracts a PR/issue number from a branch name like "pr-643" or "#643",
    /// then looks up that task in the given repo. Returns nil for branches that
    /// don't look like PR refs, or when no matching task row exists yet (the
    /// sync may not have caught the PR in question).
    static func resolveTaskID(
        forBranch branch: String,
        repoID: Int64,
        database: YggdrasilDatabase
    ) -> Int64? {
        guard let number = parsePRNumber(branch) else { return nil }
        return try? database.queue.read { db in
            try YggdrasilTask
                .filter(Column("repo_id") == repoID && Column("number") == number)
                .fetchOne(db)?
                .id
        }
    }

    static func parsePRNumber(_ branch: String) -> Int? {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#"), let number = Int(trimmed.dropFirst()) { return number }
        // Scan for one of the known core prefixes anywhere in the string —
        // tolerates an agent slug at the front (e.g. "claude-pr-643") so
        // parallel-agent worktrees still link back to the right task.
        // Order matters: longer prefixes first so "review-pr-643" doesn't
        // match "pr-" before the "review-" anchor. The trailing separator-
        // less variants ("pr", "issue") catch legacy branches typed without
        // the hyphen (e.g. "claude-pr828") so their sidebar #xxx badge
        // still appears.
        let cores = ["review-pr-", "review-pr/", "review-issue-", "review-issue/",
                     "pr-", "pr/", "issue-", "issue/",
                     "review-pr", "review-issue", "pr", "issue"]
        let lower = trimmed.lowercased()
        for core in cores {
            guard let range = lower.range(of: core) else { continue }
            // Accept only if the match is at the start OR preceded by '-'.
            guard range.lowerBound == lower.startIndex
                || lower[lower.index(before: range.lowerBound)] == "-"
            else { continue }
            let tail = lower[range.upperBound...]
            // Must be all digits (separator-less form: "pr828") OR a
            // separator already consumed by an earlier core. `Int(tail)`
            // by itself accepts a leading minus, so guard against that.
            guard !tail.isEmpty, tail.first?.isNumber == true,
                  let number = Int(tail) else { continue }
            return number
        }
        return nil
    }

    static func inferCloneParent(from repos: [Repo]) -> String {
        let parents = repos.compactMap(\.localMainPath)
            .map { ($0 as NSString).deletingLastPathComponent }
        let counts = Dictionary(grouping: parents, by: { $0 }).mapValues(\.count)
        if let mostCommon = counts.max(by: { $0.value < $1.value })?.key {
            return mostCommon
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Result of interpreting whatever the user typed in the New Session
    /// branch field: branch name to use + (when the input named a specific
    /// repo, e.g. a GitHub URL) the repo's `<owner>/<name>` for picker
    /// auto-select.
    struct BranchInterpretation: Equatable {
        let branch: String
        /// `<owner>/<name>` if the input identified a specific repo
        /// (currently only GitHub URLs do).
        let repoSlug: String?
    }

    /// Normalize whatever the user typed in the New Session branch field
    /// into a canonical branch name.
    ///
    /// Accepts:
    ///   • A GitHub URL — `https://github.com/<owner>/<repo>/pull/643` or
    ///     `…/issues/12` — returns `pr-643` / `issue-12` plus the repo slug
    ///     so the picker can auto-switch to the matching tracked repo.
    ///   • A bare number — `643` — interpreted as a PR by default, returns
    ///     `pr-643`.
    ///   • A `#N` shorthand — returns `pr-N` (we don't know without context
    ///     whether `#` means issue or PR; PR is the safer default).
    ///   • Anything else (existing branch names like `pr-643`, `feat/foo`,
    ///     `review-pr-948`) — passed through untouched.
    static func interpretBranchInput(_ raw: String) -> BranchInterpretation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // GitHub URL
        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host == "github.com" || host.hasSuffix(".github.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            // ["<owner>", "<repo>", "pull"|"issues", "<N>", ...]
            if parts.count >= 4,
               let number = Int(parts[3]),
               parts[2] == "pull" || parts[2] == "issues" {
                let kind = parts[2] == "pull" ? "pr" : "issue"
                return BranchInterpretation(
                    branch: "\(kind)-\(number)",
                    repoSlug: "\(parts[0])/\(parts[1])"
                )
            }
        }

        // Bare number (with optional leading '#'). Default to PR.
        let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if !stripped.isEmpty, stripped.allSatisfy(\.isNumber), let number = Int(stripped) {
            return BranchInterpretation(branch: "pr-\(number)", repoSlug: nil)
        }

        // Separator-less shorthand: "pr828", "issue7", "review-pr12" — insert
        // the missing hyphen so downstream code (parsePRNumber, the
        // refs/pull/N/head fetch path in confirm()) treats it as a real PR
        // reference instead of a free-form branch off `main`.
        if let normalised = normaliseSeparatorlessShorthand(trimmed) {
            return BranchInterpretation(branch: normalised, repoSlug: nil)
        }

        return BranchInterpretation(branch: trimmed, repoSlug: nil)
    }

    /// Insert the missing hyphen in `pr<N>` / `issue<N>` / `review-pr<N>` /
    /// `review-issue<N>`. Returns nil for anything else (so the original
    /// string is passed through unchanged). The full-string anchor on the
    /// regex is what stops `prerelease` or `pr-828-fix` from being mangled.
    static func normaliseSeparatorlessShorthand(_ input: String) -> String? {
        let pattern = #"^(pr|issue|review-pr|review-issue)(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = regex.firstMatch(in: input, range: range),
              match.numberOfRanges == 3,
              let kindRange = Range(match.range(at: 1), in: input),
              let numberRange = Range(match.range(at: 2), in: input)
        else { return nil }
        return "\(input[kindRange].lowercased())-\(input[numberRange])"
    }

    /// True if the branch was created via the review-picker flow. Looks
    /// for "review-" anywhere — covers both the original `review-pr-N`
    /// and the agent-prefixed `<agent>-review-pr-N`.
    static func isReviewBranch(_ branch: String) -> Bool {
        branch.lowercased().contains("review-")
    }
}

/// One card in the agent row.
private struct AgentCard: View {
    let agent: CodingAgent
    let isSelected: Bool
    let scheme: ColorScheme

    private var identity: AgentIdentity {
        AgentIdentity.detect(command: agent.command)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentBadge(agent: identity, statusIcon: nil, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YggdrasilTheme.text(scheme))
                    Text(identity.label)
                        .font(.system(size: 10))
                        .foregroundStyle(YggdrasilTheme.textMute(scheme))
                }
                Spacer()
                if agent.isDefault {
                    Text("DEFAULT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(YggdrasilTheme.accent)
                        .background(
                            Capsule().fill(YggdrasilTheme.accentSoft(scheme))
                        )
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.command)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(YggdrasilTheme.text(scheme))
                if !agent.args.isEmpty {
                    Text(agent.args.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(YggdrasilTheme.textDim(scheme))
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(width: 240, height: 110, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(YggdrasilTheme.bgPaneSoft(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected
                        ? YggdrasilTheme.accent
                        : YggdrasilTheme.border(scheme),
                    lineWidth: isSelected ? 1.2 : 0.5
                )
        )
        .shadow(
            color: isSelected ? YggdrasilTheme.accent.opacity(0.15) : .clear,
            radius: 6, x: 0, y: 2
        )
    }
}

// swiftlint:enable file_length type_body_length
