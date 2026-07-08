import Combine
@testable import ElevenLabs
import XCTest

extension XCTestCase {
    /// Waits for a `@Published` property to emit a value matching `predicate`.
    func waitForPublished<P: Publisher>(
        _ publisher: P,
        timeout: TimeInterval = 1.0,
        until predicate: @escaping (P.Output) -> Bool
    ) async where P.Failure == Never {
        let met = expectation(description: "condition met")
        var cancellable: AnyCancellable?
        cancellable = publisher.sink { value in
            if predicate(value) {
                met.fulfill()
                cancellable?.cancel()
            }
        }
        await fulfillment(of: [met], timeout: timeout)
        cancellable?.cancel()
    }

    /// Waits until `recorder` has at least `count` values, then returns the snapshot.
    func waitForValues<T>(
        _ recorder: ValueRecorder<T>,
        count: Int,
        timeout: TimeInterval = 1.0
    ) async -> [T] {
        let done = expectation(description: "recorder count")
        Task {
            await recorder.waitForCount(count)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
        return await recorder.values()
    }

    /// Waits until `recorder`'s latest value matches `predicate`, then returns that value.
    func waitForLastValue<T>(
        _ recorder: ValueRecorder<T>,
        timeout: TimeInterval = 1.0,
        matching predicate: @escaping @Sendable (T) -> Bool
    ) async -> T? {
        let done = expectation(description: "recorder last")
        Task {
            await recorder.waitForLast(matching: predicate)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
        return await recorder.last()
    }

    /// Waits until the mock's `onEventReceived` handler is installed.
    func waitForEventHandlerInstalled(
        on mock: MockWebRTCConnectionManager,
        timeout: TimeInterval = 1.0
    ) async {
        let done = expectation(description: "event handler installed")
        Task {
            await mock.waitForEventHandlerInstalled()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
    }

    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> some Sendable,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail(message(), file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}

actor ValueRecorder<Value> {
    private var storage: [Value] = []
    private var countWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var valueWaiters: [(predicate: @Sendable (Value) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ value: Value) {
        storage.append(value)
        countWaiters.removeAll { waiter in
            guard storage.count >= waiter.target else { return false }
            waiter.continuation.resume()
            return true
        }
        valueWaiters.removeAll { waiter in
            guard waiter.predicate(value) else { return false }
            waiter.continuation.resume()
            return true
        }
    }

    func reset() {
        storage.removeAll()
        let pendingCounts = countWaiters
        let pendingValues = valueWaiters
        countWaiters.removeAll()
        valueWaiters.removeAll()
        pendingCounts.forEach { $0.continuation.resume() }
        pendingValues.forEach { $0.continuation.resume() }
    }

    func values() -> [Value] {
        storage
    }

    func last() -> Value? {
        storage.last
    }

    /// Suspends until at least `expectedCount` values have been recorded.
    func waitForCount(_ expectedCount: Int) async {
        if storage.count >= expectedCount { return }
        await withCheckedContinuation { countWaiters.append((expectedCount, $0)) }
    }

    /// Suspends until the most recently recorded value satisfies `predicate`.
    func waitForLast(matching predicate: @escaping @Sendable (Value) -> Bool) async {
        if let last = storage.last, predicate(last) { return }
        await withCheckedContinuation { valueWaiters.append((predicate, $0)) }
    }
}
