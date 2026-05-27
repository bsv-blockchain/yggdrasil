import SwiftUI

/// One row in the sidebar `LazyVStack`. Pure presentation — driven by the
/// `TabRowViewModel` value type. Selection styling is set by the parent.
struct TabRow: View {
    let model: TabRowViewModel
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 14, height: 14, alignment: .center)
                .padding(.top, 2)
                .accessibilityIdentifier("tabrow.statusicon")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.titleLine)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("tabrow.title")

                Text(model.branchLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("tabrow.branch")

                Text(model.worktreeLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityIdentifier("tabrow.worktree")
            }

            Spacer(minLength: 4)

            trailingBadge
                .accessibilityIdentifier("tabrow.badge")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help(tooltipText)
    }

    /// Multi-line help string built from the aggregator's tooltipLines.
    private var tooltipText: String {
        if let lines = model.liveStatus?.tooltipLines, !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        return model.titleLine
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.statusIcon {
        case .idle:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running:
            Image(systemName: "circle.fill")
                .foregroundStyle(.green)
        case .awaitingInput:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.yellow)
        case .errored:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .dirty:
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
        case .unread:
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(.blue)
        case .ciFailing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        switch model.trailingBadge {
        case .none:
            EmptyView()
        case .prNumber(let num):
            badgeLabel("#\(num)", systemImage: "arrow.triangle.merge")
        case .issueNumber(let num):
            badgeLabel("#\(num)", systemImage: "exclamationmark.circle")
        }
    }

    private func badgeLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }
}
