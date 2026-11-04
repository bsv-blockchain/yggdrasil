import SwiftUI

/// Compact "run on" picker for the task pickers: This Mac plus one chip per
/// configured host, next to `AgentChooser`. Hidden when no hosts are set up,
/// so the fast path for local-only users is unchanged.
///
/// Starts on Settings → General → "Run new tabs on". Before this the pickers
/// used that default silently, so opening one task on a server meant changing
/// the global default first.
struct HostChooser: View {
    let hosts: [RemoteHost]
    /// nil = this Mac.
    @Binding var selectedHostID: Int64?
    let scheme: ColorScheme

    var body: some View {
        if !hosts.isEmpty {
            HStack(spacing: 6) {
                Text("Run on")
                    .font(.system(size: 11))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
                chip("This Mac", symbol: "laptopcomputer", id: nil)
                ForEach(hosts, id: \.id) { host in
                    chip(host.name, symbol: "server.rack", id: host.id)
                }
            }
            .accessibilityIdentifier("hostchooser")
        }
    }

    /// The host a picker should open on; nil = this Mac. A selection that no
    /// longer exists (host removed in Settings while the window was open)
    /// falls back to this Mac rather than to some other server.
    static func resolveHost(selectedID: Int64?, hosts: [RemoteHost]) -> RemoteHost? {
        guard let selectedID else { return nil }
        return hosts.first { $0.id == selectedID }
    }

    /// What the chooser starts on: the default host, if it still exists.
    static func initialSelection(defaultHostID: Int64?, hosts: [RemoteHost]) -> Int64? {
        hosts.contains { $0.id == defaultHostID } ? defaultHostID : nil
    }

    private func chip(_ title: String, symbol: String, id: Int64?) -> some View {
        let isSelected = selectedHostID == id
        return HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
        }
        .foregroundStyle(isSelected ? YggdrasilTheme.text(scheme) : YggdrasilTheme.textMute(scheme))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? YggdrasilTheme.bgActive(scheme) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? YggdrasilTheme.accent : YggdrasilTheme.border(scheme),
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
        // Whole chip tappable, not just its opaque pixels.
        .contentShape(Rectangle())
        .onTapGesture { selectedHostID = id }
        .accessibilityIdentifier("hostchooser.chip.\(title)")
    }
}
