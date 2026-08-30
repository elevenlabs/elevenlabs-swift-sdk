import ElevenLabs
import XCTest

final class AudioTagTests: XCTestCase {
    func testStripAudioTagsRemovesSingleAndMultiWordTags() {
        XCTAssertEqual(
            ElevenLabs.stripAudioTags(from: "[warmlyly] Hello [clears throat] there"),
            "Hello there"
        )
    }

    func testStripAudioTagsPreservesMarkdownLinks() {
        XCTAssertEqual(
            ElevenLabs.stripAudioTags(from: "[happy] Read the [docs](https://example.com)"),
            "Read the [docs](https://example.com)"
        )
    }

    func testStripAudioTagsPreservesUnsupportedBracketedContent() {
        XCTAssertEqual(
            ElevenLabs.stripAudioTags(from: "See [Chapter 4: Introduction]"),
            "See [Chapter 4: Introduction]"
        )
    }

    func testStripAudioTagsTrimsTheResult() {
        XCTAssertEqual(ElevenLabs.stripAudioTags(from: "  [sighs] Hello  "), "Hello")
        XCTAssertEqual(ElevenLabs.stripAudioTags(from: "[laughs]"), "")
    }
}
