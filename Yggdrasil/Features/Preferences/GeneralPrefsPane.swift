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
        .frame(width: 520, height: 560)
        .onChange(of: theme) { _, mode in AppearanceSettings.apply(mode: mode, services: services) }
        .onChange(of: terminalTheme) { _, mode in AppearanceSettings.terminalTheme = mode }
        .onChange(of: groupByRepo) { _, value in AppearanceSettings.persistGroupByRepo(value, services: services) }
        .onChange(of: defaultHostID) { _, id in services.defaultHostID = id }
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

    /// Applies once the stepper has been still for a moment: every apply
    /// rebuilds the scheduler, which syncs GitHub immediately.
    private func applyIntervals() {
        pendingApply?.cancel()
        let new = IntervalSettings(syncSeconds: syncSeconds, statusProbeSeconds: statusProbeSeconds)
        pendingApply = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await services.applyIntervals(new)
        }
    }
}
