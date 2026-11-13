import Foundation

struct DeadlineExceeded: Error {}

/// Runs `work`, giving up after `deadline`. `ProcessRunner` has no timeout,
/// so a command that never exits would otherwise hang its caller forever.
/// The group still waits for `work` to finish once cancelled, so this only
/// holds when the work's runner terminates on cancellation.
func withDeadline<T: Sendable>(
    _ deadline: Duration,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: deadline)
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        return first
    }
}
