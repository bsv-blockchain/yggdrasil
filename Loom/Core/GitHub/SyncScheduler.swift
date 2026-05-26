import Foundation

/// Drives a recurring async action at a fixed interval.
///
/// - Fires the action immediately on `start()`, then every `interval`.
/// - Errors thrown by the action are caught and logged; the loop keeps going.
/// - `stop()` cancels the running task; future ticks don't fire.
/// - `start()` is idempotent — calling twice is a no-op.
actor SyncScheduler {
    private let interval: Duration
    private let action: @Sendable () async throws -> Void
    private var runningTask: Task<Void, Never>?

    init(interval: Duration, action: @escaping @Sendable () async throws -> Void) {
        self.interval = interval
        self.action = action
    }

    func start() {
        guard runningTask == nil else { return }
        runningTask = Task { [interval, action] in
            while !Task.isCancelled {
                do {
                    try await action()
                } catch is CancellationError {
                    return
                } catch {
                    LoomLog.sync.error("SyncScheduler action threw: \(String(describing: error), privacy: .public)")
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return // cancelled
                }
            }
        }
    }

    func stop() {
        runningTask?.cancel()
        runningTask = nil
    }
}
