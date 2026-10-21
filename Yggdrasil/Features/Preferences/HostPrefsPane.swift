import SwiftUI

/// Settings → Hosts: ssh machines tabs can run on, and where each repo's
/// single checkout lives on them. "Check Connection" runs the host preflight,
/// which also installs or updates the `ygg` helper there.
struct HostPrefsPane: View {
    let services: AppServices

    private enum CheckState: Equatable {
        case checking
        case ready(helperInstalled: Bool)
        case missing([String])
        case failed(String)
    }

    @State private var hosts: [RemoteHost] = []
    @State private var selectedID: Int64?
    @State private var checkouts: [HostRepoCheckout] = []
    @State private var checks: [Int64: CheckState] = [:]
    @State private var adding = false
    @State private var newName = ""
    @State private var newTarget = ""
    @State private var newRoot = ""

    /// `selectedID` preselects a row (used by the settings snapshots).
    init(services: AppServices, selectedID: Int64? = nil) {
        self.services = services
        _selectedID = State(initialValue: selectedID)
    }

    var body: some View {
        SettingsListDetail {
            SettingsSourceList(
                canRemove: selectedID != nil,
                addHelp: "Add a host",
                removeHelp: "Remove the selected host",
                onAdd: {
                    newName = ""
                    newTarget = ""
                    newRoot = ""
                    adding = true
                },
                onRemove: removeSelected,
                content: {
                    // PersistedRow, not the records: List's selection needs a
                    // non-optional id (see PersistedRow).
                    List(PersistedRow.rows(from: hosts, by: \.id), selection: $selectedID) { row in
                        let host = row.value
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                            Text(host.sshTarget).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            )
        } detail: {
            if let host = selectedHost {
                detail(host)
            } else {
                SettingsEmptyDetail(
                    symbol: "server.rack",
                    message: """
                    Agents on a host keep running when Yggdrasil quits or the connection drops. \
                    Connections use /usr/bin/ssh with your ~/.ssh/config and ssh agent.
                    """
                )
            }
        }
        .sheet(isPresented: $adding) {
            SettingsAddSheet(
                title: "Add Host",
                confirmTitle: "Add",
                canConfirm: ![newName, newTarget, newRoot]
                    .contains { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                onConfirm: addHost
            ) {
                TextField("Name", text: $newName, prompt: Text("Dev server"))
                TextField("SSH target", text: $newTarget, prompt: Text("alias or user@host"))
                TextField("Repos folder", text: $newRoot, prompt: Text("/home/me/src"))
            }
        }
        .onAppear(perform: reload)
        .onChange(of: selectedID) { _, _ in reloadCheckouts() }
    }

    private var selectedHost: RemoteHost? {
        hosts.first { $0.id == selectedID }
    }

    // MARK: - Detail

    private func detail(_ host: RemoteHost) -> some View {
        Form {
            Section {
                SettingsTextField(title: "Name", prompt: "Display name", value: host.name) { name in
                    update(host, name: name)
                }
                SettingsTextField(
                    title: "SSH target", prompt: "alias or user@host", value: host.sshTarget
                ) { target in
                    update(host, sshTarget: target)
                }
                SettingsTextField(
                    title: "Repos folder", prompt: "/home/me/src", value: host.reposRoot
                ) { root in
                    update(host, reposRoot: root)
                }
            } footer: {
                Text("Repositories are cloned to <repos folder>/<owner>/<name> the first time a tab uses them here.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") { statusView(for: host) }
                HStack {
                    Spacer()
                    Button("Check Connection") { check(host) }
                        .disabled(checks[host.id ?? -1] == .checking)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Checks that claude, git, gh and dtach are installed and installs the Yggdrasil helper.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if checkouts.isEmpty {
                    Text("No repositories have been used on this host yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(checkouts, id: \.repo.id) { checkout in
                    SettingsTextField(
                        title: checkout.repo.fullName, prompt: "/path/to/checkout", value: checkout.path
                    ) { path in
                        setCheckout(host, repo: checkout.repo, path: path)
                    }
                }
            } header: {
                Text("Checkouts")
            } footer: {
                Text("""
                Each repository has one checkout per host; every tab works in its own worktree under it. \
                A checkout can't move while tabs use it.
                """)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Fresh field drafts per host, so text typed for one isn't saved to
        // the next one selected.
        .id(host.id)
    }

    @ViewBuilder
    private func statusView(for host: RemoteHost) -> some View {
        switch checks[host.id ?? -1] {
        case nil:
            Text("Not checked").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case let .ready(helperInstalled):
            Label(helperInstalled ? "Ready (helper installed)" : "Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .missing(tools):
            Label("Missing \(tools.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        }
    }

    // MARK: - Actions

    private func reload() {
        do { hosts = try services.hostStore.list() } catch {
            YggdrasilLog.ui.error("HostPrefsPane reload failed: \(String(describing: error), privacy: .public)")
        }
        reloadCheckouts()
    }

    private func reloadCheckouts() {
        guard let id = selectedID else {
            checkouts = []
            return
        }
        checkouts = (try? services.hostRepoStore.list(hostID: id)) ?? []
    }

    private func addHost() {
        do {
            let host = try services.hostStore.add(
                name: newName.trimmingCharacters(in: .whitespaces),
                sshTarget: newTarget.trimmingCharacters(in: .whitespaces),
                reposRoot: newRoot.trimmingCharacters(in: .whitespaces)
            )
            reload()
            selectedID = host.id
            check(host)
        } catch {
            NSAlert.show("Couldn't add the host", message: Self.describe(error))
        }
    }

    private func removeSelected() {
        guard let host = selectedHost, let id = host.id else { return }
        do {
            try services.hostStore.remove(id: id)
            if services.defaultHostID == id { services.defaultHostID = nil }
            selectedID = nil
            reload()
        } catch {
            NSAlert.show("Couldn't remove \(host.name)", message: Self.describe(error))
        }
    }

    private func update(
        _ host: RemoteHost, name: String? = nil, sshTarget: String? = nil, reposRoot: String? = nil
    ) -> Bool {
        guard let id = host.id else { return false }
        do {
            try services.hostStore.update(
                id: id,
                name: name ?? host.name,
                sshTarget: sshTarget ?? host.sshTarget,
                reposRoot: reposRoot ?? host.reposRoot
            )
            // The last check was for the old settings.
            checks[id] = nil
            reload()
            return true
        } catch {
            NSAlert.show("Couldn't save \(host.name)", message: Self.describe(error))
            return false
        }
    }

    private func setCheckout(_ host: RemoteHost, repo: Repo, path: String) -> Bool {
        do {
            try services.hostRepoStore.setCheckoutPath(host: host, repo: repo, path: path)
            reloadCheckouts()
            return true
        } catch {
            NSAlert.show("Couldn't move the checkout", message: Self.describe(error))
            return false
        }
    }

    private func check(_ host: RemoteHost) {
        guard let id = host.id else { return }
        checks[id] = .checking
        Task { @MainActor in
            do {
                let report = try await services.remoteControl.preflight(host: host)
                checks[id] = report.isReady
                    ? .ready(helperInstalled: report.helperInstalled)
                    : .missing(report.missingTools)
            } catch let RemoteSessionControl.Failure.ssh(_, stderr) {
                checks[id] = .failed(stderr.isEmpty ? "Couldn't connect" : stderr)
            } catch {
                checks[id] = .failed(String(describing: error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let HostStoreError.invalidSSHTarget(target):
            "“\(target)” isn't a valid ssh target. Use a ~/.ssh/config alias or user@host."
        case let HostStoreError.reposRootNotAbsolute(root),
             let HostRepoStoreError.notAbsolute(root):
            "“\(root)” must be an absolute path, like /home/me/src."
        case HostStoreError.hostInUse:
            "Tabs still run on this host. Move or remove them first; its SSH target can't change while they exist."
        case let HostRepoStoreError.pathTaken(path, repo):
            "\(repo) already has its checkout at \(path) on this host."
        case let HostRepoStoreError.inUse(path):
            "Tabs still have worktrees under \(path). Remove them first."
        default:
            String(describing: error)
        }
    }
}
