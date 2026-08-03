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
                update(id: agent.id ?? 0, name: newValue, command: agent.command, args: agent.args, env: agent.env)
            }
            EditableField(
                label: "Command", value: agent.command,
                placeholder: "/path/to/binary"
            ) { newValue in
                update(id: agent.id ?? 0, name: agent.name, command: newValue, args: agent.args, env: agent.env)
            }
            EditableField(
                label: "Args", value: agent.args.joined(separator: " "),
                placeholder: "space-separated"
            ) { newValue in
                let parts = newValue.split(separator: " ").map(String.init)
                update(id: agent.id ?? 0, name: agent.name, command: agent.command, args: parts, env: agent.env)
            }
            EditableEnvironment(value: AgentEnvironment.render(agent.env)) { newValue in
                update(
                    id: agent.id ?? 0, name: agent.name, command: agent.command,
                    args: agent.args, env: AgentEnvironment.parse(newValue)
                )
            }
            Spacer()
        }
        .padding(.leading, 8)
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

    private func update(id: Int64, name: String, command: String, args: [String], env: [String: String]) {
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
    let value: String
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Environment").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Apply") { onCommit(draft) }
                    .controlSize(.small)
                    .disabled(draft == value)
            }
            TextEditor(text: $draft)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 66)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                )
            Text("One KEY=VALUE per line. Your shell's rc files run after these and can override them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if !loaded {
                draft = value
                loaded = true
            }
        }
        .onChange(of: value) { _, newValue in
            draft = newValue
        }
    }
}
