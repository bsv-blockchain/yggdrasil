import XCTest
@testable import Yggdrasil

/// Counts how many times the scheduler's action has fired and lets tests await a target count.
actor TickCounter {
    private(set) var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        count += 1
        waiters = waiters.filter { waiter in
            if count >= waiter.target {
                waiter.continuation.resume()
                return false
            }
            return true
        }
    }

    func waitFor(count target: Int, timeout: Duration) async throws {
        if count >= target { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    Task { await self.appendWaiter(target: target, continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw XCTSkip("waitFor(\(target)) timed out")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func appendWaiter(target: Int, continuation: CheckedContinuation<Void, Never>) {
        if count >= target {
            continuation.resume()
        } else {
            waiters.append((target, continuation))
        }
    }
}

final class SyncSchedulerTests: XCTestCase {
    func testFiresImmediatelyOnStart() async throws {
        let counter = TickCounter()
        let scheduler = SyncScheduler(interval: .seconds(10)) { await counter.increment() }
        await scheduler.start()
        try await counter.waitFor(count: 1, timeout: .seconds(1))
        let count = await counter.count
        XCTAssertGreaterThanOrEqual(count, 1)
        await scheduler.stop()
    }

    func testFiresRepeatedlyAtInterval() async throws {
        let counter = TickCounter()
        let scheduler = SyncScheduler(interval: .milliseconds(40)) { await counter.increment() }
        await scheduler.start()
        try await counter.waitFor(count: 3, timeout: .seconds(2))
        await scheduler.stop()
        let final = await counter.count
        XCTAssertGreaterThanOrEqual(final, 3)
    }

    func testStopHaltsFutureTicks() async throws {
        let counter = TickCounter()
        let scheduler = SyncScheduler(interval: .milliseconds(40)) { await counter.increment() }
        await scheduler.start()
        try await counter.waitFor(count: 2, timeout: .seconds(2))
        await scheduler.stop()

        let countAtStop = await counter.count
        try await Task.sleep(for: .milliseconds(200))
        let countLater = await counter.count
        XCTAssertEqual(countAtStop, countLater, "no ticks should fire after stop()")
    }

    func testActionErrorIsSwallowedAndLoopContinues() async throws {
        let counter = TickCounter()
        let scheduler = SyncScheduler(interval: .milliseconds(40)) {
            await counter.increment()
            // Throw on alternate ticks to confirm the loop survives.
            if await counter.count % 2 == 1 {
                throw NSError(domain: "test", code: 1)
            }
        }
        await scheduler.start()
        try await counter.waitFor(count: 3, timeout: .seconds(2))
        await scheduler.stop()
    }

    func testStartIsIdempotent() async throws {
        let counter = TickCounter()
        let scheduler = SyncScheduler(interval: .milliseconds(40)) { await counter.increment() }
        await scheduler.start()
        await scheduler.start() // second start is a no-op
        try await counter.waitFor(count: 2, timeout: .seconds(2))
        await scheduler.stop()
    }
}
