@testable import ElevenLabs
import XCTest

final class ConversationConfigTests: XCTestCase {
    func testDefaultConfiguration() {
        let config = ConversationConfig()

        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertNil(config.conversationOverrides)
    }

    func testConfigurationWithOverrides() {
        var config = ConversationConfig()

        config.agentOverrides = AgentOverrides(
            prompt: "Custom prompt",
            firstMessage: "Hello!",
            language: Language.english
        )

        config.ttsOverrides = TTSOverrides(
            voiceId: "voice123"
        )

        config.conversationOverrides = ConversationOverrides(
            textOnly: true
        )

        XCTAssertNotNil(config.agentOverrides)
        XCTAssertNotNil(config.ttsOverrides)
        XCTAssertNotNil(config.conversationOverrides)
    }

    func testAgentOverrides() {
        let overrides = AgentOverrides(
            prompt: "You are a helpful assistant",
            firstMessage: "How can I help?",
            language: Language.spanish
        )

        XCTAssertEqual(overrides.prompt, "You are a helpful assistant")
        XCTAssertEqual(overrides.firstMessage, "How can I help?")
        XCTAssertEqual(overrides.language, Language.spanish)
    }

    func testTTSOverrides() {
        let overrides = TTSOverrides(
            voiceId: "voice123"
        )

        XCTAssertEqual(overrides.voiceId, "voice123")
    }

    func testConversationOverrides() {
        let overrides = ConversationOverrides(
            textOnly: true
        )

        XCTAssertEqual(overrides.textOnly, true)
    }

    func testLanguageEnum() {
        XCTAssertEqual(Language.english.rawValue, "en")
        XCTAssertEqual(Language.spanish.rawValue, "es")
        XCTAssertEqual(Language.french.rawValue, "fr")
        XCTAssertEqual(Language.german.rawValue, "de")
        XCTAssertEqual(Language.italian.rawValue, "it")
        XCTAssertEqual(Language.portuguese.rawValue, "pt")
        XCTAssertEqual(Language.hindi.rawValue, "hi")
        XCTAssertEqual(Language.japanese.rawValue, "ja")
        XCTAssertEqual(Language.korean.rawValue, "ko")
        XCTAssertEqual(Language.dutch.rawValue, "nl")
        XCTAssertEqual(Language.turkish.rawValue, "tr")
        XCTAssertEqual(Language.polish.rawValue, "pl")
        XCTAssertEqual(Language.swedish.rawValue, "sv")
        XCTAssertEqual(Language.bulgarian.rawValue, "bg")
        XCTAssertEqual(Language.croatian.rawValue, "hr")
        XCTAssertEqual(Language.czech.rawValue, "cs")
        XCTAssertEqual(Language.danish.rawValue, "da")
        XCTAssertEqual(Language.finnish.rawValue, "fi")
        XCTAssertEqual(Language.greek.rawValue, "el")
        XCTAssertEqual(Language.hungarian.rawValue, "hu")
        XCTAssertEqual(Language.indonesian.rawValue, "id")
        XCTAssertEqual(Language.latvian.rawValue, "lv")
        XCTAssertEqual(Language.lithuanian.rawValue, "lt")
        XCTAssertEqual(Language.norwegian.rawValue, "no")
        XCTAssertEqual(Language.romanian.rawValue, "ro")
        XCTAssertEqual(Language.russian.rawValue, "ru")
        XCTAssertEqual(Language.slovak.rawValue, "sk")
        XCTAssertEqual(Language.slovenian.rawValue, "sl")
        XCTAssertEqual(Language.tagalog.rawValue, "tl")
        XCTAssertEqual(Language.ukrainian.rawValue, "uk")
        XCTAssertEqual(Language.chinese.rawValue, "zh")
    }
}
