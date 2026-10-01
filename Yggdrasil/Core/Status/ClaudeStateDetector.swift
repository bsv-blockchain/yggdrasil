import Foundation

/// One of the four Claude session states the spec calls out, plus `.unknown`
/// for the "no transcript discovered yet" case.
enum ClaudeState: Equatable {
    case unknown
    case running
    case awaitingInput
    case idle
    case errored
}

/// Turns the newest transcript record into the state the sidebar renders.
///
/// `.awaitingInput` means the agent asked an explicit question and is blocked
/// until it's answered — not merely that a turn finished. That distinction is
/// the whole point: a finished turn is where nearly every open tab rests (21 of
/// 27 measured), so counting it would make the amber pill and the "Needs me"
/// filter match almost everything.
///
/// `.awaitingInput` and `.errored` deliberately don't decay with time. Both are
/// latched conditions — nothing changes until the user acts — and real
/// transcripts show multi-minute gaps before a question gets answered, so any
/// decay window would drop the row precisely while it still needs attention.
enum ClaudeStateDetector {
    /// How long without any activity before a working session counts as idle.
    static let idleThreshold: TimeInterval = 5 * 60

    static func evaluate(activity: AgentActivitySample?, now: Date) -> ClaudeState {
        guard let activity else { return .unknown }
        switch activity.activity {
        case .errored:
            return .errored
        case .awaitingAnswer:
            return .awaitingInput
        case .turnEnded:
            return .idle
        case .working:
            let age = now.timeIntervalSince(activity.timestamp)
            return age > idleThreshold ? .idle : .running
        }
    }
}
