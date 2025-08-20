# ElevenLabs Conversational AI Swift SDK

![SwiftSDK](https://github.com/user-attachments/assets/b91ef903-ff1f-4dda-9822-a6afad3437fc)

A Swift SDK for integrating ElevenLabs' conversational AI capabilities into your iOS and macOS applications. Built on top of LiveKit WebRTC for real-time audio streaming and communication.

## Quick Start

### Installation

Add to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/elevenlabs/elevenlabs-swift-sdk.git", from: "2.0.11")
]
```

### Basic Usage

```swift
import ElevenLabs

// 1. Start a conversation with your agent
let conversation = try await ElevenLabs.startConversation(
    agentId: "your-agent-id",
    config: ConversationConfig()
)

// 2. Observe conversation state and messages
conversation.$state
    .sink { state in
        print("Connection state: \(state)")
    }
    .store(in: &cancellables)

conversation.$messages
    .sink { messages in
        for message in messages {
            print("\(message.role): \(message.content)")
        }
    }
    .store(in: &cancellables)

// 3. Send messages and control the conversation
try await conversation.sendMessage("Hello!")
try await conversation.toggleMute()
await conversation.endConversation()
```

### Requirements

- iOS 14.0+ / macOS 11.0+
- Swift 5.9+
- Add `NSMicrophoneUsageDescription` to your Info.plist

## Core Features

### Real-time Conversation Management

The SDK provides a streamlined `Conversation` class that handles all aspects of real-time communication:

```swift
import ElevenLabs
import LiveKit

@MainActor
class ConversationManager: ObservableObject {
    @Published var conversation: Conversation?
    private var cancellables = Set<AnyCancellable>()

    func startConversation(agentId: String) async throws {
        let config = ConversationConfig(
            conversationOverrides: ConversationOverrides(textOnly: false)
        )

        conversation = try await ElevenLabs.startConversation(
            agentId: agentId,
            config: config
        )

        setupObservers()
    }

    private func setupObservers() {
        guard let conversation else { return }

        // Monitor connection state
        conversation.$state
            .sink { state in
                print("State: \(state)")
            }
            .store(in: &cancellables)

        // Monitor messages
        conversation.$messages
            .sink { messages in
                print("Messages: \(messages.count)")
            }
            .store(in: &cancellables)

        // Monitor agent state
        conversation.$agentState
            .sink { agentState in
                print("Agent: \(agentState)")
            }
            .store(in: &cancellables)

        // Handle client tool calls
        conversation.$pendingToolCalls
            .sink { toolCalls in
                for toolCall in toolCalls {
                    Task {
                        await handleToolCall(toolCall)
                    }
                }
            }
            .store(in: &cancellables)
    }
}
```

### Client Tool Support

Handle tool calls from your agent with full parameter support:

```swift
private func handleToolCall(_ toolCall: ClientToolCallEvent) async {
    do {
        let parameters = try toolCall.getParameters()

        let result = await executeClientTool(
            name: toolCall.toolName,
            parameters: parameters
        )

        if toolCall.expectsResponse {
            try await conversation?.sendToolResult(
                for: toolCall.toolCallId,
                result: result
            )
        } else {
            conversation?.markToolCallCompleted(toolCall.toolCallId)
        }
    } catch {
        // Handle tool execution errors
        if toolCall.expectsResponse {
            try? await conversation?.sendToolResult(
                for: toolCall.toolCallId,
                result: ["error": error.localizedDescription],
                isError: true
            )
        }
    }
}

private func executeClientTool(name: String, parameters: [String: Any]) async -> String {
    switch name {
    case "get_weather":
        let location = parameters["location"] as? String ?? "Unknown"
        return "Weather in \(location): 22°C, Sunny"

    case "get_time":
        return "Current time: \(Date().ISO8601Format())"

    case "alert_tool":
        return "User clicked something"

    default:
        return "Unknown tool: \(name)"
    }
}
```

### Authentication Methods

#### Public Agents

```swift
let conversation = try await ElevenLabs.startConversation(
    agentId: "your-public-agent-id",
    config: ConversationConfig()
)
```

#### Private Agents with Conversation Token

```swift
// Option 1: Direct method (recommended)
// Get a conversatoin token from your backend (never store API keys in your app)
let token = try await fetchConversationToken()

let conversation = try await ElevenLabs.startConversation(
    conversationToken: token,
    config: ConversationConfig()
)

// Option 2: Using auth configuration
let conversation = try await ElevenLabs.startConversation(
    auth: .conversationToken(token),
    config: ConversationConfig()
)
```

#### Complete Private Agent Example

Here's a complete example showing how to fetch tokens and connect to private agents:

```swift
import Foundation

// Token service for fetching conversation tokens
actor TokenService {
    private let apiKey: String
    private let baseURL = "https://api.us.elevenlabs.io/v1/convai/conversation/token"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func fetchConversationToken(for agentId: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)?agent_id=\(agentId)") else {
            throw TokenServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TokenServiceError.apiError
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return tokenResponse.token
    }
}

