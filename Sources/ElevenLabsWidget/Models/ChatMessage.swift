#if canImport(UIKit)
import Foundation
import ElevenLabs

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, agent }
    enum Kind: Equatable { case text, voiceTranscript, error, mcpApprovalRequest }
    enum MCPApprovalStatus: Equatable { case approved, rejected }
    
    /// A file the user attached to an outgoing message, rendered inline in the
    /// transcript (image thumbnail or PDF pill).
    struct Attachment: Equatable {
        let fileName: String
        let fileExtension: String
        let previewData: Data?
        
        var isImage: Bool { fileExtension.lowercased() != "pdf" }
        
        /// Custom equality that compares the preview by byte *count* rather than
        /// contents. The preview data never changes for a given attachment, so
        /// this is sufficient to detect a real change while avoiding a
        /// multi-megabyte `Data` memcmp on every message-projection rebuild
        /// (which runs on each streaming delta). See `ChatWidgetViewModel`.
        static func == (lhs: Attachment, rhs: Attachment) -> Bool {
            lhs.fileName == rhs.fileName &&
            lhs.fileExtension == rhs.fileExtension &&
            lhs.previewData?.count == rhs.previewData?.count
        }
    }
    
    /// Stable identity. For SDK-backed bubbles this is the core SDK's
    /// `Message.id`, so the projection survives rebuilds (preserving SwiftUI
    /// diffing / scroll position). Widget-only synthetic bubbles get a fresh id.
    let id: String
    let role: Role
    let kind: Kind
    var eventId: Int?
    var feedbackScore: FeedbackEvent.Score?
    var mcpApprovalRequest: MCPToolApprovalRequest?
    var mcpApprovalStatus: MCPApprovalStatus?
    var content: String
    var attachment: Attachment?
    /// `true` while the underlying SDK message is still streaming/tentative (an
    /// in-progress agent response or live user transcript). Drives the ghost
    /// styling for in-progress user captions.
    var isPartial: Bool
    let timestamp: Date
    
    init(
        id: String = UUID().uuidString,
        role: Role,
        kind: Kind,
        content: String,
        eventId: Int? = nil,
        feedbackScore: FeedbackEvent.Score? = nil,
        mcpApprovalRequest: MCPToolApprovalRequest? = nil,
        mcpApprovalStatus: MCPApprovalStatus? = nil,
        attachment: Attachment? = nil,
        isPartial: Bool = false,
        timestamp: Date = .init()
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.eventId = eventId
        self.feedbackScore = feedbackScore
        self.mcpApprovalRequest = mcpApprovalRequest
        self.mcpApprovalStatus = mcpApprovalStatus
        self.content = content
        self.attachment = attachment
        self.isPartial = isPartial
        self.timestamp = timestamp
    }
}

struct MCPToolApprovalRequest: Equatable, Sendable {
    let toolCallId: String
    let toolName: String
    let toolDescription: String?
    let parameters: [String: ConversationConfigValue]
    let approvalTimeoutSecs: Int?
}

enum ConversationConfigValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: ConversationConfigValue])
    case array([ConversationConfigValue])
    case null

    var stringValue: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
        case .boolean(let value):
            return String(value)
        case .object(let values):
            return values
                .map { "\($0.key): \($0.value.stringValue)" }
                .sorted()
                .joined(separator: ", ")
        case .array(let values):
            return values.map(\.stringValue).joined(separator: ", ")
        case .null:
            return "null"
        }
    }

    static func fromJSONValue(_ value: Any) -> ConversationConfigValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(number.doubleValue)
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues { ConversationConfigValue.fromJSONValue($0) })
        case let array as [Any]:
            return .array(array.map { ConversationConfigValue.fromJSONValue($0) })
        default:
            return .null
        }
    }
}

#endif
