import SwiftUI

/// Settings → General: appearance, sidebar, where new tabs run, and refresh
/// intervals. Every control applies immediately, as in System Settings.
struct GeneralPrefsPane: View {
    let services: AppServices

    @State private var theme: AppearanceSettings.Mode
    @State private var terminalTheme: AppearanceSettings.TerminalTheme
    @State private var groupByRepo: Bool
    @State private var hosts: [RemoteHost]
    @State private var defaultHostID: Int64?
    @State private var syncSeconds: Int
    @State private var statusProbeSeconds: Int
    @State private var pendingApply: Task<Void, Never>?
    @State private var reviewPrompt: String
    @State private var issuePrompt: String

    /// State is read up front so the `onChange` handlers only see user edits.
    init(services: AppServices) {
        self.services = services
        let hosts = (try? services.hostStore.list()) ?? []
        _theme = State(initialValue: AppearanceSettings.readMode(services: services))
        _terminalTheme = State(initialValue: AppearanceSettings.terminalTheme)
        _groupByRepo = State(initialValue: AppearanceSettings.readGroupByRepo(services: services))
        _hosts = State(initialValue: hosts)
        _defaultHostID = State(initialValue: hosts.contains { $0.id == services.defaultHostID } ? services
            .defaultHostID : nil)
        _syncSeconds = State(initialValue: services.intervals.syncSeconds)
        _statusProbeSeconds = State(initialValue: services.intervals.statusProbeSeconds)
        _reviewPrompt = State(initialValue: SettingsActions.startingPrompt(.review, services: services))
        _issuePrompt = State(initialValue: SettingsActions.startingPrompt(.issue, services: services))
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppearanceSettings.Mode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Terminal", selection: $terminalTheme) {
                    ForEach(AppearanceSettings.TerminalTheme.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Sidebar") {
                Toggle("Group tabs by repository", isOn: $groupByRepo)
            }

            Section {
                Picker("Run new tabs on", selection: $defaultHostID) {
                    Text("This Mac").tag(Int64?.none)
                    ForEach(hosts, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(hosts.isEmpty)
            } header: {
                Text("New Tabs")
            } footer: {
                Text(hosts.isEmpty
                    ? "Add a remote host under Hosts to run agents on a server."
                    : "The New Session sheet can override this per tab.")
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingsTextField(title: "PR to review", prompt: "None", value: reviewPrompt) { template in
                    setStartingPrompt(.review, template)
                }
                SettingsTextField(title: "Issue", prompt: "None", value: issuePrompt) { template in
                    setStartingPrompt(.issue, template)
                }
            } header: {
                Text("Starting Prompts")
            } footer: {
                Text("""
                What Claude starts with in a new tab for a PR you're asked to review, or for an issue. \
                \(StartingPrompt.placeholders.joined(separator: ", ")) are filled in; empty sends nothing. \
                A repository can have its own under Repositories.
                """)
                .foregroundStyle(.secondary)
            }

            Section {
                intervalStepper("GitHub sync", value: $syncSeconds, range: IntervalSettings.syncRange, step: 5)
                intervalStepper(
                    "Git status", value: $statusProbeSeconds, range: IntervalSettings.statusProbeRange, step: 1
                )
            } header: {
                Text("Refresh")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Shorter intervals keep status fresher but use more GitHub API quota.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        syncSeconds = IntervalSettings.defaults.syncSeconds
                        statusProbeSeconds = IntervalSettings.defaults.statusProbeSeconds
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .onChange(of: theme) { _, mode in SettingsActions.setTheme(mode, services: services) }
        .onChange(of: terminalTheme) { _, mode in SettingsActions.setTerminalTheme(mode) }
        .onChange(of: groupByRepo) { _, value in SettingsActions.setGroupByRepo(value, services: services) }
        .onChange(of: defaultHostID) { _, id in try? SettingsActions.setDefaultHost(id: id, services: services) }
        .onChange(of: syncSeconds) { _, _ in applyIntervals() }
        .onChange(of: statusProbeSeconds) { _, _ in applyIntervals() }
        .onAppear {
            hosts = (try? services.hostStore.list()) ?? []
            // The default may have been removed under Hosts meanwhile.
            if let id = defaultHostID, !hosts.contains(where: { $0.id == id }) {
                defaultHostID = nil
            }
        }
    }

    private func intervalStepper(
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue) s").monospacedDigit()
                Stepper(title, value: value, in: range, step: step).labelsHidden()
            }
        }
    }

    private func setStartingPrompt(_ kind: StartingPrompt.Kind, _ template: String) -> Bool {
        do {
            try SettingsActions.setStartingPrompt(kind, template: template, services: services)
        } catch {
            return false
        }
        switch kind {
        case .review: reviewPrompt = template
        case .issue: issuePrompt = template
        }
        return true
    }

    /// Applies once the stepper has been still for a moment: every apply
    /// rebuilds the scheduler, which syncs GitHub immediately.
    private func applyIntervals() {
        pendingApply?.cancel()
        let (sync, status) = (syncSeconds, statusProbeSeconds)
        pendingApply = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await SettingsActions.setIntervals(syncSeconds: sync, statusProbeSeconds: status, services: services)
        }
    }
}
