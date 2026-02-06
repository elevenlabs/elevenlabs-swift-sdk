import Foundation

/// A protocol that defines a message sender.
///
/// A message sender is responsible for sending messages to the agent.
/// It is used to send messages to the agent and update the message feed.
///
/// - SeeAlso: ``SentMessage``
protocol MessageSender: Sendable {
    func send(_ message: SentMessage) async throws
}
