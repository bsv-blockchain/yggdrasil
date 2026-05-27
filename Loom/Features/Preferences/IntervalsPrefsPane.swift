import SwiftUI

/// Read-only display of the spec's polling intervals. Edits are Phase 8.5+;
/// for now the values are sourced from `SettingsStore` (overrideable via
/// `defaults write`) or fall back to the spec defaults.
struct IntervalsPrefsPane: View {
    let services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Refresh Intervals").font(.title3).bold()
            Text("Loom's polling cadence. Hardcoded in this build — a future release will surface sliders here.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                row(label: "GitHub sync", value: "60 s", note: "Assigned issues + PRs across all tracked repos")
                row(label: "Per-tab git probe", value: "5 s", note: "git status + ahead/behind")
                row(label: "Per-PR GraphQL", value: "60 s", note: "CI / mergeable / review (piggybacks on sync)")
                row(label: "BackoffRetry on sync failure", value: "1, 2, 4, 8, 16 s", note: "Then waits for next tick")
            }
            .padding(.top, 4)

            Spacer()
        }
    }

    private func row(label: String, value: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 200, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 110, alignment: .leading)
            Text(note).foregroundStyle(.tertiary).font(.callout)
        }
    }
}
