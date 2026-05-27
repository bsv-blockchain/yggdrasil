import SwiftUI

/// Coding-agent identity. Mirrors `AGENT_COLORS` / `AGENT_LABELS` in
/// `sidebar.jsx`. Brand colors are the published ones used by the design.
enum AgentIdentity: String, CaseIterable {
    case claude, codex, gemini, copilot, grok

    /// Heuristic mapping from `CodingAgent.command` to a known identity.
    /// Unknown commands fall back to `.claude` (the default agent).
    static func detect(command: String) -> AgentIdentity {
        let lower = command.lowercased()
        if lower.contains("claude") { return .claude }
        if lower.contains("codex") || lower.contains("openai") { return .codex }
        if lower.contains("gemini") || lower.contains("google") { return .gemini }
        if lower.contains("copilot") || lower.contains("ghcs") { return .copilot }
        if lower.contains("grok") || lower.contains("xai") { return .grok }
        return .claude
    }

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .copilot: "Copilot"
        case .grok: "Grok"
        }
    }

    /// Per-agent brand color.
    /// claude #d97757 — Anthropic warm orange. codex #19c37d — OpenAI green.
    /// gemini #4670ff — our accent (Google blue substitute). copilot #9d8df1
    /// — Copilot violet. grok #e8e8e8 — xAI light.
    var color: Color {
        switch self {
        case .claude: Color(hex: 0xd97757)
        case .codex: Color(hex: 0x19c37d)
        case .gemini: Color(hex: 0x4670ff)
        case .copilot: Color(hex: 0x9d8df1)
        case .grok: Color(hex: 0xe8e8e8)
        }
    }
}

