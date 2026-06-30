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

The `ConversationClient` exposes reactive `@Published` properties for seamless UI integration. Hold one as a `@StateObject` and bind to it directly.

### Message Handling

Monitor real-time transcriptions for both the agent and the user. The `messages` array is automatically updated.

```swift
client.$messages
    .receive(on: DispatchQueue.main)
    .sink { messages in
        // messages are of type [Message]
        // Each message has role (.user or .agent) and content
        // `message.isPartial` is true while it's still being assembled —
        // a streaming agent response or an in-progress (tentative) user
        // transcript — and flips to false once finalized.
    }
    .store(in: &cancellables)
```

### Agent Speaking State

Track whether the agent is currently speaking to drive UI indicators (e.g. an
animated orb). The agent is always listening, so there is no separate
"listening"/"thinking" state — `isAgentSpeaking` is the single, honest signal of
agent voice activity, driven by the transport's speaking detection.

```swift
client.$isAgentSpeaking
    .sink { isSpeaking in
        if isSpeaking {
            // Agent is currently talking — show the speaking indicator
        } else {
            // Agent is not talking
        }
    }
    .store(in: &cancellables)
```

### Connection State

Handle transitions between idle, connecting, connected, ended, and startup-failed
states. The `connecting` case carries a `StartupPhase` describing how far the
connection/handshake has progressed; ignore it if you only need the coarse state.

```swift
client.$state
    .sink { state in
        switch state {
        case .idle:
            break
        case .connecting(let phase):
            print("Connecting: \(phase)")
        case .connected:
            print("Connected")
        case .ended(let reason):
            print("Conversation ended: \(reason)")
        case .startupFailed(let failure):
            print("Startup failed: \(failure)")
        }
    }
    .store(in: &cancellables)
```

---

## Text-Only Conversations {#text-only}

Start a conversation without audio and use text messages only.

```swift
// 1) Start a text-only conversation (no microphone used)
let client = ConversationClient()
try await client.start(
    auth: .publicAgent(id: "agent_123"),
    config: ConversationConfig(
        textOnly: true
    )
)

// 2) Send text messages
try await client.sendMessage("Hi! Tell me about the weather.")

// 3) Receive responses (reactive)
client.$messages
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
@MainActor
class AudioControlViewModel: ObservableObject {
    @Published var isAgentReady = false
    // Microphone (input) mute only — this does not mute the agent's audio output.
    @Published var isMicMuted = true

    let client: ConversationClient
    private var cancellables = Set<AnyCancellable>()

    init() {
        client = ConversationClient(
            callbacks: .init(
                onAgentReady: { [weak self] in
                    Task { @MainActor in
                        self?.isAgentReady = true
                        // Automatically unmute the mic when the agent is ready
                        try? await self?.setMicMuted(false)
                    }
                }
            )
        )

        // Observe mic mute state changes from the client
        client.$isMicMuted
            .receive(on: DispatchQueue.main)
            .assign(to: &$isMicMuted)
    }

    func startConversation(agentId: String) async throws {
        try await client.start(auth: .publicAgent(id: agentId))
    }

    func setMicMuted(_ muted: Bool) async {
        try? await client.setMicMuted(muted)
    }

    func toggleMicMute() async {
        try? await client.toggleMicMute()
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
                        await viewModel.toggleMicMute()
                    }
                }) {
                    Image(systemName: viewModel.isMicMuted ? "mic.slash" : "mic")
                        .font(.largeTitle)
                }
                .buttonStyle(.borderedProminent)
                
                Text(viewModel.isMicMuted ? "Muted" : "Unmuted")
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

### Custom Audio Renderers

For advanced audio handling — visualizers, level meters, recording, custom DSP,
or deriving your own metrics (frequency bands, a playout clock) — tap the raw
decoded PCM with a `ConversationAudioRenderer`. This works without exposing any
transport types: the only value you receive is an `AVAudioPCMBuffer`.

```swift
import AVFoundation
import ElevenLabs

final class PlayoutClock: ConversationAudioRenderer {
    private(set) var playoutMs = 0.0

    // Called on a realtime audio thread — keep it light and hop off before
    // touching UI state.
    func render(_ buffer: AVAudioPCMBuffer) {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return }
        playoutMs += Double(buffer.frameLength) / sampleRate * 1000
    }
}

let clock = PlayoutClock()
client.addAgentAudioRenderer(clock)   // agent output
// client.addInputAudioRenderer(clock) // local microphone

