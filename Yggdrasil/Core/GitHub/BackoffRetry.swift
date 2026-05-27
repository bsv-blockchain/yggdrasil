import Foundation

/// Generic backoff-retry helper used by the sync scheduler.
///
/// On each failed attempt, sleeps `Backoff.delay(forAttempt:)` seconds before
/// trying again. After `maxAttempts` failures, rethrows the last error.
/// `sleep` is injectable so tests don't have to wait real time.
enum BackoffRetry {
    static func attempt<T>(
        maxAttempts: Int = 5,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                YggdrasilLog.sync.warning(
                    "BackoffRetry attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                if attempt < maxAttempts {
                    let delay = Backoff.delay(forAttempt: attempt)
                    try await sleep(.seconds(delay))
                }
            }
        }
        throw lastError ?? NSError(domain: "BackoffRetry", code: -1)
    }
}
