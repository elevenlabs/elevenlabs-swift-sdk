# ElevenLabs Conversational AI Swift SDK

<img src="https://github.com/user-attachments/assets/ca4fa726-5e98-4bbc-91b2-d055e957df7d" alt="ElevenLabs ConvAI" width="400">

A Swift SDK for integrating ElevenLabs' conversational AI capabilities into your iOS and macOS applications. Built on top of LiveKit WebRTC for real-time audio streaming and communication.

[![Swift Package Manager](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey.svg)](https://github.com/elevenlabs/ElevenLabsSwift)

## Quick Start

### Installation

Add to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/elevenlabs/ElevenLabsSwift.git", from: "1.2.0")
]
```

### Basic Usage

```swift
import ElevenLabsSwift

// 1. Configure your session
let config = ElevenLabsSDK.SessionConfig(agentId: "your-agent-id")

// 2. Set up callbacks
var callbacks = ElevenLabsSDK.Callbacks()
callbacks.onConnect = { conversationId in
    print("🟢 Connected: \(conversationId)")
}
callbacks.onMessage = { message, role in
    print("💬 \(role.rawValue): \(message)")
}
callbacks.onError = { error, _ in
    print("❌ Error: \(error)")
}

// 3. Start conversation
Task {
    do {
        let conversation = try await ElevenLabsSDK.startSession(
            config: config,
            callbacks: callbacks
        )

        // Send messages
        conversation.sendUserMessage("Hello!")
        conversation.sendContextualUpdate("User is in the kitchen")

        // Control recording
        conversation.startRecording()
        conversation.stopRecording()

        // End session
        conversation.endSession()
    } catch {
        print("Failed to start conversation: \(error)")
    }
}
```

### Requirements

- iOS 16.0+ / macOS 10.15+
- Swift 5.9+
- Add `NSMicrophoneUsageDescription` to your Info.plist

## Advanced Features

### Client Tools

Register custom tools that your agent can call:

```swift
var clientTools = ElevenLabsSDK.ClientTools()
clientTools.register("get_weather") { parameters in
    let location = parameters["location"] as? String ?? "Unknown"
    return "The weather in \(location) is sunny, 72°F"
}

let conversation = try await ElevenLabsSDK.startSession(
    config: config,
    callbacks: callbacks,
    clientTools: clientTools
)
```

### Agent Configuration

Override agent settings:

```swift
let overrides = ElevenLabsSDK.ConversationConfigOverride(
    agent: ElevenLabsSDK.AgentConfig(
        prompt: ElevenLabsSDK.AgentPrompt(prompt: "You are a helpful cooking assistant"),
        language: .en,
        firstMessage: "Hello! How can I help you cook today?"
    ),
    tts: ElevenLabsSDK.TTSConfig(voiceId: "your-voice-id")
)

let config = ElevenLabsSDK.SessionConfig(
    agentId: "your-agent-id",
    overrides: overrides
)
```

### Audio Controls

```swift
// Volume management
conversation.conversationVolume = 0.8
let inputLevel = conversation.getInputVolume()
let outputLevel = conversation.getOutputVolume()

// Recording controls
conversation.startRecording()
conversation.stopRecording()

// Volume callbacks
callbacks.onVolumeUpdate = { level in
    print("🎤 Input: \(level)")
}
callbacks.onOutputVolumeUpdate = { level in
    print("🔊 Output: \(level)")
}
```

## Architecture

The SDK is built with clean architecture principles:

```
ElevenLabsSDK (Main API)
├── LiveKitConversation (WebRTC Management)
├── RTCLiveKitAudioManager (Audio Streaming)
├── DataChannelManager (Message Handling)
└── NetworkService (Token Management)
```

## Examples

Check out complete examples in the [ElevenLabs Examples repository](https://github.com/elevenlabs/elevenlabs-examples/tree/main/examples/conversational-ai/swift).

## Contributing

We welcome contributions! Please check out our [Contributing Guide](CONTRIBUTING.md) and join us in the [ElevenLabs Discord](https://discord.gg/elevenlabs).

## License

This SDK is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Support

- 📚 [Documentation](https://elevenlabs.io/docs/conversational-ai/libraries/conversational-ai-sdk-swift)
- 💬 [Discord Community](https://discord.gg/elevenlabs)
- 🐛 [Issues](https://github.com/elevenlabs/ElevenLabsSwift/issues)
- 📧 [Support Email](mailto:support@elevenlabs.io)
