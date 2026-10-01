import Foundation

/// A fingerprint of *why* a tab is demanding attention.
///
/// Dismissing amber records this value; the dismissal holds only while the
/// fingerprint is unchanged. That is what "until some new event triggers it
/// again" means in practice — no timer and no snooze duration to guess at. A
/// new commit, another unresolved thread, a fresh review request, a changed
/// review decision, or the agent writing anything new all change it, and the
/// amber comes back by itself.
enum AttentionSignature {
    /// Bumped if the format changes, so stored mutes from an older build stop
    /// matching and the amber comes back. Failing open is the right direction:
    /// a stale mute that silently holds would hide real work.
    private static let version = "v2"

    /// Field separator that cannot appear in any component, so `nil` and an
    /// empty string stay distinguishable — otherwise clearing a field would
    /// silently preserve a dismissal that should have lapsed.
    private static let separator = "\u{1F}"

    /// Every input that can make a tab demand attention has to be in here. A
    /// mute is global over the tab, so any reason left out is a reason that can
    /// turn amber while the mute silently swallows it.
    static func make(row: GitHubStatus?, session: AgentActivitySample?) -> String {
        [
            version,
            row?.headSHA.map { "sha:\($0)" } ?? "sha:-",
            "threads:\(row?.unresolvedThreadsAwaitingViewer ?? 0)",
            // A count alone is not enough: resolving one thread and opening
            // another between two syncs returns it to the muted value and hides
            // the new one. This total only ever grows.
            "activity:\(row?.commentsReviewsTotal ?? 0)",
            row?.viewerReviewRequestedAt.map { "req:\($0.timeIntervalSince1970)" } ?? "req:-",
            "requested:\(row?.viewerReviewRequested ?? false)",
            row?.reviewState.map { "review:\($0)" } ?? "review:-",
            // CI is a reason `needsAttention` fires on (red on your own PR), so
            // leaving it out meant a muted tab could go red and stay silent.
            row?.ciState.map { "ci:\($0)" } ?? "ci:-",
            agentComponent(session)
        ].joined(separator: separator)
    }

    /// Only an attention-worthy agent state counts.
    ///
    /// `AgentActivitySample.timestamp` advances on essentially every record the
    /// agent writes — its own tool calls and results included. Fingerprinting
    /// that made muting useless exactly where it is most wanted: mute a tab
    /// because you will deal with its thread later, keep working in it, and the
    /// mute lapses within one 5s tick. A question or an error is an event; the
    /// agent talking to itself is not.
    private static func agentComponent(_ session: AgentActivitySample?) -> String {
        guard let session else { return "agent:-" }
        switch session.activity {
        case .awaitingAnswer, .errored:
            return "agent:\(session.activity):\(session.timestamp.timeIntervalSince1970)"
        case .working, .turnEnded:
            return "agent:quiet"
        }
    }

    /// Whether the tab's amber is currently muted.
    static func isDismissed(current: String, dismissed: String?) -> Bool {
        guard let dismissed, !current.isEmpty else { return false }
        return current == dismissed
    }
}

/// Where dismissals live.
///
/// `UserDefaults`, following `yggdrasil.diffScope.<tabID>` — this is per-tab,
/// per-machine view state that re-arms on any real event, so the worst case
/// from losing it is that amber reappears. Keeping it out of the database also
/// keeps it off the migration path, which matters while two other branches are
/// in flight against the same schema.
enum AttentionDismissal {
    private static func key(_ tabID: Int64) -> String {
        "yggdrasil.attentionDismissed.\(tabID)"
    }

    static func dismissedSignature(tabID: Int64, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(tabID))
    }

    static func dismiss(tabID: Int64, signature: String, defaults: UserDefaults = .standard) {
        defaults.set(signature, forKey: key(tabID))
    }

    /// Also the cleanup path when a tab is removed: a key left behind would
    /// mute a future tab that reused the id.
    static func restore(tabID: Int64, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(tabID))
    }
}
