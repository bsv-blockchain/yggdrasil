import SwiftUI

/// Settings → Agents: the coding-agent profiles a tab can run.
struct AgentPrefsPane: View {
    let services: AppServices

    @State private var agents: [CodingAgent] = []
    @State private var selectedID: Int64?
    @State private var adding = false
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newArgs = ""

    /// `selectedID` preselects a row (used by the settings snapshots).
    init(services: AppServices, selectedID: Int64? = nil) {
        self.services = services
        _selectedID = State(initialValue: selectedID)
    }

    var body: some View {
        SettingsListDetail {
            SettingsSourceList(
                canRemove: selectedAgent.map { !$0.isDefault } ?? false,
                addHelp: "Add an agent",
                removeHelp: "Remove the selected agent",
                onAdd: {
                    newName = ""
                    newCommand = ""
                    newArgs = ""
                    adding = true
                },
                onRemove: removeSelected,
                content: {
                    // PersistedRow, not the records: List's selection needs a
                    // non-optional id (see PersistedRow).
                    List(PersistedRow.rows(from: agents, by: \.id), selection: $selectedID) { row in
                        let agent = row.value
                        HStack {
                            Text(agent.name)
                            Spacer()
                            if agent.isDefault {
                                Text("Default").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            )
        } detail: {
            if let agent = selectedAgent {
                detail(agent)
            } else {
                SettingsEmptyDetail(
                    symbol: "terminal",
                    message: "Each tab runs one of these agents. New tabs use the default one."
                )
            }
        }
        .sheet(isPresented: $adding) {
            SettingsAddSheet(
                title: "Add Agent",
                confirmTitle: "Add",
                canConfirm: !newName.trimmingCharacters(in: .whitespaces).isEmpty
                    && !newCommand.trimmingCharacters(in: .whitespaces).isEmpty,
                onConfirm: addAgent
            ) {
                TextField("Name", text: $newName, prompt: Text("Codex"))
                TextField("Command", text: $newCommand, prompt: Text("codex"))
                TextField("Arguments", text: $newArgs, prompt: Text("Optional"))
            }
        }
        .onAppear(perform: reload)
    }

    private var selectedAgent: CodingAgent? {
        agents.first { $0.id == selectedID }
    }

    private func detail(_ agent: CodingAgent) -> some View {
        Form {
            Section {
                SettingsTextField(title: "Name", prompt: "Display name", value: agent.name) { name in
                    update(agent, name: name)
                }
                SettingsTextField(title: "Command", prompt: "claude", value: agent.command) { command in
                    update(agent, command: command)
                }
                SettingsTextField(
                    title: "Arguments", prompt: "None", value: agent.args.joined(separator: " ")
                ) { args in
                    update(agent, args: args.split(separator: " ").map(String.init))
                }
            } footer: {
                Text("Arguments are separated by spaces.")
                    .foregroundStyle(.secondary)
            }

            Section {
                EnvironmentEditor(env: agent.env) { env in
                    _ = update(agent, env: env)
                }
            } header: {
                Text("Environment")
            } footer: {
                Text("""
                One KEY=VALUE per line, stored unencrypted in the app database. Your shell's rc files run \
                after these and can override them. Not passed to agents on remote hosts.
                """)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Default agent") {
                    if agent.isDefault {
                        Text("Yes").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { setDefault(agent) }
                    }
                }
            } footer: {
                Text("New tabs and task pickers start the default agent.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Identity per agent: the fields hold in-progress text in @State, and
        // without this a draft typed against one profile survives the switch
        // to another and gets applied to it.
        .id(agent.id)
    }

    // MARK: - Actions

    private func reload() {
        do { agents = try services.agentStore.list() } catch {
            YggdrasilLog.ui.error("AgentPrefsPane reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func addAgent() {
        let args = newArgs.split(separator: " ").map(String.init)
        do {
            let agent = try services.agentStore.add(
                name: newName.trimmingCharacters(in: .whitespaces),
                command: newCommand.trimmingCharacters(in: .whitespaces),
                args: args
            )
            reload()
            selectedID = agent.id
        } catch {
            NSAlert.show("Couldn't add the agent", message: String(describing: error))
        }
    }

    private func removeSelected() {
        guard let agent = selectedAgent, let id = agent.id, !agent.isDefault else { return }
        do {
            try services.agentStore.remove(id: id)
            selectedID = nil
            reload()
        } catch {
            NSAlert.show("Couldn't remove \(agent.name)", message: String(describing: error))
        }
    }

    private func setDefault(_ agent: CodingAgent) {
        guard let id = agent.id else { return }
        do {
            try services.agentStore.setDefault(id: id)
            reload()
        } catch {
            NSAlert.show("Couldn't change the default agent", message: String(describing: error))
        }
    }

    private func update(
        _ agent: CodingAgent, name: String? = nil, command: String? = nil, args: [String]? = nil,
        env: [String: String]? = nil
    ) -> Bool {
        guard let id = agent.id else { return false }
        guard name?.isEmpty != true, command?.isEmpty != true else { return false }
        do {
            try services.agentStore.update(id: id, name: name, command: command, args: args, env: env)
            reload()
            return true
        } catch {
            NSAlert.show("Couldn't save the agent", message: String(describing: error))
            return false
        }
    }
}

/// Multi-line `KEY=VALUE` editor for the agent's environment (issue #47).
/// `TextEditor` has no commit event of its own, so the save is an explicit
/// button — enabled only while the text differs from what's stored.
private struct EnvironmentEditor: View {
    let env: [String: String]
    let onCommit: ([String: String]) -> Void

    @State private var draft = ""

    /// What the stored environment looks like in the editor. `parse` is lossy
    /// (comments and ordering don't survive, unusable lines are dropped), so
    /// this — not the raw draft — is what "unchanged" means.
    private var rendered: String {
        AgentEnvironment.render(env)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minHeight: 72)
                .scrollContentBackground(.hidden)
            Button("Apply") { apply() }
                .disabled(draft == rendered)
        }
        .onAppear { draft = rendered }
        .onChange(of: rendered) { _, newValue in draft = newValue }
    }

    /// Commits, then snaps the editor back to what was actually kept, so text
    /// that parsed away (comments, reorders, unusable lines) doesn't leave
    /// Apply enabled forever.
    private func apply() {
        let parsed = AgentEnvironment.parse(draft)
        onCommit(parsed)
        draft = AgentEnvironment.render(parsed)
    }
}
