import Foundation

/// One of the four Claude session states the spec calls out, plus `.unknown`
/// for the "no JSONL discovered yet" case.
enum ClaudeState: Equatable {
    case unknown
    case running
    case awaitingInput
    case idle
    case errored
}

/// Pure-function classifier. Given the latest known JSONL record and "now",
/// returns the spec's state per §Phase 6.
///
/// Thresholds match the spec:
/// - errored: the latest record's `type` contains "error"
/// - idle: no records in the last 5 minutes
/// - awaitingInput: latest record has `stop_reason == "end_turn"`
/// - running: any assistant or user record within the recency window
enum ClaudeStateDetector {
    static let idleThreshold: TimeInterval = 5 * 60
    static let recencyWindow: TimeInterval = 5

    static func evaluate(
        lastRecordType: String?,
        lastRecordStopReason: String?,
        lastRecordAt: Date?,
        now: Date
    ) -> ClaudeState {
        guard let type = lastRecordType, let lastRecordAt else {
            return .unknown
        }

        if type.lowercased().contains("error") {
            return .errored
        }

        let age = now.timeIntervalSince(lastRecordAt)
        if age > idleThreshold {
            return .idle
        }

        if lastRecordStopReason == "end_turn" {
            return .awaitingInput
        }

        // Anything else inside the recency window — user prompt being processed,
        // assistant streaming — counts as running.
        return .running
    }
}
