import GRDB
import SwiftUI

/// "+" sheet shown from the sidebar. User picks a tracked repo, types a branch
/// name, and picks a coding agent. On confirm: WorktreeManager.ensure(...) →
/// TabStore.insert → SessionsModel.add → spawn happens automatically via
/// AgentTerminalSurface mounting.
struct NewTabSheet: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [Repo] = []
    @State private var agents: [CodingAgent] = []
    @State private var selectedRepoID: Int64?
    @State private var selectedAgentID: Int64?
    @State private var branchName: String = ""
    @State private var inProgress: Bool = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tab").font(.title2).bold()

            row(label: "Repo") {
                Picker("", selection: $selectedRepoID) {
                    ForEach(repos, id: \.id) { repo in
                        Text(repo.fullName).tag(repo.id)
                    }
                }
                .labelsHidden()
            }

            row(label: "Branch") {
                TextField("e.g. feat/something or pr-655", text: $branchName)
                    .textFieldStyle(.roundedBorder)
            }

            row(label: "Agent") {
                Picker("", selection: $selectedAgentID) {
                    ForEach(agents, id: \.id) { agent in
                        Text("\(agent.name) (\(agent.command))").tag(agent.id)
                    }
                }
                .labelsHidden()
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("newtab.error")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Tab") { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
        .accessibilityIdentifier("sidebar.newtab.sheet")
    }

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
        }
    }

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

        // The repo's local clone path is set by the user out of band (Phase 1+).
        // If it's nil, we can't create a worktree — surface a clear error.
        guard repo.localMainPath != nil else {
            error = "Repo \(repo.fullName) has no local clone path on disk; add it via the database or a future Preferences UI."
            return
        }

        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Create or discover the worktree.
            let worktreeURL = try await services.worktreeManager.ensure(
                repo: repo, branch: trimmedBranch, baseRef: nil
            )

            // Insert tab row and refresh the sidebar.
            let newTab = try services.tabStore.insert(
                branchName: trimmedBranch,
                worktreePath: worktreeURL.path,
                agentID: agent.id,
                taskID: nil
            )
            services.tabs.reload()

            // Spawn the session.
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
}
