import SwiftUI

/// Full CRUD over coding-agent profiles.
struct AgentPrefsPane: View {
    let services: AppServices

    @State private var agents: [CodingAgent] = []
    @State private var selectedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding Agents").font(.title3).bold()
            Text("Each tab spawns one of these. The default is used unless you pick another when starting a session.")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                List(selection: $selectedID) {
                    ForEach(agents, id: \.id) { agent in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(agent.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(agent.command) \(agent.args.joined(separator: " "))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if agent.isDefault {
                                Text("default")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        .tag(agent.id)
                    }
                }
                .frame(minWidth: 280)

                if let agent = agents.first(where: { $0.id == selectedID }) {
                    agentEditor(agent)
                } else {
                    Text("Select an agent on the left, or use + to add one.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            HStack {
                Button { addAgent() } label: { Image(systemName: "plus") }
                    .help("Add agent")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                    .help("Remove agent")
                Spacer()
                if let id = selectedID,
                   let agent = agents.first(where: { $0.id == id }),
                   !agent.isDefault {
                    Button("Make Default") { setDefault(id: id) }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func agentEditor(_ agent: CodingAgent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit").font(.system(size: 13, weight: .semibold))
            EditableField(
                label: "Name", value: agent.name,
                placeholder: "Display name"
            ) { newValue in
                update(id: agent.id ?? 0, name: newValue)
            }
            EditableField(
                label: "Command", value: agent.command,
                placeholder: "/path/to/binary"
            ) { newValue in
                update(id: agent.id ?? 0, command: newValue)
            }
            EditableField(
                label: "Args", value: agent.args.joined(separator: " "),
                placeholder: "space-separated"
            ) { newValue in
                update(id: agent.id ?? 0, args: newValue.split(separator: " ").map(String.init))
            }
            EditableEnvironment(env: agent.env) { newEnv in
                update(id: agent.id ?? 0, env: newEnv)
            }
            Spacer()
        }
        .padding(.leading, 8)
        // Identity per agent: the sub-editors hold the in-progress text in
        // @State, and without this a draft typed against one profile survives
        // the switch to another and gets applied to it.
        .id(agent.id)
    }

    // MARK: - Actions

    private func reload() {
        do { agents = try services.agentStore.list() } catch {
            YggdrasilLog.ui.error("AgentPrefsPane reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func addAgent() {
        guard let details = DebugMenu.promptForAgentDetails() else { return }
        do {
            _ = try services.agentStore.add(
                name: details.name, command: details.command, args: details.args
            )
            reload()
        } catch {
            NSAlert.show("Add agent failed", message: String(describing: error))
        }
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        do {
            try services.agentStore.remove(id: id)
            selectedID = nil
            reload()
        } catch {
            NSAlert.show("Remove failed", message: String(describing: error))
        }
    }

    private func setDefault(id: Int64) {
        do {
            try services.agentStore.setDefault(id: id)
            reload()
        } catch {
            NSAlert.show("Set default failed", message: String(describing: error))
        }
    }

    private func update(
        id: Int64, name: String? = nil, command: String? = nil,
        args: [String]? = nil, env: [String: String]? = nil
    ) {
        do {
            try services.agentStore.update(id: id, name: name, command: command, args: args, env: env)
            reload()
        } catch {
            NSAlert.show("Update failed", message: String(describing: error))
        }
    }
}

/// Self-contained "label + text field" row that fires a callback when the
/// user commits (loses focus / presses enter).
private struct EditableField: View {
    let label: String
    let value: String
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .semibold))
            TextField(placeholder, text: $draft, onCommit: { onCommit(draft) })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
        .onAppear {
            if !loaded { draft = value
                loaded = true
            }
        }
        .onChange(of: value) { _, newValue in
            draft = newValue
        }
    }
}

/// Multi-line `KEY=VALUE` editor for the agent's environment (issue #47).
/// `TextEditor` has no commit event of its own, so the save is an explicit
/// button — enabled only while the text differs from what's stored.
private struct EditableEnvironment: View {
    let env: [String: String]
    let onCommit: ([String: String]) -> Void

    @State private var draft: String = ""
    @State private var loaded = false

    /// What the stored environment looks like in the editor. `parse` is lossy
    /// (comments and ordering don't survive, unusable lines are dropped), so
    /// this — not the raw draft — is what "unchanged" means.
    private var rendered: String {
        AgentEnvironment.render(env)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Environment").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Apply") { apply() }
                    .controlSize(.small)
                    .disabled(draft == rendered)
            }
            TextEditor(text: $draft)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 66)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                )
            Text(
                """
                One KEY=VALUE per line, stored unencrypted in the app database. \
                Your shell's rc files run after these and can override them.
                """
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            if !loaded {
                draft = rendered
                loaded = true
            }
        }
        .onChange(of: rendered) { _, newValue in
            draft = newValue
        }
    }

    /// Commits, then snaps the editor back to what was actually kept. Without
    /// this an edit that parses to the stored value — a comment-only line, a
    /// reorder, an unusable line — leaves Apply enabled forever on text that was
    /// silently discarded.
    private func apply() {
        let parsed = AgentEnvironment.parse(draft)
        onCommit(parsed)
        draft = AgentEnvironment.render(parsed)
    }
}
