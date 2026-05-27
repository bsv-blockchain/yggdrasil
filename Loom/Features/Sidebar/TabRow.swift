import SwiftUI

/// One sidebar row, redesigned per `Loom.html`:
/// - Leading `AgentBadge` (per-agent brand mark + status pip)
/// - 3-line stack: title / branch (mono w/ branch glyph) / worktree (mono, mid-ellipsis)
/// - Trailing PR/issue badge + ember unread dot
/// - Footer row of status chips (working / awaiting / dirty / ahead / behind / CI / unread)
/// - 2.5pt accent rail down the left edge when selected
struct TabRow: View {
    let model: TabRowViewModel
    let agent: AgentIdentity
    let isSelected: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentBadge(agent: agent, statusIcon: model.liveStatus?.icon, size: 26)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.titleLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LoomTheme.text(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("tabrow.title")

                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .opacity(0.65)
                    Text(model.branchLine)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(LoomTheme.textDim(scheme))
                .accessibilityIdentifier("tabrow.branch")

                Text(model.worktreeLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LoomTheme.textMute(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("tabrow.worktree")

                StatusChipRow(status: model.liveStatus, agent: agent)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                trailingBadge
                if model.liveStatus?.showsUnreadBadgeDot == true {
                    Circle()
                        .fill(LoomTheme.ember)
                        .frame(width: 6, height: 6)
                        .overlay(
                            Circle()
                                .stroke(LoomTheme.ember.opacity(0.22), lineWidth: 2)
                        )
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? LoomTheme.bgActive(scheme) : Color.clear)
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LoomTheme.accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 8)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? LoomTheme.borderStrong(scheme) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .contentShape(Rectangle())
        .help(tooltipText)
    }

    @ViewBuilder
    private var trailingBadge: some View {
        switch model.trailingBadge {
        case .none:
            EmptyView()
        case .prNumber(let number):
            Text("#\(number)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(LoomTheme.textDim(scheme))
                .tracking(0.2)
        case .issueNumber(let number):
            Text("#\(number)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(LoomTheme.ember)
                .tracking(0.2)
        }
    }

    private var tooltipText: String {
        if let lines = model.liveStatus?.tooltipLines, !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        return model.titleLine
    }
}

/// Row of compact status chips under each tab row. Mirrors `StatusFooter` in
/// `sidebar.jsx`.
struct StatusChipRow: View {
    let status: TabStatus?
    let agent: AgentIdentity

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                StatusChip(chip: chip)
            }
            if chips.isEmpty {
                StatusChip(chip: .init(symbol: nil, text: "no activity", tone: .neutral))
            }
        }
    }

    private var chips: [StatusChip.Data] {
        guard let status else { return [] }
        var out: [StatusChip.Data] = []

        switch status.icon {
        case .running:
            out.append(.init(symbol: "clock", text: "working", tone: tone(for: agent)))
        case .awaitingInput:
            out.append(.init(symbol: "ellipsis.circle", text: "awaiting input", tone: .warn))
        case .errored:
            out.append(.init(symbol: "xmark.octagon.fill", text: "error", tone: .err))
        case .ciFailing, .dirty, .unread, .idle:
            break
        }

        for line in status.tooltipLines {
            // Parse the tooltipLines (which read "git: dirty",
            // "N ahead, M behind upstream", "CI: SUCCESS|FAILURE|…",
            // "K unread comment(s)") to drive the chip set.
            let lower = line.lowercased()
            if lower.contains("git: dirty") {
                out.append(.init(symbol: "pencil", text: "dirty", tone: .ember))
            } else if let counts = parseAheadBehind(line) {
                if counts.ahead > 0 {
                    out.append(.init(symbol: "arrow.up", text: "\(counts.ahead)", tone: .neutral))
                }
                if counts.behind > 0 {
                    out.append(.init(symbol: "arrow.down", text: "\(counts.behind)", tone: .warn))
                }
            } else if lower.hasPrefix("ci: ") {
                let value = String(line.dropFirst(4)).lowercased()
                if value.contains("success") || value.contains("pass") {
                    out.append(.init(symbol: "checkmark", text: "CI", tone: .ok))
                } else if value.contains("fail") || value.contains("error") {
                    out.append(.init(symbol: "xmark", text: "CI", tone: .err))
                } else {
                    out.append(.init(symbol: "clock", text: "CI", tone: .warn))
                }
            } else if lower.contains("unread comment") {
                let digits = line.filter(\.isNumber)
                if let count = Int(digits), count > 0 {
                    out.append(.init(symbol: "bubble.left", text: "\(count)", tone: .ember))
                }
            }
        }
        return out
    }

    private func tone(for agent: AgentIdentity) -> StatusChip.Tone {
        switch agent {
        case .claude: .ember
        case .codex: .ok
        case .gemini: .info
        case .copilot, .grok: .info
        }
    }

    private func parseAheadBehind(_ line: String) -> (ahead: Int, behind: Int)? {
        let pattern = #"(\d+) ahead, (\d+) behind"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 3,
              let aheadRange = Range(match.range(at: 1), in: line),
              let behindRange = Range(match.range(at: 2), in: line),
              let ahead = Int(line[aheadRange]),
              let behind = Int(line[behindRange])
        else { return nil }
        return (ahead, behind)
    }
}

/// Compact pill rendered by `StatusChipRow`. Mirrors `Chip` in `sidebar.jsx`.
struct StatusChip: View {
    enum Tone { case neutral, ok, warn, err, info, ember }
    struct Data {
        let symbol: String?
        let text: String
        let tone: Tone
    }

    let chip: Data
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = chip.symbol {
                Image(systemName: symbol).font(.system(size: 9))
            }
            Text(chip.text)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(0.1)
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .foregroundStyle(foreground)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var foreground: Color {
        switch chip.tone {
        case .neutral: LoomTheme.textDim(scheme)
        case .ok: LoomTheme.statusOK(scheme)
        case .warn: LoomTheme.statusWarn(scheme)
        case .err: LoomTheme.statusErr(scheme)
        case .info: LoomTheme.accent
        case .ember: LoomTheme.ember
        }
    }
    private var background: Color {
        switch chip.tone {
        case .neutral: LoomTheme.chipBg(scheme)
        case .ok: LoomTheme.statusOK(scheme).opacity(0.12)
        case .warn: LoomTheme.statusWarn(scheme).opacity(0.14)
        case .err: LoomTheme.statusErr(scheme).opacity(0.13)
        case .info: LoomTheme.accentSoft(scheme)
        case .ember: LoomTheme.emberSoft(scheme)
        }
    }
    private var border: Color {
        switch chip.tone {
        case .neutral: LoomTheme.chipBd(scheme)
        case .ok: LoomTheme.statusOK(scheme).opacity(0.22)
        case .warn: LoomTheme.statusWarn(scheme).opacity(0.24)
        case .err: LoomTheme.statusErr(scheme).opacity(0.26)
        case .info: LoomTheme.accent.opacity(0.26)
        case .ember: LoomTheme.ember.opacity(0.28)
        }
    }
}
