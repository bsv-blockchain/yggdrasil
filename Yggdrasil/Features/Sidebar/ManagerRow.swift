import SwiftUI

/// The pinned "Yggdrasil" row at the top of the sidebar: a Claude session
/// that manages the other tabs through the Yggdrasil MCP.
struct ManagerRow: View {
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tree")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(YggdrasilTheme.accent)
                .frame(width: 26, height: 26)
                .background(YggdrasilTheme.accentSoft(scheme), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Yggdrasil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YggdrasilTheme.text(scheme))
                Text("Ask Claude to manage your tabs")
                    .font(.system(size: 10.5))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? YggdrasilTheme.bgActive(scheme) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Yggdrasil session")
    }
}
