# ElevenLabs Conversational AI Swift SDK

![SwiftSDK](https://github.com/user-attachments/assets/b91ef903-ff1f-4dda-9822-a6afad3437fc)

A Swift SDK for integrating ElevenLabs' conversational AI capabilities into your iOS and macOS applications. Built on top of LiveKit WebRTC for real-time audio streaming and communication.

## Quick Start

### Requirements

- Xcode (minimum 16.3)

### Installation

Add to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/elevenlabs/elevenlabs-swift-sdk.git", from: "2.0.17")
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
- Add `NSCameraUsageDescription` to your Info.plist. Your app won't fail to work in development but uploading to App Store Connect will fail without this.

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

        // Monitor MCP (Model Context Protocol) tool calls
        conversation.$mcpToolCalls
            .sink { mcpCalls in
                for call in mcpCalls {
                    print("MCP tool: \(call.toolName) - \(call.state)")
                    // Approve/reject if awaiting approval
                    if call.state == .awaitingApproval {
                        try? await conversation.sendMCPToolApproval(
                            toolCallId: call.toolCallId,
                            isApproved: true
                        )
                    }
                }
            }
            .store(in: &cancellables)

        // Monitor MCP connection status
        conversation.$mcpConnectionStatus
            .sink { status in
                if let status = status {
                    for integration in status.integrations {
                        print("MCP \(integration.integrationType): \(integration.isConnected ? "connected" : "disconnected")")
                    }
                }
            }
            .store(in: &cancellables)

        // Monitor conversation metadata (includes conversation ID)
        conversation.$conversationMetadata
            .compactMap { $0 }
            .sink { metadata in
                print("Conversation ID: \(metadata.conversationId)")
                print("Agent audio format: \(metadata.agentOutputAudioFormat)")
                if let userFormat = metadata.userInputAudioFormat {
                    print("User audio format: \(userFormat)")
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

### Accessing Conversation Metadata

The conversation metadata (including conversation ID) is available after the conversation is initialized:

```swift
// Access conversation metadata directly
if let metadata = conversation.conversationMetadata {
    let conversationId = metadata.conversationId
    let agentAudioFormat = metadata.agentOutputAudioFormat
    let userAudioFormat = metadata.userInputAudioFormat // Optional
}

// Or observe it reactively
conversation.$conversationMetadata
    .compactMap { $0 }
    .sink { metadata in
        // Store or use the conversation ID
        self.currentConversationId = metadata.conversationId

        // Log conversation details
        print("Started conversation: \(metadata.conversationId)")
    }
    .store(in: &cancellables)
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

## Configuration & Callbacks

### Error Handling

The SDK provides comprehensive error handling through the `onError` callback:

```swift
let config = ConversationConfig(
    onError: { error in
        print("SDK Error: \(error.localizedDescription)")
        // Handle different error types
        switch error {
        case .notConnected:
            // Show "not connected" message
            break
        case .connectionFailed(let reason):
            // Handle connection failure
            print("Connection failed: \(reason)")
        case .authenticationFailed(let reason):
            // Handle auth error
            print("Auth failed: \(reason)")
        case .agentTimeout:
            // Agent took too long to respond
            break
        case .localNetworkPermissionRequired:
            // User needs to grant local network permission
            break
        }
    }
)
```

### Startup State Monitoring

Monitor the conversation startup progress with detailed state transitions:

```swift
let config = ConversationConfig(
    onStartupStateChange: { state in
        switch state {
        case .idle:
            print("Not started")
        case .resolvingToken:
            print("Fetching authentication token...")
        case .connectingToRoom:
            print("Connecting to LiveKit room...")
        case .waitingForAgent(let timeout):
            print("Waiting for agent (timeout: \(timeout)s)...")
        case .agentReady(let report):
            print("Agent ready in \(report.elapsed)s")
            if report.viaGraceTimeout {
                print("  (via grace timeout)")
            }
        case .sendingConversationInit:
            print("Sending conversation initialization...")
        case .active(let callInfo, let metrics):
            print("✅ Connected to agent: \(callInfo.agentId)")
            print("   Total startup time: \(metrics.total)s")
            print("   - Token fetch: \(metrics.tokenFetch ?? 0)s")
            print("   - Room connect: \(metrics.roomConnect ?? 0)s")
            print("   - Agent ready: \(metrics.agentReady ?? 0)s")
            print("   - Init: \(metrics.conversationInit ?? 0)s")
            print("   - Attempts: \(metrics.conversationInitAttempts)")
        case .failed(let stage, let metrics):
            print("❌ Failed at \(stage)")
            print("   Total time: \(metrics.total)s")
        }
    }
)
```

### Conversation Event Callbacks

Listen to fine-grained conversation events:

```swift
let config = ConversationConfig(
    // Agent response events
    onAgentResponse: { text, eventId in
        print("Agent said: \(text) [event: \(eventId)]")
    },

    // Agent response corrections (when agent self-corrects)
    onAgentResponseCorrection: { original, corrected, eventId in
        print("Agent corrected: '\(original)' → '\(corrected)'")
    },

    // User transcript events
    onUserTranscript: { text, eventId in
        print("You said: \(text) [event: \(eventId)]")
    },

    // Interruption detection
    onInterruption: { eventId in
        print("User interrupted agent [event: \(eventId)]")
    },

    // Feedback availability tracking
    onCanSendFeedbackChange: { canSend in
        // Enable/disable feedback UI based on whether feedback can be sent
        self.showFeedbackButton = canSend
    }
)
```

### Audio Alignment & Word Highlighting

Get word-level timing information to highlight text as the agent speaks:

```swift
let config = ConversationConfig(
    onAudioAlignment: { alignment in
        // alignment.chars: ["H", "e", "l", "l", "o"]
        // alignment.charStartTimesMs: [0, 100, 150, 200, 250]
        // alignment.charDurationsMs: [100, 50, 50, 50, 100]

        // Example: Highlight text character by character
        for (index, char) in alignment.chars.enumerated() {
            let startMs = alignment.charStartTimesMs[index]
            let durationMs = alignment.charDurationsMs[index]

            Task {
                try? await Task.sleep(nanoseconds: UInt64(startMs * 1_000_000))
                await highlightCharacter(at: index, duration: durationMs)
            }
        }
    }
)
```

### Audio Pipeline Configuration

Control microphone behavior and voice processing:

```swift
let audioConfig = AudioPipelineConfiguration(
    // Microphone mute strategy
    // - .voiceProcessing: Mute by stopping voice processing
    // - .restart: Mute by restarting the audio session
    // - .inputMixer: Mute at the input mixer level (default)
    microphoneMuteMode: .inputMixer,

    // Keep mic warm to avoid first-word latency (default: true)
    recordingAlwaysPrepared: true,

    // Bypass WebRTC voice processing (AEC/NS/VAD)
    // Set to true if you want raw audio without processing
    voiceProcessingBypassed: false,

    // Enable Auto Gain Control for consistent volume
    voiceProcessingAGCEnabled: true,

    // Detect speech while muted (useful for "tap to speak" UX)
    onSpeechActivity: { event in
        print("Speech detected while muted!")
        // Show visual indicator that user is trying to speak
    }
)

let config = ConversationConfig(
    audioConfiguration: audioConfig
)
```

### Startup Configuration

Fine-tune the connection handshake behavior:

```swift
let startupConfig = ConversationStartupConfiguration(
    // How long to wait for agent to be ready (default: 3.0s)
    agentReadyTimeout: 5.0,

    // Retry delays for conversation init in seconds (default: [0, 0.5, 1.0])
    // First attempt: immediate, 2nd: wait 0.5s, 3rd: wait 1.0s, etc.
    initRetryDelays: [0, 0.5, 1.0, 2.0],

    // Whether to fail if agent isn't ready in time (default: false)
    // false = continue with grace period, true = throw error immediately
    failIfAgentNotReady: false
)

let config = ConversationConfig(
    startupConfiguration: startupConfig
)
```

### Voice Activity Detection (VAD)

Monitor real-time voice activity scores:

```swift
let config = ConversationConfig(
    onVadScore: { score in
        // score: 0.0 to 1.0 (higher = more speech detected)
        updateVoiceActivityIndicator(score)
    }
)
```

### Complete Configuration Example

```swift
let config = ConversationConfig(
    // Core callbacks
    onAgentReady: {
        print("✅ Agent is ready!")
    },
    onDisconnect: { reason in
        print("🔌 Disconnection reason: \(reason)")
    },
    onError: { error in
        print("❌ Error: \(error.localizedDescription)")
    },

    // Startup monitoring
    onStartupStateChange: { state in
        print("Startup: \(state)")
    },

    // Event callbacks
    onAgentResponse: { text, eventId in
        print("Agent: \(text)")
    },
    onUserTranscript: { text, eventId in
        print("User: \(text)")
    },
    onInterruption: { eventId in
        print("Interrupted!")
    },

    // Advanced features
    onAudioAlignment: { alignment in
        // Highlight words as agent speaks
    },
    onCanSendFeedbackChange: { canSend in
        // Enable/disable feedback button
    },

    // Audio pipeline
    audioConfiguration: AudioPipelineConfiguration(
        microphoneMuteMode: .inputMixer,
        recordingAlwaysPrepared: true,
        voiceProcessingBypassed: false,
        voiceProcessingAGCEnabled: true
    ),

    // Network configuration
    networkConfiguration: LiveKitNetworkConfiguration(
        strategy: .automatic
    ),

    // Startup tuning
    startupConfiguration: ConversationStartupConfiguration(
        agentReadyTimeout: 5.0,
        initRetryDelays: [0, 0.5, 1.0, 2.0]
    )
)

let conversation = try await ElevenLabs.startConversation(
    agentId: "your-agent-id",
    config: config
)
```
