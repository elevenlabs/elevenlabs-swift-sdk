#if canImport(UIKit)
import Foundation

public enum WidgetConversationMode: String, CaseIterable, Identifiable {
    case textOnly
    case voiceOnly
    case voiceAndText
    case voiceAndTextWithTextOnly
    
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .textOnly:
            return "Text-only"
        case .voiceOnly:
            return "Voice-only"
        case .voiceAndText:
            return "Voice & Text"
        case .voiceAndTextWithTextOnly:
            return "Voice & Text + Text-only"
        }
    }

    public var supportsVoice: Bool {
        switch self {
        case .textOnly:
            return false
        case .voiceOnly, .voiceAndText, .voiceAndTextWithTextOnly:
            return true
        }
    }
    
    public var supportsTextInput: Bool {
        switch self {
        case .voiceOnly:
            return false
        case .textOnly, .voiceAndText, .voiceAndTextWithTextOnly:
            return true
        }
    }
}

public struct ChatWidgetConfig: Equatable {
    public var conversationMode: WidgetConversationMode
    public var showBackdrop: Bool
    public var strings: ChatWidgetStrings
    public var theme: ChatWidgetTheme
    public var terms: ChatWidgetTerms
    public var collectFeedbackAfterCall: Bool
    public var enableInConversationFeedback: Bool
    public var enableTermsAndConditions: Bool
    public var enableFileUpload: Bool
    public var enableMicMuteControl: Bool
    public var sendUserActivityOnTyping: Bool
    public var userActivityThrottleInterval: TimeInterval
    public var showVoiceMessages: Bool
    public var showTentativeUserTranscript: Bool
    
    public init(
        conversationMode: WidgetConversationMode,
        showBackdrop: Bool = ChatWidgetConfig.default.showBackdrop,
        collectFeedbackAfterCall: Bool = ChatWidgetConfig.default.collectFeedbackAfterCall,
        enableInConversationFeedback: Bool = ChatWidgetConfig.default.enableInConversationFeedback,
        enableTermsAndConditions: Bool = ChatWidgetConfig.default.enableTermsAndConditions,
        enableFileUpload: Bool = ChatWidgetConfig.default.enableFileUpload,
        enableMicMuteControl: Bool = ChatWidgetConfig.default.enableMicMuteControl,
        sendUserActivityOnTyping: Bool = ChatWidgetConfig.default.sendUserActivityOnTyping,
        userActivityThrottleInterval: TimeInterval = ChatWidgetConfig.default.userActivityThrottleInterval,
        showVoiceMessages: Bool = ChatWidgetConfig.default.showVoiceMessages,
        showTentativeUserTranscript: Bool = ChatWidgetConfig.default.showTentativeUserTranscript,
        strings: ChatWidgetStrings = .default,
        theme: ChatWidgetTheme = .default,
        terms: ChatWidgetTerms = .default
    ) {
        self.conversationMode = conversationMode
        self.showBackdrop = showBackdrop
        self.collectFeedbackAfterCall = collectFeedbackAfterCall
        self.enableInConversationFeedback = enableInConversationFeedback
        self.enableTermsAndConditions = enableTermsAndConditions
        self.enableFileUpload = enableFileUpload
        self.enableMicMuteControl = enableMicMuteControl
        self.sendUserActivityOnTyping = sendUserActivityOnTyping
        self.userActivityThrottleInterval = userActivityThrottleInterval
        self.showVoiceMessages = showVoiceMessages
        self.showTentativeUserTranscript = showTentativeUserTranscript
        self.strings = strings
        self.theme = theme
        self.terms = terms
    }

    public static let `default` = ChatWidgetConfig(
        conversationMode: .voiceAndTextWithTextOnly,
        showBackdrop: true,
        collectFeedbackAfterCall: true,
        enableInConversationFeedback: false,
        enableTermsAndConditions: false,
        enableFileUpload: false,
        enableMicMuteControl: true,
        sendUserActivityOnTyping: true,
        userActivityThrottleInterval: 1,
        showVoiceMessages: true,
        showTentativeUserTranscript: true,
        strings: .default,
        theme: .default,
        terms: .default
    )

    public static let voiceOnly = ChatWidgetConfig(
        conversationMode: .voiceOnly,
        showBackdrop: true,
        collectFeedbackAfterCall: true,
        enableInConversationFeedback: false,
        enableTermsAndConditions: false,
        enableFileUpload: false,
        enableMicMuteControl: true,
        sendUserActivityOnTyping: true,
        userActivityThrottleInterval: 1,
        showVoiceMessages: true,
        showTentativeUserTranscript: true,
        strings: .default,
        theme: .default,
        terms: .default
    )

    public static let textOnly = ChatWidgetConfig(
        conversationMode: .textOnly,
        showBackdrop: true,
        collectFeedbackAfterCall: true,
        enableInConversationFeedback: false,
        enableTermsAndConditions: false,
        enableFileUpload: false,
        enableMicMuteControl: false,
        sendUserActivityOnTyping: true,
        userActivityThrottleInterval: 1,
        showVoiceMessages: false,
        showTentativeUserTranscript: true,
        strings: .default,
        theme: .default,
        terms: .default
    )
}

#endif
