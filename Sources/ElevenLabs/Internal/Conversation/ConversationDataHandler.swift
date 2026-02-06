import Foundation

/// Actor responsible for handling data parsing and serialization off the main thread.
actor ConversationDataHandler {
    /// Parse incoming JSON data into an IncomingEvent
    func parseIncomingEvent(from data: Data) throws -> IncomingEvent? {
        try EventParser.parseIncomingEvent(from: data)
    }

    /// Serialize outgoing event into JSON data
    func serializeOutgoingEvent(_ event: OutgoingEvent) throws -> Data {
        try EventSerializer.serializeOutgoingEvent(event)
    }
}
