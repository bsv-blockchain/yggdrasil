import SwiftUI

/// Compact "open with" agent picker: one small chip per configured agent.
///
/// The task pickers used to hardcode `agentStore.getDefault()`, so a review or
/// assigned-task session was always whichever agent happened to be the default
/// — there was no way to review a PR with Codex while Claude was default, and
/// the resulting branch name (`<agent>-review-pr-N`) had no way to say
/// otherwise. `NewTabSheet` has always had a chooser, but its `AgentCard` is a
/// 240×110 card built for a sheet with room to spare; these pickers are dense
/// lists where the choice belongs on one line next to the buttons.
///
/// Selection defaults to the default agent, so the fast path is unchanged:
/// open the window, click a row, get what you always got.
struct AgentChooser: View {
    let agents: [CodingAgent]
    @Binding var selectedAgentID: Int64?
    let scheme: ColorScheme

    var body: some View {
        // One agent configured means no choice to make; the label would only
        // be noise next to the buttons.
        if agents.count > 1 {
            HStack(spacing: 6) {
                Text("Open with")
                    .font(.system(size: 11))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
                ForEach(agents, id: \.id) { agent in
                    chip(for: agent)
                }
            }
            .accessibilityIdentifier("agentchooser")
        }
    }

    /// The agent a picker should open with. An explicit selection wins; a
    /// selection that no longer exists (agent removed in Preferences while the
    /// window was open) falls back rather than stranding the user, as does no
    /// selection at all.
    static func resolveAgent(
        selectedID: Int64?,
        agents: [CodingAgent],
        defaultAgent: CodingAgent?
    ) -> CodingAgent? {
        if let selectedID, let picked = agents.first(where: { $0.id == selectedID }) {
            return picked
        }
        return defaultAgent ?? agents.first
    }

    private func chip(for agent: CodingAgent) -> some View {
        let isSelected = selectedAgentID == agent.id
        return HStack(spacing: 5) {
            AgentBadge(agent: AgentIdentity.detect(command: agent.command), statusIcon: nil, size: 14)
            Text(agent.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? YggdrasilTheme.text(scheme) : YggdrasilTheme.textMute(scheme))
        }
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
        .onTapGesture { selectedAgentID = agent.id }
        .accessibilityIdentifier("agentchooser.chip.\(agent.name)")
    }
}
