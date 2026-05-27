import GRDB
import SwiftUI

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
    @State private var inProgress: Bool = false
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
        .frame(width: 640, height: 460)
        .background(YggdrasilTheme.bgPane(scheme))
        .onAppear(perform: load)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Branch")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(YggdrasilTheme.textMute(scheme))

            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                TextField("e.g. feat/something or pr-655", text: $branchName)
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
        }
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
        } catch {
            self.error = "Failed to load: \(error.localizedDescription)"
        }
    }

    private func confirm() async {
        guard let repoID = selectedRepoID,
              let agent = agents.first(where: { $0.id == selectedAgentID }),
              let repo = repos.first(where: { $0.id == repoID })
        else { return }

        inProgress = true
        error = nil
        defer { inProgress = false }

        guard repo.localMainPath != nil else {
            error = "Repo \(repo.fullName) has no local clone path on disk; set it in Preferences → Repos."
            return
        }

        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let worktreeURL = try await services.worktreeManager.ensure(
                repo: repo, branch: trimmedBranch, baseRef: nil
            )
            // Match the branch against PR/issue patterns ("pr-643", "#643") so the
            // GitHub pane has a task to render. Falls back to nil (= no task link)
            // for free-form branch names like "feat/foo".
            let resolvedTaskID = Self.resolveTaskID(
                forBranch: trimmedBranch,
                repoID: repoID,
                database: services.database
            )
            let newTab = try services.tabStore.insert(
                branchName: trimmedBranch,
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
                        displayName: "\(agent.name) · \(trimmedBranch)",
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
        let prefixes = ["pr-", "pr/", "issue-", "issue/"]
        for prefix in prefixes where trimmed.lowercased().hasPrefix(prefix) {
            if let number = Int(trimmed.dropFirst(prefix.count)) { return number }
        }
        return nil
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
