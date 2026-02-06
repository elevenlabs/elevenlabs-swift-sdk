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
class AudioControlViewModel: ObservableObject {
    @Published var isAgentReady = false
    @Published var isMuted = true
    
    private var conversation: Conversation?
    private var cancellables = Set<AnyCancellable>()
    
    func startConversation(agentId: String) async throws {
        conversation = try await ElevenLabs.startConversation(
            agentId: agentId,
            config: .init(
                onAgentReady: { [weak self] in
                    Task { @MainActor in
                        self?.isAgentReady = true
                        // Automatically unmute when agent is ready
                        try? await self?.setMuted(false)
                    }
                }
            )
        )
        
        // Observe mute state changes from the conversation
        conversation?.$isMuted
            .receive(on: DispatchQueue.main)
            .assign(to: &$isMuted)
    }
    
    func setMuted(_ muted: Bool) async {
        guard let conversation else { return }
        try? await conversation.setMuted(muted)
    }
    
    func toggleMute() async {
        guard let conversation else { return }
        try? await conversation.toggleMute()
    }
}

// SwiftUI usage
struct AudioControlView: View {
    @StateObject private var viewModel = AudioControlViewModel()
    
    var body: some View {
        VStack(spacing: 16) {
            if viewModel.isAgentReady {
                Button(action: {
                    Task {
                        await viewModel.toggleMute()
                    }
                }) {
                    Image(systemName: viewModel.isMuted ? "mic.slash" : "mic")
                        .font(.largeTitle)
                }
                .buttonStyle(.borderedProminent)
                
                Text(viewModel.isMuted ? "Muted" : "Unmuted")
                    .foregroundColor(.secondary)
            } else {
                ProgressView("Connecting...")
            }
        }
        .task {
            try? await viewModel.startConversation(agentId: "agent_123")
        }
    }
}
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
// Complete example with lifecycle management
class ConversationViewModel: ObservableObject {
    @Published var pendingTools: [ClientToolCallEvent] = []
    @Published var isProcessingTool = false
    
    private var cancellables = Set<AnyCancellable>()
    private let conversation: Conversation
    private var toolObserverTask: Task<Void, Never>?
    
    init(conversation: Conversation) {
        self.conversation = conversation
        setupToolObserver()
    }
    
    private func setupToolObserver() {
        // Option 1: Using async/await pattern (recommended for automatic execution)
        toolObserverTask = Task {
            for await toolCalls in conversation.$pendingToolCalls.values {
                await withTaskGroup(of: Void.self) { group in
                    for toolCall in toolCalls {
                        group.addTask {
                            await self.executeTool(toolCall)
                        }
                    }
                }
            }
        }
        
        // Option 2: Using Combine (for manual execution with UI control)
        conversation.$pendingToolCalls
            .receive(on: DispatchQueue.main)
            .sink { [weak self] toolCalls in
                self?.pendingTools = toolCalls
            }
            .store(in: &cancellables)
    }
    
    func executeTool(_ toolCall: ClientToolCallEvent) async {
        await MainActor.run { isProcessingTool = true }
        defer { Task { @MainActor in isProcessingTool = false } }
        
        do {
            let params = try toolCall.getParameters()
            
            // Execute specific tool based on name
            let result: String
            switch toolCall.toolName {
            case "get_weather":
                let location = params["location"] as? String ?? "Unknown"
                result = await getWeather(for: location)
                
            case "search_database":
                let query = params["query"] as? String ?? ""
                result = await searchDatabase(query: query)
                
            case "calculate":
                let expression = params["expression"] as? String ?? "0"
                result = calculateExpression(expression)
                
            default:
                result = "Unknown tool: \(toolCall.toolName)"
            }
            
            try await conversation.sendToolResult(for: toolCall.toolCallId, result: result)
        } catch {
            print("Tool execution failed: \(error)")
            try? await conversation.sendToolResult(
                for: toolCall.toolCallId,
                result: "Error: \(error.localizedDescription)",
                isError: true
            )
        }
    }
    
    // Example tool implementations
    private func getWeather(for location: String) async -> String {
        // Your weather API call
        return "Sunny, 22°C in \(location)"
    }
    
    private func searchDatabase(query: String) async -> String {
        // Your database search
        return "Found 3 results for '\(query)'"
    }
    
    private func calculateExpression(_ expression: String) -> String {
        // Your calculation logic
        return "Result: 42"
    }
    
    deinit {
        toolObserverTask?.cancel()
    }
}

// SwiftUI usage
struct ConversationView: View {
    @StateObject private var viewModel: ConversationViewModel
    
    init(conversation: Conversation) {
        _viewModel = StateObject(wrappedValue: ConversationViewModel(conversation: conversation))
    }
    
    var body: some View {
        VStack {
            if viewModel.isProcessingTool {
                ProgressView("Processing tool...")
            }
            
            // Optional: Show pending tools for manual approval
            ForEach(viewModel.pendingTools, id: \.toolCallId) { toolCall in
                Button("Execute \(toolCall.toolName)") {
                    Task {
                        await viewModel.executeTool(toolCall)
                    }
                }
            }
        }
    }
}
```

### MCP (Model Context Protocol) Tools

If your agent uses MCP, you can monitor and approve sensitive operations.

```swift
class MCPViewModel: ObservableObject {
    @Published var pendingApprovals: [MCPToolCallEvent] = []
    @Published var isProcessing = false
    