// later, to stop and release it:
client.removeAgentAudioRenderer(clock)
```

Renderers attach automatically once the relevant track is available and are
re-attached across reconnects, so you can register them at any time.

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
    private let client: ConversationClient
    private var toolObserverTask: Task<Void, Never>?
    
    init(client: ConversationClient) {
        self.client = client
        setupToolObserver()
    }
    
    private func setupToolObserver() {
        // Option 1: Using async/await pattern (recommended for automatic execution)
        toolObserverTask = Task {
            for await toolCalls in client.$pendingToolCalls.values {
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
        client.$pendingToolCalls
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
            
            try await client.sendToolResult(for: toolCall.toolCallId, result: result)
        } catch {
            print("Tool execution failed: \(error)")
            try? await client.sendToolResult(
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
    
    init(client: ConversationClient) {
        _viewModel = StateObject(wrappedValue: ConversationViewModel(client: client))
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
    
    private let client: ConversationClient
    private var cancellables = Set<AnyCancellable>()
    private var mcpObserverTask: Task<Void, Never>?
    
    init(client: ConversationClient) {
        self.client = client
        setupMCPObserver()
    }
    
    private func setupMCPObserver() {
        // Option 1: Automatic approval with custom logic
        mcpObserverTask = Task {
            for await mcpCalls in client.$mcpToolCalls.values {
                await withTaskGroup(of: Void.self) { group in
                    for call in mcpCalls where call.state == .awaitingApproval {
                        group.addTask {
                            // Auto-approve safe operations, ask for dangerous ones
                            let approved = await self.shouldAutoApprove(call)
                            if let approved {
                                try? await self.client.sendMCPToolApproval(
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
        client.$mcpToolCalls
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
        
        try? await client.sendMCPToolApproval(
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
    
    init(client: ConversationClient) {
        _viewModel = StateObject(wrappedValue: MCPViewModel(client: client))
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

For non-reactive integrations, pass fine-grained `ConversationCallbacks` when you create the client.

```swift
let callbacks = ConversationCallbacks(
    onError: { error in
        print("A non-fatal or startup error occurred: \(error)")
    },
    onAgentResponse: { text, eventId in 
        print("Agent finalized response: \(text)")
    },
    onAgentResponsePart: { text, type, eventId in
        // type is .start / .delta / .stop; text is empty for the boundary markers
        if type == .delta { print("Streamed agent chunk: \(text)") }
    },
    onUserTranscript: { text, eventId in
        print("User said: \(text)")
    },
    onTentativeUserTranscript: { text, eventId in
        print("User is saying (in progress): \(text)")
    },
    onInterruption: { eventId in
        print("User interrupted the agent!")
    },
    onAudioAlignment: { alignment in
        // Real-time word highlighting timing.
    },
    onMessage: { source, message in
        // Raw JSON frames for logging/telemetry. `source` is "ai" or "user".
        // Fires for every frame (incl. the ping heartbeat), so it can be noisy;
        // prefer the typed callbacks above for app logic.
    }
)

let client = ConversationClient(callbacks: callbacks)
```

---

## Audio Pipeline

The `AudioPipelineConfiguration` allows you to fine-tune the hardware audio behavior.

```swift
let audioConfig = AudioPipelineConfiguration(
    // How to mute the local mic. Pick one strategy:
    //   .inputMixer (default)  - instant, silent; no speaking-while-muted detection
    //   .voiceProcessing       - supports detection, but iOS plays a sound effect
    //   .restart               - fully releases the mic (privacy dot off), slower
    //   .software(speechThreshold: -35) - silent + detection, mutes in software
    microphoneMuteMode: .inputMixer,

    // Bypass system Echo Cancellation / Noise Suppression (Advanced)
    voiceProcessingBypassed: false
)

let config = ConversationConfig(audioConfiguration: audioConfig)
```

---

## Startup Performance Tuning {#startup-tuning}

Bound how long startup waits before failing with `.agentTimeout`. These are two
independent budgets: `agentJoinTimeout` (voice only) covers waiting for the agent
to join the room, and `conversationInitTimeout` (voice and text) covers waiting
for the `conversation_initiation_metadata` acknowledgement that completes the
handshake.

```swift
// Each defaults to 3 seconds.
let config = ConversationConfig(
    agentJoinTimeout: 10.0,
    conversationInitTimeout: 10.0
)
```

---

## Feedback & Context {#feedback-context}

Handle feedback (like/dislike) and contextual updates to the agent.

Feedback is correlated to a specific agent message via its `eventId`, which every
agent `Message` in `client.messages` carries. There is intentionally **no**
`canSendFeedback` flag: the backend accepts feedback for any past agent event
while the conversation is connected, and is last-write-wins (re-rating overwrites;
an unknown `eventId` is a no-op). So the only requirements are a valid agent
`eventId` and an active connection — `sendFeedback` throws `notConnected`
otherwise. "Once per response" or "disable after rating" is UI state your app
owns (e.g. by remembering which `eventId`s you've already rated).

```swift
let client = ConversationClient()
try await client.start(auth: .publicAgent(id: "agent_123"))

// Per-message thumbs: rate any agent message by its eventId.
func thumbsUp(for message: Message) {
    guard let eventId = message.eventId else { return } // locally-appended messages have none
    Task { try? await client.sendFeedback(.like, eventId: eventId) }
}

func thumbsDown(for message: Message) {
    guard let eventId = message.eventId else { return }
    Task { try? await client.sendFeedback(.dislike, eventId: eventId) }
}