struct TokenResponse: Codable {
    let token: String
}

enum TokenServiceError: Error {
    case invalidURL
    case apiError
}

// Usage in your app
class ConversationManager {
    private let tokenService = TokenService(apiKey: "your-api-key")
    private let agentId = "your-private-agent-id"

    func startPrivateAgentConversation() async throws -> Conversation {
        // Fetch token from ElevenLabs API
        let token = try await tokenService.fetchConversationToken(for: agentId)

        // Start conversation with private agent
        return try await ElevenLabs.startConversation(
            conversationToken: token,
            config: ConversationConfig()
        )
    }
}
```

### Voice and Text Modes

```swift
// Voice conversation (default)
let voiceConfig = ConversationConfig(
    conversationOverrides: ConversationOverrides(textOnly: false)
)

// Text-only conversation
let textConfig = ConversationConfig(
    conversationOverrides: ConversationOverrides(textOnly: true)
)

let conversation = try await ElevenLabs.startConversation(
    agentId: agentId,
    config: textConfig
)
```

### Audio Controls

```swift
// Microphone control
try await conversation.toggleMute()
try await conversation.setMuted(true)

// Check microphone state
let isMuted = conversation.isMuted

// Access audio tracks for advanced use cases
let inputTrack = conversation.inputTrack
let agentAudioTrack = conversation.agentAudioTrack
```

## Architecture

The SDK is built with modern Swift patterns and reactive programming:

```
ElevenLabs (Main Module)
├── Conversation (Core conversation management)
├── ConnectionManager (LiveKit WebRTC integration)
├── DataChannelReceiver (Real-time message handling)
├── EventParser/EventSerializer (Protocol implementation)
├── TokenService (Authentication and connection details)
└── Dependencies (Dependency injection container)
```

### Key Components

- **Conversation**: Main class providing `@Published` properties for reactive UI updates
- **ConnectionManager**: Manages LiveKit room connections and audio streaming
- **DataChannelReceiver**: Handles incoming protocol events from ElevenLabs agents
- **EventParser/EventSerializer**: Handles protocol event parsing and serialization
- **ClientToolCallEvent**: Represents tool calls from agents with parameter extraction

## Advanced Usage

### Message Handling

The SDK provides automatic message management with reactive updates:

```swift
conversation.$messages
    .sink { messages in
        // Update your UI with the latest messages
        self.chatMessages = messages.map { message in
            ChatMessage(
                id: message.id,
                content: message.content,
                isFromAgent: message.role == .agent
            )
        }
    }
    .store(in: &cancellables)
```

### Agent State Monitoring

```swift
conversation.$agentState
    .sink { state in
        switch state {
        case .listening:
            // Agent is listening, show listening indicator
            break
        case .speaking:
            // Agent is speaking, show speaking indicator
            break
        }
    }
    .store(in: &cancellables)
```

### Connection State Management

```swift
conversation.$state
    .sink { state in
        switch state {
        case .idle:
            // Not connected
            break
        case .connecting:
            // Show connecting indicator
            break
        case .active(let callInfo):
            // Connected to agent: \(callInfo.agentId)
            break
        case .ended(let reason):
            // Handle disconnection: \(reason)
            break
        case .error(let error):
            // Handle error: \(error)
            break
        }
    }
    .store(in: &cancellables)
```

### SwiftUI Integration

```swift
import SwiftUI
import ElevenLabs
import LiveKit
import Combine

struct ConversationView: View {
    @StateObject private var viewModel = ConversationViewModel()

    var body: some View {
        VStack {
            // Chat messages
            ScrollView {
                LazyVStack {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message)
                    }
                }
            }

            // Controls
            HStack {
                Button(viewModel.isConnected ? "End" : "Start") {
                    Task {
                        if viewModel.isConnected {
                            await viewModel.endConversation()
                        } else {
                            await viewModel.startConversation()
                        }
                    }
                }

                Button(viewModel.isMuted ? "Unmute" : "Mute") {
                    Task {
                        await viewModel.toggleMute()
                    }
                }
                .disabled(!viewModel.isConnected)
            }
        }
        .task {
            await viewModel.setup()
        }
    }
}

@MainActor
class ConversationViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isConnected = false
    @Published var isMuted = false

    private var conversation: Conversation?
    private var cancellables = Set<AnyCancellable>()

    func setup() async {
        // Initialize your conversation manager
    }

    func startConversation() async {
        do {
            conversation = try await ElevenLabs.startConversation(
                agentId: "your-agent-id",
                config: ConversationConfig()
            )
            setupObservers()
        } catch {
            print("Failed to start conversation: \(error)")
        }
    }

    private func setupObservers() {
        guard let conversation else { return }

        conversation.$messages
            .assign(to: &$messages)

        conversation.$state
            .map { $0.isActive }
            .assign(to: &$isConnected)

        conversation.$isMuted
            .assign(to: &$isMuted)
    }
}
```