    private let conversation: Conversation
    private var cancellables = Set<AnyCancellable>()
    private var mcpObserverTask: Task<Void, Never>?
    
    init(conversation: Conversation) {
        self.conversation = conversation
        setupMCPObserver()
    }
    
    private func setupMCPObserver() {
        // Option 1: Automatic approval with custom logic
        mcpObserverTask = Task {
            for await mcpCalls in conversation.$mcpToolCalls.values {
                await withTaskGroup(of: Void.self) { group in
                    for call in mcpCalls where call.state == .awaitingApproval {
                        group.addTask {
                            // Auto-approve safe operations, ask for dangerous ones
                            let approved = await self.shouldAutoApprove(call)
                            if let approved {
                                try? await self.conversation.sendMCPToolApproval(
                                    toolCallId: call.toolCallId,
                                    isApproved: approved
                                )
                            }
                        }
                    }
                }
            }
        }
        
        // Option 2: Manual approval through UI
        conversation.$mcpToolCalls
            .receive(on: DispatchQueue.main)
            .sink { [weak self] calls in
                self?.pendingApprovals = calls.filter { $0.state == .awaitingApproval }
            }
            .store(in: &cancellables)
    }
    
    private func shouldAutoApprove(_ call: MCPToolCallEvent) async -> Bool? {
        // Auto-approve read-only operations
        let safeMethods = ["get", "read", "list", "search"]
        if safeMethods.contains(where: { call.toolName.lowercased().contains($0) }) {
            return true
        }
        
        // Require user approval for write operations
        return nil // nil means show UI prompt
    }
    
    func approveTool(_ toolCallId: String, approved: Bool) async {
        isProcessing = true
        defer { isProcessing = false }
        
        try? await conversation.sendMCPToolApproval(
            toolCallId: toolCallId,
            isApproved: approved
        )
    }
    
    deinit {
        mcpObserverTask?.cancel()
    }
}

// SwiftUI approval interface
struct MCPApprovalView: View {
    @StateObject private var viewModel: MCPViewModel
    @State private var showingDialog = false
    @State private var currentCall: MCPToolCallEvent?
    
    init(conversation: Conversation) {
        _viewModel = StateObject(wrappedValue: MCPViewModel(conversation: conversation))
    }
    
    var body: some View {
        VStack {
            if !viewModel.pendingApprovals.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("\(viewModel.pendingApprovals.count) operation(s) need approval")
                    Spacer()
                    Button("Review") {
                        currentCall = viewModel.pendingApprovals.first
                        showingDialog = true
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .alert("Approve Operation?", isPresented: $showingDialog, presenting: currentCall) { call in
            Button("Approve") {
                Task {
                    await viewModel.approveTool(call.toolCallId, approved: true)
                }
            }
            Button("Deny", role: .destructive) {
                Task {
                    await viewModel.approveTool(call.toolCallId, approved: false)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { call in
            VStack(alignment: .leading, spacing: 8) {
                Text("Tool: \(call.toolName)")
                    .font(.headline)
                if let params = try? call.getParameters() {
                    Text("Parameters: \(params)")
                        .font(.caption)
                }
            }
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
class ReconnectionManager: ObservableObject {
    @Published var showReconnectButton = false
    @Published var isReconnecting = false
    @Published var reconnectAttempts = 0
    
    private let conversation: Conversation
    private let agentId: String
    private let maxRetries = 3
    private var cancellables = Set<AnyCancellable>()
    
    init(conversation: Conversation, agentId: String) {
        self.conversation = conversation
        self.agentId = agentId
        
        conversation.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                
                switch state {
                case .ended(let reason):
                    if reason == .remoteDisconnected {
                        self.showReconnectButton = true
                        self.reconnectAttempts = 0
                    }
                case .active:
                    self.showReconnectButton = false
                    self.isReconnecting = false
                    self.reconnectAttempts = 0
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
    
    func reconnect() async {
        isReconnecting = true
        
        while reconnectAttempts < maxRetries {
            do {
                try await conversation.startConversation(with: agentId)
                return
            } catch {
                reconnectAttempts += 1
                
                if reconnectAttempts < maxRetries {
                    // Exponential backoff: 1s, 2s, 4s
                    let delay = pow(2.0, Double(reconnectAttempts - 1))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    print("Max reconnection attempts reached")
                }
            }
        }
        
        isReconnecting = false
    }
}

// SwiftUI usage
struct ConversationView: View {
    @StateObject private var reconnectionManager: ReconnectionManager
    
    var body: some View {
        VStack {
            if reconnectionManager.showReconnectButton {
                Button(action: {
                    Task {
                        await reconnectionManager.reconnect()
                    }
                }) {
                    if reconnectionManager.isReconnecting {
                        ProgressView()
                            .padding()
                    } else {
                        Text("Reconnect")
                    }
                }
                .disabled(reconnectionManager.isReconnecting)
            }
        }
    }
}
```

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
