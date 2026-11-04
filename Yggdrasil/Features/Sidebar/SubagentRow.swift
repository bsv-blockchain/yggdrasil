import SwiftUI

/// A running subagent, nested under its tab's row. Selecting it shows its
/// transcript in the main pane.
struct SubagentRow: View {
    let info: SubagentInfo
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(YggdrasilTheme.textFaint(scheme))
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
            Text(info.agentType)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(YggdrasilTheme.chipBg(scheme), in: Capsule())
            Text(info.description.isEmpty ? "Subagent" : info.description)
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.text(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if info.background {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 9))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
                    .help("Runs in the background")
            }
        }
        .padding(.leading, 18 + CGFloat(max(info.spawnDepth - 1, 0)) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? YggdrasilTheme.bgActive(scheme) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.agentType) subagent: \(info.description)")
    }
}