// Contextual updates (e.g., user preferences)
Task { try? await client.updateContext("user_prefers_detailed_answers=true") }
```

---

## Reconnect & Recovery {#reconnect}

A simple recovery pattern after the agent disconnects.

```swift
class ReconnectionManager: ObservableObject {
    @Published var showReconnectButton = false
    @Published var isReconnecting = false
    @Published var reconnectAttempts = 0
    
    private let client: ConversationClient
    private let agentId: String
    private let maxRetries = 3
    private var cancellables = Set<AnyCancellable>()
    
    init(client: ConversationClient, agentId: String) {
        self.client = client
        self.agentId = agentId
        
        client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                
                switch state {
                case .ended(let reason):
                    if reason == .remoteDisconnected {
                        self.showReconnectButton = true
                        self.reconnectAttempts = 0
                    }
                case .connected:
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
                // The client is reusable — starting again runs a fresh session.
                try await client.start(auth: .publicAgent(id: agentId))
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
let callbacks = ConversationCallbacks(
    onVadScore: { score in
        // score is a float from 0.0 to 1.0
        // 0.0 = Silence, 1.0 = Loud Speech
        self.updateAmplitudeView(with: score)
    }
)

let client = ConversationClient(callbacks: callbacks)
```

---

## Advanced Authentication

### Custom Token Provider

For complex scenarios where you need to refresh tokens or verify the user session before starting a conversation, fetch a fresh conversation token right before you connect. `auth` is consumed at `start(auth:)`-time, so the token stays fresh.

```swift
// Your custom logic to fetch a conversation token
let session = try await myAuthService.getCurrentSession()
let token = try await myBackend.fetchToken(for: session)

let client = ConversationClient()
try await client.start(auth: .conversationToken(token))
```

### Custom Endpoints {#custom-endpoints}

The SDK talks to four endpoints: the conversation-token host, the LiveKit voice
host, the text-WebSocket host, and the REST host (file upload/delete, feedback).
By default these point at production (`ElevenLabsEndpoints.production`). Set a
custom `ElevenLabsEndpoints` on `ConversationConfig.endpoints` to front them
through a proxy/gateway, use a regional/data-residency host, or target a staging
deployment.

Three of the four endpoints share an API host, so the common case is one base URL:

```swift
// Derives conversationToken / textWebSocket / apiBase from one host;
// LiveKit stays on the production host unless you override it.
let endpoints = ElevenLabsEndpoints.apiBase(URL(string: "https://my-proxy.example.com")!)

let client = ConversationClient()
try await client.start(
    auth: .publicAgent(id: "your-agent-id"),
    config: .init(endpoints: endpoints)
)
```

For full control (e.g. a custom LiveKit host), use the memberwise initializer —
any endpoint you omit falls back to its production value:

```swift
let endpoints = ElevenLabsEndpoints(
    voiceWebSocket: URL(string: "wss://livekit.my-region.example.com")!
)
```

The same `endpoints:` parameter is available on `ChatWidget.init` for the widget.

---

## Diagnostics & Troubleshooting {#diagnostics}

The SDK uses `os.Logger` for high-performance logging. You can filter logs in Xcode or Console.app using these identifiers:

- **Subsystem**: `com.elevenlabs.sdk`
- **Category**: `ElevenLabs`
- **Prefix**: `[ElevenLabs]`

### Log Levels

Set the verbosity of the SDK per conversation via `ConversationConfig` (fixed for
the lifetime of the conversation; defaults to `.warning`):

```swift
let config = ConversationConfig(logLevel: .debug) // .trace for full event logs
let client = ConversationClient()
try await client.start(auth: .publicAgent(id: "your-agent-id"), config: config)
```

---

## Best Practices

### 1. Unified MainActor

Always call SDK methods from the `@MainActor` when interacting with the UI. The SDK handles offloading heavy work to background threads internally.

### 2. Manual Cleanup

Although the SDK uses ARC, we recommend calling `endConversation()` when the user leaves the chat screen to promptly release WebRTC resources.

```swift
// Call endConversation() when the conversation is connected
if client.state == .connected {
    await client.endConversation()
}
```

### 3. Cancelling Startup

If you want to abort connecting (e.g., the user dismisses the screen during `start(auth:)`), run the start in a separate `Task` and cancel it if needed:

```swift
let client = ConversationClient()

// Start
let connectTask = Task {
    try await client.start(auth: .publicAgent(id: "agent_123"))
}

// Cancel later
connectTask.cancel()

// Optionally await the result
do {
    try await connectTask.value
    // client is connected
} catch is CancellationError {
    // connection cancelled
} catch {
    // startup error
}
```

Timeout-based cancellation:

If you want to automatically cancel connecting after a timeout (e.g., 10 seconds), start the task and schedule a cancellation using `Task.sleep`:

```swift
let client = ConversationClient()

// Start connecting
let connectTask = Task {
    try await client.start(auth: .publicAgent(id: "agent_123"))
}

// Cancel after timeout
Task {
    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
    connectTask.cancel()
}

// Await result (optional)
do {
    try await connectTask.value
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

Always ensure you have requested microphone permissions **before** calling `start(auth:)` for a smoother user experience, although the SDK will handle basics.
