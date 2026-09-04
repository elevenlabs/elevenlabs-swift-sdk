import Foundation

/// Transport for text-only conversations.
///
/// Opens a single `URLSessionWebSocketTask` to the text conversation endpoint,
/// sends `conversationInit` once the socket is open, then runs a receive loop
/// that forwards incoming events and waits for initiation metadata. On runtime
/// socket error, fires `onDisconnected` once.
///
/// Used instead of `WebRTCConnectionManager` because the WebRTC transport
/// drops rooms with no audio — text-only needs a transport that stays open
/// without media.
@MainActor
final class WebSocketConnectionManager: WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onDisconnected: (() async -> Void)?
    var errorHandler: ((Swift.Error?) -> Void)?

    private let urlSession: URLSession
    private let logger: any Logging
    private let endpoints: Endpoints
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var initiationMetadataWaiter: ConversationInitiationMetadataWaiter?
    private var startupGeneration = 0
    private var activeStartupGeneration: Int?
    private var connectionGeneration: Int?
    private var startupDisconnectErrors: [Int: ConversationError] = [:]

    init(logger: any Logging, endpoints: Endpoints = .production) {
        self.logger = logger
        self.endpoints = endpoints
        urlSession = URLSession(configuration: .default)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    @MainActor
    func connect(
        auth: ConversationAuth.TextOnly,
        config: ConversationConfig,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult {
        startupGeneration += 1
        let generation = startupGeneration
        activeStartupGeneration = generation
        connectionGeneration = generation
        defer {
            if activeStartupGeneration == generation {
                activeStartupGeneration = nil
            }
            startupDisconnectErrors[generation] = nil
        }
        await initiationMetadataWaiter?.cancel()
        let waiter = ConversationInitiationMetadataWaiter(
            timeout: config.startupConfiguration.initiationMetadataTimeout
        )
        initiationMetadataWaiter = waiter
        let startTime = Date()
        var metrics = ConversationStartupMetrics()

        let resolved: (url: URL, agentId: String)
        do {
            resolved = try await Self.websocketUrl(
                for: auth,
                endpoints: endpoints,
                environment: config.environment
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            throw ConversationStartupError(
                stage: .preparing,
                metrics: metrics,
                underlyingError: error as? ConversationError ?? .authenticationFailed(error)
            )
        }
        guard activeStartupGeneration == generation else { throw CancellationError() }
        let url = resolved.url

        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()

        // The first send awaits the WebSocket handshake internally —
        // any connection failure surfaces here.
        onStartupStateChange(.sendingConversationInit)
        let initStart = Date()
        do {
            let initEvent = ConversationInitEvent(config: config)
            try await send(data: EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent)))
            metrics.conversationInit = Date().timeIntervalSince(initStart)
        } catch is CancellationError {
            tearDownTask(task)
            throw CancellationError()
        } catch {
            tearDownTask(task)
            metrics.conversationInit = Date().timeIntervalSince(initStart)
            metrics.total = Date().timeIntervalSince(startTime)
            throw ConversationStartupError(
                stage: .sendingConversationInit,
                metrics: metrics,
                underlyingError: error as? ConversationError ?? .connectionFailed(error)
            )
        }
        guard self.task === task, connectionGeneration == generation else {
            tearDownTask(task)
            throw CancellationError()
        }

        // Socket is up and the init message is sent. Start consuming responses.
        let logger = logger
        receiveTask = Task { [weak self, weak task] in
            guard let task else { return }
            await Self.receiveLoop(
                task: task,
                metadataWaiter: waiter,
                logger: logger,
                onEvent: { [weak self] event in
                    self?.deliver(event, from: task, generation: generation)
                },
                onFailure: { [weak self] error in
                    await self?.handleReceiveFailure(error, from: task, generation: generation)
                }
            )
        }

        let metadata = try await waitForInitiationMetadata(
            config: config,
            metrics: &metrics,
            startTime: startTime,
            metadataWaiter: waiter,
            onStartupStateChange: onStartupStateChange
        )
        if let startupDisconnectError = startupDisconnectErrors[generation] {
            throw ConversationStartupError(
                stage: .waitingForInitiationMetadata(
                    timeout: config.startupConfiguration.initiationMetadataTimeout
                ),
                metrics: metrics,
                underlyingError: startupDisconnectError
            )
        }
        return ConversationStartResult(
            callInfo: CallInfo(agentId: resolved.agentId, conversationId: metadata.conversationId),
            metrics: metrics
        )
    }

    func send(data: Data) async throws {
        guard let task else {
            throw ConnectionManagerError.notConnected
        }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func disconnect() async {
        activeStartupGeneration = nil
        connectionGeneration = nil
        onEventReceived = nil
        onDisconnected = nil
        errorHandler = nil

        await initiationMetadataWaiter?.cancel()
        initiationMetadataWaiter = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func tearDownTask(_ task: URLSessionWebSocketTask) {
        task.cancel(with: .normalClosure, reason: nil)
        if self.task === task {
            self.task = nil
            connectionGeneration = nil
        }
    }

    private nonisolated static func receiveLoop(
        task: URLSessionWebSocketTask,
        metadataWaiter: ConversationInitiationMetadataWaiter,
        logger: any Logging,
        onEvent: @escaping @MainActor @Sendable (IncomingEvent) -> Void,
        onFailure: @escaping @Sendable (Error) async -> Void
    ) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    await Self.handleIncomingData(
                        Data(text.utf8),
                        metadataWaiter: metadataWaiter,
                        logger: logger,
                        onEvent: onEvent
                    )
                case .data:
                    logger.warning("Ignoring binary WebSocket message")
                @unknown default:
                    logger.warning("Unknown WebSocket message type")
                }
            } catch {
                guard !Task.isCancelled else { return }
                await onFailure(error)
                return
            }
        }
    }

    private func deliver(
        _ event: IncomingEvent,
        from task: URLSessionWebSocketTask,
        generation: Int
    ) {
        guard self.task === task, connectionGeneration == generation else { return }
        onEventReceived?(event)
    }

    private func handleReceiveFailure(
        _ error: Error,
        from task: URLSessionWebSocketTask,
        generation: Int
    ) async {
        guard self.task === task, connectionGeneration == generation else { return }
        self.task = nil
        connectionGeneration = nil
        errorHandler?(error)
        if activeStartupGeneration == generation {
            let startupError = ConversationError.connectionFailed(error)
            startupDisconnectErrors[generation] = startupError
            await initiationMetadataWaiter?.fail(startupError)
            return
        }
        await onDisconnected?()
    }

    static func websocketUrl(
        for auth: ConversationAuth.TextOnly,
        endpoints: Endpoints,
        environment: String? = nil
    ) async throws -> (url: URL, agentId: String) {
        switch auth {
        case let .publicAgent(agentId):
            guard var components = URLComponents(url: endpoints.textWebSocket, resolvingAgainstBaseURL: false) else {
                throw ConversationError.authenticationFailed("Invalid conversation URL")
            }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "agent_id", value: agentId))
            if let environment {
                queryItems.append(URLQueryItem(name: "environment", value: environment))
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw ConversationError.authenticationFailed("Invalid conversation URL")
            }
            return (url, agentId)

        case let .signedWebSocketURL(mint):
            let urlString = try await mint()
            guard let url = URL(string: urlString) else {
                throw ConversationError.authenticationFailed("Invalid signed WebSocket URL")
            }
            // Only reported back through `CallInfo`, so absence falls back to the sentinel.
            let parsedAgentId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "agent_id" }?
                .value
            return (url, parsedAgentId.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown")
        }
    }
}
