import AppKit
import SwiftUI

/// Settings → API: lets other programs on this Mac (Claude Code, Grok, shell
/// scripts) drive Yggdrasil, each with its own key.
struct APIPrefsPane: View {
    let services: AppServices
    let control: ControlService

    @State private var enabled: Bool
    @State private var loopback: Bool
    @State private var portText: String
    @State private var keys: [APIKey] = []
    @State private var adding = false
    @State private var newName = ""
    @State private var newScope: APIKey.Scope = .read
    @State private var shownSecret: String?

    init(services: AppServices, control: ControlService) {
        self.services = services
        self.control = control
        _enabled = State(initialValue: control.isEnabled)
        _loopback = State(initialValue: control.listensOnLoopback)
        _portText = State(initialValue: String(control.port))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow other apps to control Yggdrasil", isOn: $enabled)
                Toggle("Also listen on 127.0.0.1", isOn: $loopback)
                    .disabled(!enabled)
                LabeledContent("Port") {
                    TextField("Port", text: $portText, prompt: Text(String(ControlService.defaultPort)))
                        .labelsHidden()
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyPort)
                        .disabled(!enabled || !loopback)
                }
                LabeledContent("Status") {
                    Text(status).foregroundStyle(control.lastError == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Control API")
            } footer: {
                Text("""
                Programs reach it through a socket only your account can open, and every request needs \
                a key. 127.0.0.1 is for clients that can't use the socket: other accounts on this Mac \
                can reach that port too, and could take it over while Yggdrasil isn't listening.
                """)
                .foregroundStyle(.secondary)
            }

            Section {
                if keys.isEmpty {
                    Text("No keys yet.").foregroundStyle(.secondary)
                }
                ForEach(keys, id: \.id) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                            Text(detail(for: key)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { revoke(key) }
                    }
                }
                Button("New Key…") {
                    newName = ""
                    newScope = .read
                    adding = true
                }
            } header: {
                Text("Keys")
            } footer: {
                Text("""
                A full key can do anything you can, including typing into your agents, also ones \
                running without permission prompts. Give it only to programs you trust.
                """)
                .foregroundStyle(.secondary)
            }

            Section {
                command("Claude Code", """
                claude mcp add yggdrasil -e YGGDRASIL_API_KEY=<key> -- '\(yggctl)' mcp
                """)
                command("Grok CLI, or any MCP client", "Command '\(yggctl)' mcp, with YGGDRASIL_API_KEY set")
                command("Shell", """
                YGGDRASIL_API_KEY=<key> '\(yggctl)' tabs.list
                """)
                // Only while Yggdrasil holds the port: a key sent to it
                // otherwise could reach whoever took it.
                if loopback, let mcpURL {
                    command("MCP over HTTP", "URL \(mcpURL), header Authorization: Bearer <key>")
                }
            } header: {
                Text("Connect")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 600)
        .onAppear(perform: reload)
        .onChange(of: enabled) { _, value in control.isEnabled = value }
        .onChange(of: loopback) { _, value in control.listensOnLoopback = value }
        .sheet(isPresented: $adding) {
            SettingsAddSheet(
                title: "New API Key",
                confirmTitle: "Create",
                canConfirm: !newName.trimmingCharacters(in: .whitespaces).isEmpty,
                onConfirm: createKey
            ) {
                TextField("Name", text: $newName, prompt: Text("Claude Code"))
                Picker("Access", selection: $newScope) {
                    Text("Read only").tag(APIKey.Scope.read)
                    Text("Full").tag(APIKey.Scope.full)
                }
            }
        }
        .sheet(item: Binding(
            get: { shownSecret.map(Secret.init) },
            set: { shownSecret = $0?.value }
        )) { secret in
            SecretSheet(secret: secret.value)
        }
    }

    private struct Secret: Identifiable {
        let value: String
        var id: String {
            value
        }
    }

    /// The command-line client inside this app bundle.
    private var yggctl: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/yggctl").path
    }

    private var mcpURL: String? {
        control.boundPort.map { "http://127.0.0.1:\($0)/mcp" }
    }

    private var status: String {
        if let error = control.lastError {
            return control.isRunning ? "Listening on the socket. 127.0.0.1: \(error)" : error
        }
        guard control.isRunning else { return "Off" }
        return control.boundPort.map { "Listening on the socket and 127.0.0.1:\($0)" } ?? "Listening on the socket"
    }

    private func detail(for key: APIKey) -> String {
        let scope = key.scope == .full ? "Full" : "Read only"
        let used = key.lastUsedAt.map { "last used \($0.formatted(.relative(presentation: .named)))" } ?? "never used"
        return "\(scope) · \(used)"
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func reload() {
        keys = (try? control.keys.list()) ?? []
    }

    private func applyPort() {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
            portText = String(control.port)
            return
        }
        control.port = port
    }

    private func createKey() {
        do {
            let secret = try control.keys.create(name: newName, scope: newScope).secret
            reload()
            // After the add sheet has gone: one sheet at a time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { shownSecret = secret }
        } catch {
            NSAlert.show("Couldn't create the key", message: error.actionMessage)
        }
    }

    private func revoke(_ key: APIKey) {
        guard let id = key.id else { return }
        try? control.keys.revoke(id: id)
        reload()
    }
}

/// The new key, shown this once.
private struct SecretSheet: View {
    let secret: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy the new key").font(.headline)
            Text("It isn't shown again. Yggdrasil keeps only a hash of it.")
                .foregroundStyle(.secondary)
            Text(secret)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(secret, forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
