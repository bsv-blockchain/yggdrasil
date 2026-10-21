import AppKit
import GRDB
import SwiftUI

/// Settings → Repositories: the tracked repos and each one's local clone. The
/// local clone is where local tabs get their worktrees; checkouts on remote
/// hosts are managed under Hosts.
struct RepoPrefsPane: View {
    let services: AppServices

    @State private var repos: [Repo] = []
    @State private var selectedID: Int64?
    @State private var cloning = false
    @State private var adding = false
    @State private var newRepoSlug = ""

    /// `selectedID` preselects a row (used by the settings snapshots).
    init(services: AppServices, selectedID: Int64? = nil) {
        self.services = services
        _selectedID = State(initialValue: selectedID)
    }

    var body: some View {
        SettingsListDetail {
            SettingsSourceList(
                canRemove: selectedID != nil,
                addHelp: "Track a repository",
                removeHelp: "Stop tracking the selected repository",
                onAdd: {
                    newRepoSlug = ""
                    adding = true
                },
                onRemove: removeSelected,
                content: {
                    // PersistedRow, not the records: List's selection needs a
                    // non-optional id (see PersistedRow).
                    List(PersistedRow.rows(from: repos, by: \.id), selection: $selectedID) { row in
                        let repo = row.value
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.name)
                            Text(repo.owner).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            )
        } detail: {
            if let repo = repos.first(where: { $0.id == selectedID }) {
                detail(repo)
            } else {
                SettingsEmptyDetail(
                    symbol: "shippingbox",
                    message: "Yggdrasil syncs assigned issues and pull requests from tracked repositories."
                )
            }
        }
        .sheet(isPresented: $adding) {
            SettingsAddSheet(
                title: "Track Repository",
                confirmTitle: "Add",
                canConfirm: Self.parseSlug(newRepoSlug) != nil,
                onConfirm: addRepo
            ) {
                TextField("Repository", text: $newRepoSlug, prompt: Text("owner/name"))
            }
        }
        .onAppear(perform: reload)
    }

    private func detail(_ repo: Repo) -> some View {
        Form {
            Section {
                LabeledContent("Repository", value: repo.fullName)
                LabeledContent("Default branch", value: repo.defaultBranch)
            }

            Section {
                LabeledContent("Location") {
                    Text(repo.localMainPath ?? "Not set")
                        .foregroundStyle(repo.localMainPath == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let path = repo.localMainPath, !Self.isValidGitRepo(path) {
                    Label("This folder isn't a git checkout.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                HStack {
                    if cloning {
                        ProgressView().controlSize(.small)
                        Text("Cloning…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Folder…") { pickPath(for: repo) }
                    Button("Clone from GitHub…") { cloneRepo(repo) }
                        .disabled(cloning)
                }
            } header: {
                Text("Local Clone")
            } footer: {
                Text("Local tabs work in worktrees under this clone.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(repo.id)
    }

    static func isValidGitRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// "owner/name", or a github.com URL to one.
    static func parseSlug(_ raw: String) -> (owner: String, name: String)? {
        var slug = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where slug.hasPrefix(prefix) {
            slug = String(slug.dropFirst(prefix.count))
        }
        if slug.hasSuffix(".git") { slug = String(slug.dropLast(4)) }
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts.contains(where: { $0.contains(where: \.isWhitespace) })
        else { return nil }
        return (parts[0], parts[1])
    }

    // MARK: - Actions

    private func reload() {
        do {
            repos = try services.database.queue.read { db in
                try Repo.order(Column("owner").collating(.nocase), Column("name").collating(.nocase)).fetchAll(db)
            }
        } catch {
            YggdrasilLog.ui.error("RepoPrefsPane reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func addRepo() {
        guard let (owner, name) = Self.parseSlug(newRepoSlug) else { return }
        Task {
            let branch = await (try? services.restClient.defaultBranch(owner: owner, name: name)) ?? "main"
            do {
                let repo = try await services.database.queue.write { db in
                    var repo = Repo(
                        id: nil, owner: owner, name: name,
                        defaultBranch: branch, localMainPath: nil, addedAt: Date()
                    )
                    try repo.insert(db)
                    return repo
                }
                await MainActor.run {
                    reload()
                    selectedID = repo.id
                }
            } catch {
                NSAlert.show("Couldn't add \(owner)/\(name)", message: String(describing: error))
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
            NSAlert.show("Couldn't remove \(repo.fullName)", message: String(describing: error))
        }
    }

    private func cloneRepo(_ repo: Repo) {
        let defaultParent = URL(fileURLWithPath: NewTabSheet.inferCloneParent(from: repos), isDirectory: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to clone \(repo.fullName) into. A \"\(repo.name)\" subfolder will be created."
        panel.prompt = "Clone Here"
        panel.directoryURL = defaultParent
        guard panel.runModal() == .OK, let parentURL = panel.url else { return }
        let targetPath = parentURL.appendingPathComponent(repo.name).path

        if FileManager.default.fileExists(atPath: targetPath) {
            NSAlert.show("Folder already exists",
                         message: "\(repo.name) already exists in this location. Choose a different folder or remove it first.")
            return
        }

        cloning = true
        Task {
            defer { Task { @MainActor in cloning = false } }
            do {
                try await GitHubCloner().clone(owner: repo.owner, name: repo.name, to: targetPath)
                await MainActor.run { updateLocalPath(targetPath, for: repo) }
            } catch {
                YggdrasilLog.ui
                    .error(
                        "Clone failed for \(repo.fullName, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                await MainActor.run {
                    NSAlert.show("Clone failed",
                                 message: "Could not clone \(repo.fullName). Check your network connection and that you're signed in with gh, then try again.")
                }
            }
        }
    }

    private func updateLocalPath(_ path: String, for repo: Repo) {
        do {
            try services.database.queue.write { db in
                try db.execute(
                    sql: "UPDATE repo SET local_main_path = ? WHERE id = ?",
                    arguments: [path, repo.id ?? 0]
                )
            }
            reload()
        } catch {
            NSAlert.show("Couldn't save the location", message: String(describing: error))
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
        updateLocalPath(url.path, for: repo)
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
