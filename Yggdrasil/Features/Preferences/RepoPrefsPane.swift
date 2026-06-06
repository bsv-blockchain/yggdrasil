import AppKit
import GRDB
import SwiftUI

/// Manages the tracked-repo list and each row's local clone path. The local
/// path is required for worktree creation and diff computation — Phase 1+ left
/// this read-only via SQL; Phase 8 surfaces it in the UI.
struct RepoPrefsPane: View {
    let services: AppServices

    @State private var repos: [Repo] = []
    @State private var selectedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tracked Repos").font(.title3).bold()
            Text("Yggdrasil syncs assigned issues + PRs from these repos.")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                List(selection: $selectedID) {
                    ForEach(repos, id: \.id) { repo in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repo.fullName).font(.system(size: 12, weight: .semibold))
                            Text(repo.localMainPath ?? "(no local path set)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(repo.id)
                    }
                }
                .frame(minWidth: 280)

                if let selected = repos.first(where: { $0.id == selectedID }) {
                    repoDetail(selected)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    placeholder
                        .frame(maxWidth: .infinity)
                }
            }

            HStack {
                Button {
                    addRepo()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add repo")

                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedID == nil)
                .help("Remove repo")

                Spacer()
            }
        }
        .onAppear(perform: reload)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("Pick a repo to edit its local clone path.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func repoDetail(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(repo.fullName).font(.system(size: 14, weight: .semibold))
            Text("Default branch: \(repo.defaultBranch)")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Local clone path").font(.system(size: 11, weight: .semibold))
                HStack {
                    Text(repo.localMainPath ?? "(unset)")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Button("Choose…") { pickPath(for: repo) }
                }
                Text("Used by Phase 2's WorktreeManager and Phase 7's diff view.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 8)
    }

    // MARK: - Actions

    private func reload() {
        do {
            repos = try services.database.queue.read { db in try Repo.fetchAll(db) }
        } catch {
            YggdrasilLog.ui.error("RepoPrefsPane reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func addRepo() {
        guard let (owner, name) = DebugMenu.promptForOwnerAndName() else { return }
        Task {
            let branch = (try? await services.restClient.defaultBranch(owner: owner, name: name)) ?? "main"
            do {
                try await services.database.queue.write { db in
                    var repo = Repo(
                        id: nil, owner: owner, name: name,
                        defaultBranch: branch, localMainPath: nil, addedAt: Date()
                    )
                    try repo.insert(db)
                }
                await MainActor.run { reload() }
            } catch {
                NSAlert.show("Add repo failed", message: String(describing: error))
            }
        }
    }

    private func removeSelected() {
        guard let id = selectedID,
              let repo = repos.first(where: { $0.id == id }) else { return }
        do {
            try services.database.queue.write { db in try repo.delete(db) }
            selectedID = nil
            reload()
        } catch {
            NSAlert.show("Remove failed", message: String(describing: error))
        }
    }

    private func pickPath(for repo: Repo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the local clone of \(repo.fullName)"
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try services.database.queue.write { db in
                try db.execute(
                    sql: "UPDATE repo SET local_main_path = ? WHERE id = ?",
                    arguments: [url.path, repo.id ?? 0]
                )
            }
            reload()
        } catch {
            NSAlert.show("Save path failed", message: String(describing: error))
        }
    }
}

extension NSAlert {
    static func show(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
