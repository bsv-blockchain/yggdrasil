import SwiftUI

/// Editable polling-interval pane. Changes are persisted to SettingsStore
/// and applied to the running schedulers immediately via
/// `AppServices.applyIntervals(_:)` — no relaunch needed.
struct IntervalsPrefsPane: View {
    let services: AppServices

    @State private var syncSeconds: Int = IntervalSettings.defaults.syncSeconds
    @State private var statusProbeSeconds: Int = IntervalSettings.defaults.statusProbeSeconds
    @State private var lastApplied: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Refresh Intervals").font(.title3).bold()
            Text(
                "How often Yggdrasil polls GitHub + the worktree. Lower = fresher pills, higher = lighter on API quota."
            )
            .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                intervalRow(
                    label: "GitHub sync",
                    value: $syncSeconds,
                    range: IntervalSettings.syncRange,
                    step: 5,
                    note: "Assigned issues + PRs + review-requested across all tracked repos."
                )
                intervalRow(
                    label: "Per-tab git probe",
                    value: $statusProbeSeconds,
                    range: IntervalSettings.statusProbeRange,
                    step: 1,
                    note: "git status + ahead/behind for the worktree of each open tab."
                )
            }

            HStack(spacing: 8) {
                Button("Reset to defaults") {
                    syncSeconds = IntervalSettings.defaults.syncSeconds
                    statusProbeSeconds = IntervalSettings.defaults.statusProbeSeconds
                    apply()
                }
                if let lastApplied {
                    Text("Applied \(Self.timeFormatter.string(from: lastApplied))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            Spacer()
        }
        .onAppear {
            syncSeconds = services.intervals.syncSeconds
            statusProbeSeconds = services.intervals.statusProbeSeconds
        }
    }

    private func intervalRow(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).frame(width: 180, alignment: .leading)
                Stepper(value: value, in: range, step: step) {
                    Text("\(value.wrappedValue) s")
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 60, alignment: .leading)
                }
                .onChange(of: value.wrappedValue) { _, _ in
                    apply()
                }
                Text("(\(range.lowerBound)–\(range.upperBound) s)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 180)
        }
    }

    private func apply() {
        let new = IntervalSettings(
            syncSeconds: syncSeconds,
            statusProbeSeconds: statusProbeSeconds
        )
        Task {
            await services.applyIntervals(new)
            lastApplied = Date()
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
