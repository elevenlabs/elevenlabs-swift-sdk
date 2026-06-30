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
@MainActor
final class WebSocketConnectionManager: WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onRawMessage: (@Sendable (Data, IncomingEvent?) -> Void)?
    var onDisconnected: (() async -> Void)?

    /// Reports startup-phase transitions during `connect`.
    var onStartupPhaseChange: ((StartupPhase) -> Void)?

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

    func connect(auth: ConversationAuth, config: ConversationConfig) async throws {
        let endpoints = config.endpoints

        // Authorizing: build/validate the WebSocket URL from `auth`.
        onStartupPhaseChange?(.authorizing)

        let url: URL
        do {
            url = try Self.url(for: auth, base: endpoints.textWebSocket, environment: config.environment)
        } catch {
            let convError = error as? ConversationError ?? .authenticationFailed(error.localizedDescription)
            throw ConversationStartupFailure.token(convError)
        }

        // Connecting: open the socket (the handshake completes on first send).
        onStartupPhaseChange?(.connecting)

        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()

        // Sending the conversation_initiation_client_data handshake. The first
        // send awaits the WebSocket handshake internally — any connection
        // failure surfaces here.
        onStartupPhaseChange?(.sendingInitData)
        do {
            let initEvent = ConversationInitEvent(config: config)
            try await send(data: EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent)))
        } catch is CancellationError {
            tearDownTask(task)
            throw CancellationError()
        } catch {
            tearDownTask(task)
            let convError = error as? ConversationError ?? .connectionFailed(error)
            throw ConversationStartupFailure.conversationInit(convError)
        }

        // Socket is up and the init message is sent. Start consuming responses.
        receiveTask = Task { [weak self, weak task] in
            guard let self, let task else { return }
            await receiveLoop(task: task)
        }
    }

    func send(data: Data) async throws {
        guard let task else {
            throw ConnectionManagerError.notConnected
        }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func disconnect() async {
        onEventReceived = nil
        onRawMessage = nil
        onDisconnected = nil
        onStartupPhaseChange = nil

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
                logger.error("WebSocket receive failed", context: ["error": "\(error)"])
                await onDisconnected?()
                return
            }
        }
    }

    static func url(for auth: ConversationAuth, base: URL, environment: String? = nil) throws -> URL {
        switch auth.authSource {
        case let .publicAgentId(agentId):
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw ConversationError.invalidURL
            }
            var queryItems = [
                URLQueryItem(name: "agent_id", value: agentId)
            ]
            if let environment {
                queryItems.append(URLQueryItem(name: "environment", value: environment))
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw ConversationError.invalidURL
            }
            return url

        case let .signedWebSocketURL(urlString, _):
            guard let url = URL(string: urlString) else {
                throw ConversationError.authenticationFailed("Invalid signed WebSocket URL")
            }
            return url

        case .conversationToken:
            throw ConversationError.authenticationFailed(
                "Text-only conversations require a public agent ID or signed WebSocket URL."
            )
        }
    }
}
