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

    func testDynamicVariablesAcceptsMixedTypedValues() {
        let config = ConversationConfig(
            dynamicVariables: [
                "customer_name": .string("John Doe"),
                "account_balance": .number(5000.50),
                "user_id": .int(12345),
                "is_premium": .boolean(true)
            ]
        )

        XCTAssertEqual(config.dynamicVariables?["customer_name"], .string("John Doe"))
        XCTAssertEqual(config.dynamicVariables?["account_balance"], .number(5000.50))
        XCTAssertEqual(config.dynamicVariables?["user_id"], .int(12345))
        XCTAssertEqual(config.dynamicVariables?["is_premium"], .boolean(true))
    }

    func testDynamicVariablesAcceptsDictionaryLiterals() {
        let config = ConversationConfig(
            dynamicVariables: [
                "name": "John",
                "id": 123,
                "ok": true,
                "score": 4.5
            ]
        )

        XCTAssertEqual(config.dynamicVariables?["name"], .string("John"))
        XCTAssertEqual(config.dynamicVariables?["id"], .int(123))
        XCTAssertEqual(config.dynamicVariables?["ok"], .boolean(true))
        XCTAssertEqual(config.dynamicVariables?["score"], .number(4.5))
    }

    func testDynamicVariablesAcceptsStringDictionary() {
        let strings: [String: String] = [
            "customer_name": "John Doe",
            "account_id": "abc-123"
        ]
        let config = ConversationConfig(dynamicVariables: strings)

        XCTAssertEqual(config.dynamicVariables?["customer_name"], .string("John Doe"))
        XCTAssertEqual(config.dynamicVariables?["account_id"], .string("abc-123"))
    }

    func testSetDynamicVariablesFromStringDictionary() {
        var config = ConversationConfig()
        config.setDynamicVariables(["user_name": "Ada"])

        XCTAssertEqual(config.dynamicVariables?["user_name"], .string("Ada"))
    }

    func testToConversationOptionsPreservesDynamicVariables() {
        let config = ConversationConfig(
            dynamicVariables: [
                "user_id": .int(5),
                "is_premium": .boolean(true)
            ]
        )
        let options = config.toConversationOptions()

        XCTAssertEqual(options.dynamicVariables?["user_id"], .int(5))
        XCTAssertEqual(options.dynamicVariables?["is_premium"], .boolean(true))

        let roundTrip = options.toConversationConfig()
        XCTAssertEqual(roundTrip.dynamicVariables?["user_id"], .int(5))
        XCTAssertEqual(roundTrip.dynamicVariables?["is_premium"], .boolean(true))
    }

    func testConversationOptionsAcceptsStringDictionary() {
        let strings: [String: String] = ["customer_name": "John Doe"]
        var options = ConversationOptions(dynamicVariables: strings)

        XCTAssertEqual(options.dynamicVariables?["customer_name"], .string("John Doe"))

        options.setDynamicVariables(["account_id": "abc-123"])
        XCTAssertEqual(options.dynamicVariables?["account_id"], .string("abc-123"))
    }
}
