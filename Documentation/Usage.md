# Detailed Usage Documentation

This document provides in-depth examples and advanced configuration options for the ElevenLabs Conversational AI Swift SDK.

---

## Table of Contents

1. [State Management](#state-management)
2. [Text-Only Conversations](#text-only)
3. [Advanced Audio Controls](#advanced-audio-controls)
4. [Tool Calls & MCP](#tool-calls)
5. [Event Callbacks](#event-callbacks)
6. [Audio Pipeline Configuration](#audio-pipeline)
7. [Startup Performance Tuning](#startup-tuning)
8. [Feedback & Context](#feedback-context)
9. [Reconnect & Recovery](#reconnect)
10. [Voice Activity Detection (VAD)](#vad)
11. [Advanced Authentication](#advanced-authentication)
12. [Diagnostics & Troubleshooting](#diagnostics)
13. [Best Practices](#best-practices)

---

## State Management

The `Conversation` object provides reactive `@Published` properties for seamless UI integration.

### Message Handling

Monitor real-time transcriptions for both the agent and the user. The `messages` array is automatically updated.

```swift
conversation.$messages
    .receive(on: DispatchQueue.main)
    .sink { messages in
        // messages are of type [Message]
        // Each message has role (.user or .agent) and content
    }
    .store(in: &cancellables)
```

### Agent State Monitoring

Directly track what the agent is currently doing to show appropriate UI indicators.

```swift
conversation.$agentState
    .sink { state in
        switch state {
        case .listening:
            // Agent is waiting for the user to speak
            break
        case .speaking:
            // Agent is currently talking
            break
        case .thinking:
            // Agent is preparing a tool call or response
            break
        }
    }
    .store(in: &cancellables)
```

### Connection State

Handle transitions between idle, connecting, active, and ended states.

```swift
conversation.$state
    .sink { state in
        switch state {
        case .idle:
            break
        case .connecting:
            break
        case .active(let callInfo):
            print("Connected to agent: \(callInfo.agentId)")
        case .ended(let reason):
            print("Conversation ended: \(reason)")
        case .error(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
    .store(in: &cancellables)
```

---

## Text-Only Conversations {#text-only}

Start a conversation without audio and use text messages only.

```swift
// 1) Start a text-only conversation (no microphone used)
let conversation = try await ElevenLabs.startConversation(
    agentId: "agent_123",
    config: ConversationConfig(
        conversationOverrides: .init(textOnly: true)
    )
)

// 2) Send text messages
try await conversation.sendMessage("Hi! Tell me about the weather.")

// 3) Receive responses (reactive)
conversation.$messages
    .receive(on: DispatchQueue.main)
    .sink { messages in
        guard let last = messages.last, last.role == .agent else { return }
        print("Agent:", last.content)
    }
    .store(in: &cancellables)
```

---

## Advanced Audio Controls

### Microphone Management

Control the user's microphone state directly without needing to manage `AVAudioSession` yourself.

```swift
// Toggle state
try await conversation.toggleMute()

// Set explicitly
try await conversation.setMuted(true)

// Note: setMuted() requires an active connection. Call it after the conversation connects,
// for example in the onAgentReady callback:
let conversation = try await ElevenLabs.startConversation(
    agentId: "agent_123",
    config: .init(
        onAgentReady: {
            Task {
                try? await conversation.setMuted(false) // Unmute when ready
            }
        }
    )
)
```

### Raw Audio Tracks

Access the underlying LiveKit audio tracks for advanced visualization (e.g., audio visualizers or level meters).

```swift
// Use these with LiveKit view components or custom processors
if let inputTrack = conversation.inputTrack as? LocalAudioTrack {
    // Access local microphone track
}

if let agentTrack = conversation.agentAudioTrack as? RemoteAudioTrack {
    // Access agent's audio track
}
```

---

## Tool Calls

### Client Tools

Client tools allow your agent to execute logic within your app. You must register the tools in the ElevenLabs Dashboard first.

```swift
// Observe tool calls using Combine
conversation.$pendingToolCalls
    .receive(on: DispatchQueue.main)
    .sink { [weak conversation] toolCalls in
        guard let conversation else { return }
        for toolCall in toolCalls {
            Task {
                // 1. Parse parameters (JSON)
                let params = (try? toolCall.getParameters()) ?? [:]
                
                // 2. Execute your logic
                let result = await myAppService.execute(toolName: toolCall.toolName, params: params)
                
                // 3. Send result back to agent
                try? await conversation.sendToolResult(
                    for: toolCall.toolCallId,
                    result: result
                )
            }
        }
    }
    .store(in: &cancellables)

// Alternative: Using async/await pattern with observation
Task {
    for await toolCalls in conversation.$pendingToolCalls.values {
        await withTaskGroup(of: Void.self) { group in
            for toolCall in toolCalls {
                group.addTask {
                    let params = (try? toolCall.getParameters()) ?? [:]
                    let result = await myAppService.execute(toolName: toolCall.toolName, params: params)
                    try? await conversation.sendToolResult(for: toolCall.toolCallId, result: result)
                }
            }
        }
    }
}
```

### MCP (Model Context Protocol) Tools

If your agent uses MCP, you can monitor and approve sensitive operations.

```swift
// Using Combine
conversation.$mcpToolCalls
    .receive(on: DispatchQueue.main)
    .sink { [weak conversation] mcpCalls in
        guard let conversation else { return }
        for call in mcpCalls where call.state == .awaitingApproval {
            Task {
                let approved = await showApprovalUI(for: call)
                try? await conversation.sendMCPToolApproval(
                    toolCallId: call.toolCallId,
                    isApproved: approved
                )
            }
        }
    }
    .store(in: &cancellables)

// Alternative: Using async/await pattern
Task {
    for await mcpCalls in conversation.$mcpToolCalls.values {
        for call in mcpCalls where call.state == .awaitingApproval {
            let approved = await showApprovalUI(for: call)
            try? await conversation.sendMCPToolApproval(
                toolCallId: call.toolCallId,
                isApproved: approved
            )
        }
    }
}
```

---

## Event Callbacks

For non-reactive integrations, use fine-grained callbacks in `ConversationConfig`.

```swift
let config = ConversationConfig(
    onAgentResponse: { text, eventId in 
        print("Agent finalized response: \(text)")
    },
    onUserTranscript: { text, eventId in
        print("User said: \(text)")
    },
    onInterruption: { eventId in
        print("User interrupted the agent!")
    },
    onAudioAlignment: { alignment in
        // Real-time word highlighting timing.
    },
    onCanSendFeedbackChange: { canSend in
        // Enable/disable your 'Thumbs Up/Down' buttons in the UI
        self.showFeedbackUI = canSend
    },
    onError: { error in
        print("A non-fatal or startup error occurred: \(error)")
    }
)
```

---

## Audio Pipeline

The `AudioPipelineConfiguration` allows you to fine-tune the hardware audio behavior.

```swift
let audioConfig = AudioPipelineConfiguration(
    // .inputMixer (default) - uses standard system mixing
    // .voiceProcessing - optimized for speech (AEC/NS)
    microphoneMuteMode: .inputMixer,
    
    // Set to true to minimize latency of the first word
    recordingAlwaysPrepared: true,
    
    // Bypass system Echo Cancellation / Noise Suppression (Advanced)
    voiceProcessingBypassed: false
)

let config = ConversationConfig(audioConfiguration: audioConfig)
```

---

## Startup Performance Tuning {#startup-tuning}

Control the connection handshake and retry behavior.

```swift
let startupConfig = ConversationStartupConfiguration(
    // Time to wait for agent to be 'ready' after room connection
    agentReadyTimeout: 10.0,
    
    // Backoff strategy for protocol initialization 
    initRetryDelays: [0, 1.0, 2.0, 5.0],
    
    // Whether to fail early if agent takes too long
    failIfAgentNotReady: true
)

let config = ConversationConfig(startupConfiguration: startupConfig)
```

---

## Feedback & Context {#feedback-context}

Handle feedback (like/dislike) and contextual updates to the agent.

```swift
// 1) Setup: react to feedback availability
var canSendFeedback = false

let cfg = ConversationConfig(
    onAgentResponse: { text, eventId in
        print("Agent:", text, "(event:", eventId, ")")
    },
    onCanSendFeedbackChange: { can in
        canSendFeedback = can
        // e.g., refresh your UI
    }
)

let conversation = try await ElevenLabs.startConversation(agentId: "agent_123", config: cfg)

// 2) Sending feedback from your UI
func thumbsUp(latestEventId: Int) {
    Task { try? await conversation.sendFeedback(.like, eventId: latestEventId) }
}

func thumbsDown(latestEventId: Int) {
    Task { try? await conversation.sendFeedback(.dislike, eventId: latestEventId) }
}

// 3) Contextual updates (e.g., user preferences)
Task { try? await conversation.updateContext("user_prefers_detailed_answers=true") }
```

---

## Reconnect & Recovery {#reconnect}

A simple recovery pattern after the agent disconnects.

```swift
conversation.$state
    .receive(on: DispatchQueue.main)
    .sink { state in
        switch state {
        case .ended(let reason):
            if reason == .remoteDisconnected {
                // Show a RECONNECT button or attempt automatically
                Task {
                    do {
                        // Reconnecting to the same agent
                        try await conversation.startConversation(with: "agent_123")
                    } catch {
                        print("Reconnect failed:", error)
                    }
                }
            }
        default: break
        }
    }
    .store(in: &cancellables)
```

Apply your own strategy (exponential backoff, retry limits, user notifications).

---

## Voice Activity Detection (VAD) {#vad}

Monitor the user's voice intensity for custom animations or meters.

```swift
let config = ConversationConfig(
    onVadScore: { score in
        // score is a float from 0.0 to 1.0
        // 0.0 = Silence, 1.0 = Loud Speech
        self.updateAmplitudeView(with: score)
    }
)
```

---

## Advanced Authentication

### Custom Token Provider

For complex scenarios where you need to refresh tokens or verify user session before starting a conversation.

```swift
let conversation = try await ElevenLabs.startConversation(
    tokenProvider: {
        // Your custom logic to fetch a conversation token
        let session = try await myAuthService.getCurrentSession()
        return try await myBackend.fetchToken(for: session)
    }
)
```

---

## Diagnostics & Troubleshooting {#diagnostics}

The SDK uses `os.Logger` for high-performance logging. You can filter logs in Xcode or Console.app using these identifiers:

- **Subsystem**: `com.elevenlabs.sdk`
- **Category**: `ElevenLabs`
- **Prefix**: `[ElevenLabs]`

### Log Levels

Adjust the verbosity of the SDK:

```swift
ElevenLabs.configure(
    ElevenLabs.Configuration(logLevel: .debug) // .trace for full event logs
)
```

---

## Best Practices

### 1. Unified MainActor

Always call SDK methods from the `@MainActor` when interacting with the UI. The SDK handles offloading heavy work to background threads internally.

### 2. Manual Cleanup

Although the SDK uses ARC, we recommend calling `endConversation()` when the user leaves the chat screen to promptly release WebRTC resources.

```swift
// Call endConversation() when the conversation is active
if conversation.state.isActive {
    await conversation.endConversation()
}
```

### 3. Cancelling Startup

If you want to abort connecting (e.g., the user dismisses the screen during `startConversation(...)`), run the start in a separate `Task` and cancel it if needed:

```swift
// Start
let connectTask = Task { () -> Conversation in
    try await ElevenLabs.startConversation(agentId: "agent_123")
}

// Cancel later
connectTask.cancel()

// Optionally await the result
do {
    let conversation = try await connectTask.value
    // conversation is ready
} catch is CancellationError {
    // connection cancelled
} catch {
    // startup error
}
```

Timeout-based cancellation:

If you want to automatically cancel connecting after a timeout (e.g., 10 seconds), start the task and schedule a cancellation using `Task.sleep`:

```swift
// Start connecting
let connectTask = Task { () -> Conversation in
    try await ElevenLabs.startConversation(agentId: "agent_123")
}

// Cancel after timeout
Task {
    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
    connectTask.cancel()
}

// Await result (optional)
do {
    let conversation = try await connectTask.value
    // connected
} catch is CancellationError {
    // cancelled due to timeout
} catch {
    // startup error
}
```

### 4. Handling Connection Drops

Listen to the `$state` property. If you see `.ended(reason: .remoteDisconnected)`, consider showing a reconnect option and/or performing automatic reconnect with backoff.

### 5. Privacy

Always ensure you have requested microphone permissions **before** calling `startConversation` for a smoother user experience, although the SDK will handle basics.
