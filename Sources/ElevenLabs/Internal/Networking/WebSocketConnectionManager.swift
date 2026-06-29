import Foundation

/// Transport for text-only conversations.
///
/// Opens a single `URLSessionWebSocketTask` to the text conversation endpoint,
/// sends `conversationInit` once the socket is open, then runs a receive loop
/// that parses incoming JSON into `IncomingEvent`s and forwards them via
/// `onEventReceived`. On runtime socket error, fires `onDisconnected` once.
///
/// Used instead of `WebRTCConnectionManager` because the WebRTC transport
/// drops rooms with no audio — text-only needs a transport that stays open
/// without media.
final class WebSocketConnectionManager: WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onDisconnected: (() async -> Void)?
    var errorHandler: ((Swift.Error?) -> Void)?

    private let urlSession: URLSession
    private let logger: any Logging
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(logger: any Logging) {
        self.logger = logger
        urlSession = URLSession(configuration: .default)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    func connect(auth: ElevenLabsConfiguration, options: ConversationOptions) async throws -> StartupResult {
        let startTime = Date()
        var metrics = ConversationStartupMetrics()

        let url: URL
        do {
            url = try Self.url(for: auth)
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            let convError = error as? ConversationError ?? .authenticationFailed(error.localizedDescription)
            throw StartupFailure.token(convError, metrics)
        }

        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()

        // The first send awaits the WebSocket handshake internally —
        // any connection failure surfaces here.
        do {
            let initEvent = ConversationInitEvent(config: options.toConversationConfig())
            try await send(data: EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent)))
        } catch is CancellationError {
            tearDownTask(task)
            throw CancellationError()
        } catch {
            tearDownTask(task)
            metrics.total = Date().timeIntervalSince(startTime)
            let convError = error as? ConversationError ?? .connectionFailed(error)
            throw StartupFailure.conversationInit(convError, metrics)
        }

        // Socket is up and the init message is sent. Start consuming responses.
        receiveTask = Task { [weak self, weak task] in
            guard let self, let task else { return }
            await receiveLoop(task: task)
        }

        metrics.conversationInitAttempts = 1
        metrics.total = Date().timeIntervalSince(startTime)
        return StartupResult(agentId: auth.agentId, metrics: metrics)
    }

    func send(data: Data) async throws {
        guard let task else {
            throw ConnectionManagerError.notConnected
        }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func disconnect() async {
        onEventReceived = nil
        onDisconnected = nil
        errorHandler = nil

        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func tearDownTask(_ task: URLSessionWebSocketTask) {
        task.cancel(with: .normalClosure, reason: nil)
        if self.task === task {
            self.task = nil
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    handleIncomingData(Data(text.utf8), logger: logger)
                case .data:
                    logger.warning("Ignoring binary WebSocket message")
                @unknown default:
                    logger.warning("Unknown WebSocket message type")
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.task = nil
                errorHandler?(error)
                await onDisconnected?()
                return
            }
        }
    }

    static func url(for auth: ElevenLabsConfiguration) throws -> URL {
        switch auth.authSource {
        case let .publicAgentId(agentId):
            var components = URLComponents(string: ConnectionConstants.textConversationUrl)
            components?.queryItems = [URLQueryItem(name: "agent_id", value: agentId)]
            guard let url = components?.url else {
                throw ConversationError.authenticationFailed("Invalid conversation URL")
            }
            return url

        case let .signedWebSocketURL(urlString, _):
            guard let url = URL(string: urlString) else {
                throw ConversationError.authenticationFailed("Invalid signed WebSocket URL")
            }
            return url

        case .conversationToken, .customTokenProvider:
            throw ConversationError.authenticationFailed(
                "Text-only conversations require a public agent ID or signed WebSocket URL."
            )
        }
    }
}
