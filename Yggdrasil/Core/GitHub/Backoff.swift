import Foundation

/// Pure-function exponential backoff per spec §Phase 1: 1s, 2s, 4s, 8s, … capped at 5min.
enum Backoff {
    static let cap: TimeInterval = 300

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let normalised = max(attempt, 1)
        let raw = pow(2.0, Double(normalised - 1))
        return min(raw, cap)
    }
}
