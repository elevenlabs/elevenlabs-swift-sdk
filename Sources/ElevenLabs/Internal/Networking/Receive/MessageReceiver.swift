import Foundation

/// A protocol that defines a message receiver.
///
/// A message receiver is responsible for creating a stream of messages from the agent.
/// It is used to receive messages from the agent and update the message feed.
///
/// - SeeAlso: ``ReceivedMessage``
protocol MessageReceiver: Sendable {
    func messages() async throws -> AsyncStream<ReceivedMessage>
}
