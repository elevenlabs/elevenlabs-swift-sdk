import Foundation

actor ConversationInitiationMetadataWaiter {
    private let timeoutNanoseconds: UInt64
    private var outcome: Result<ConversationMetadataEvent, Error>?
    private var continuation: CheckedContinuation<ConversationMetadataEvent, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(timeout: TimeInterval) {
        timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
    }

    func observe(_ metadata: ConversationMetadataEvent) {
        complete(.success(metadata))
    }

    func wait() async throws -> ConversationMetadataEvent {
        if let outcome { return try outcome.get() }
        if Task.isCancelled {
            let error = CancellationError()
            complete(.failure(error))
            throw error
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome {
                    continuation.resume(with: outcome)
                    return
                }
                precondition(self.continuation == nil, "Only one metadata wait is allowed")
                self.continuation = continuation
                startTimeout()
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func startTimeout() {
        guard timeoutTask == nil else { return }
        timeoutTask = Task { [weak self, timeoutNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.complete(.failure(ConversationError.initiationMetadataTimeout))
        }
    }

    private func complete(_ outcome: Result<ConversationMetadataEvent, Error>) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(with: outcome)
        continuation = nil
    }
}