/// One agent's brand mark, drawn as a SwiftUI `Path` over a 16×16 design grid.
/// Ports the hand-drawn SVG paths in `icons.jsx`. Claude uses the official
/// Anthropic symbol (template-rendered PNG asset) instead of the hand-drawn
/// asterisk fallback.
struct AgentMark: View {
    let agent: AgentIdentity
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let asset = Self.assetName(for: agent) {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(agent.color)
                .frame(width: size, height: size)
                .accessibilityLabel(agent.label)
        } else {
            canvasBody
        }
    }

    /// Asset-catalog name for agents whose brand mark is shipped as an image
    /// (rather than the hand-drawn Canvas paths). Returns nil for agents that
    /// still rely on `canvasBody`.
    private static func assetName(for agent: AgentIdentity) -> String? {
        switch agent {
        case .claude: "ClaudeMark"
        case .codex: "CodexMark"
        case .grok: "GrokMark"
        case .gemini, .copilot: nil
        }
    }

    private var canvasBody: some View {
        Canvas { context, canvasSize in
            // Scale the 16×16 design grid to `size`.
            let scale = canvasSize.width / 16
            let stroke = StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round, lineJoin: .round)
            context.scaleBy(x: scale, y: scale)
            let color = GraphicsContext.Shading.color(agent.color)

            switch agent {
            case .claude, .codex, .grok:
                // Handled by the Image branch in `body` (asset-backed marks);
                // never reached.
                break
            case .gemini:
                // Four-pointed sparkle (Gemini's official mark stylised).
                context.fill(geminiSparkle(), with: color)
            case .copilot:
                // Goggles + side antennas (Copilot's distinctive face).
                let ellipse = Path(ellipseIn: CGRect(x: 2, y: 5.4, width: 12, height: 7.2))
                context.stroke(ellipse, with: color, style: stroke)
                let eyeL = Path(ellipseIn: CGRect(x: 4.9, y: 8.1, width: 1.8, height: 1.8))
                let eyeR = Path(ellipseIn: CGRect(x: 9.3, y: 8.1, width: 1.8, height: 1.8))
                context.fill(eyeL, with: color)
                context.fill(eyeR, with: color)
                let antennaL = Path { path in
                    path.move(to: CGPoint(x: 5.6, y: 5.5))
                    path.addCurve(
                        to: CGPoint(x: 8, y: 4.1),
                        control1: CGPoint(x: 5.2, y: 4.1),
                        control2: CGPoint(x: 6, y: 2.9)
                    )
                    path.addCurve(
                        to: CGPoint(x: 8, y: 5.3),
                        control1: CGPoint(x: 8.6, y: 2.9),
                        control2: CGPoint(x: 9, y: 3.3)
                    )
                }
                let antennaR = Path { path in
                    path.move(to: CGPoint(x: 10.4, y: 5.5))
                    path.addCurve(
                        to: CGPoint(x: 8, y: 4.1),
                        control1: CGPoint(x: 10.8, y: 4.1),
                        control2: CGPoint(x: 10, y: 2.9)
                    )
                    path.addCurve(
                        to: CGPoint(x: 8, y: 5.3),
                        control1: CGPoint(x: 7.4, y: 2.9),
                        control2: CGPoint(x: 7, y: 3.3)
                    )
                }
                context.stroke(antennaL, with: color, style: stroke)
                context.stroke(antennaR, with: color, style: stroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.label)
    }

    // MARK: - Path helpers

    private func geminiSparkle() -> Path {
        Path { path in
            path.move(to: CGPoint(x: 8, y: 0.6))
            path.addCurve(
                to: CGPoint(x: 14.8, y: 7.4),
                control1: CGPoint(x: 8.4, y: 4.0),
                control2: CGPoint(x: 11.4, y: 6.6)
            )
            path.addLine(to: CGPoint(x: 14.8, y: 8.6))
            path.addCurve(
                to: CGPoint(x: 8, y: 15.4),
                control1: CGPoint(x: 11.4, y: 9.4),
                control2: CGPoint(x: 8.4, y: 12.0)
            )
            path.addLine(to: CGPoint(x: 7.6, y: 15.4))
            path.addCurve(
                to: CGPoint(x: 0.8, y: 8.6),
                control1: CGPoint(x: 7.2, y: 12.0),
                control2: CGPoint(x: 4.2, y: 9.4)
            )
            path.addLine(to: CGPoint(x: 0.8, y: 7.4))
            path.addCurve(
                to: CGPoint(x: 7.6, y: 0.6),
                control1: CGPoint(x: 4.2, y: 6.6),
                control2: CGPoint(x: 7.2, y: 4.0)
            )
            path.closeSubpath()
        }
    }
}

/// Bordered tile holding the `AgentMark` with a per-agent gradient background
/// and an optional status pip in the bottom-right. Used by the rich `TabRow`.
struct AgentBadge: View {
    let agent: AgentIdentity
    let statusIcon: TabStatus.Icon?
    var size: CGFloat = 26
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [
                            agent.color.opacity(0.22),
                            agent.color.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(agent.color.opacity(0.35), lineWidth: 0.5)
                )
                .overlay(
                    AgentMark(agent: agent, size: size * 0.62)
                )
                .frame(width: size, height: size)

            if let icon = statusIcon, showsPip(for: icon) {
                Circle()
                    .fill(color(for: icon))
                    .overlay(
                        Circle()
                            .stroke(YggdrasilTheme.bgPane(scheme), lineWidth: 1.5)
                    )
                    .frame(width: 9, height: 9)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size, height: size)
        .help(agent.label)
    }

    private func showsPip(for icon: TabStatus.Icon) -> Bool {
        switch icon {
        case .idle, .running, .awaitingInput, .errored, .ciFailing, .dirty, .unread:
            return true
        }
    }

    private func color(for icon: TabStatus.Icon) -> Color {
        switch icon {
        case .errored, .ciFailing: YggdrasilTheme.statusErr(scheme)
        case .awaitingInput, .dirty: YggdrasilTheme.statusWarn(scheme)
        case .running: YggdrasilTheme.statusInfo
        case .unread: YggdrasilTheme.ember
        case .idle: YggdrasilTheme.statusIdle(scheme)
        }
    }
}
