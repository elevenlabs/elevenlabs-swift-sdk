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

`ConversationClient` exposes reactive `@Published` properties for seamless UI integration. The client is reusable: its state stays observable across conversations, so bindings survive from one call to the next. After a conversation ends, the last state (history, metadata) is kept for display until you start a new conversation or call `reset()`.

### Chat History

Observe messages and tool calls in one reconciled history.

```swift
client.$chatHistory
    .receive(on: DispatchQueue.main)
    .sink { history in
        let messages = history.compactMap(\.message)
        let toolCalls = history.compactMap(\.toolCall)
    }
    .store(in: &cancellables)
```

### Agent State Monitoring

Directly track what the agent is currently doing to show appropriate UI indicators.

```swift
client.$agentState
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

Handle transitions between idle, connecting, connected, ended, and error states.
Startup stages are nested under `.connecting`.

```swift
client.$state
    .sink { state in
        switch state {
        case .idle:
            break
        case .connecting(let stage):
            print("Connecting: \(stage)")
        case .connected(let callInfo):
            print("Connected to agent: \(callInfo.agentId)")
            print("Conversation ID: \(callInfo.conversationId)")
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
let client = ConversationClient()
_ = try await client.startTextOnlyConversation(.publicAgent(id: "agent_123"))

// 2) Send text messages
try await client.sendMessage("Hi! Tell me about the weather.")

// 3) Receive responses (reactive)
client.$chatHistory
    .receive(on: DispatchQueue.main)
    .compactMap { $0.compactMap(\.message).last }
    .sink { last in
        guard last.role == .agent else { return }
        print("Agent:", last.content)
    }
    .store(in: &cancellables)
```

For private agents, authenticate with a signed WebSocket URL minted by your backend — see [Advanced Authentication](#advanced-authentication).

---

## Advanced Audio Controls

### Microphone Management

Control the user's microphone state directly without needing to manage `AVAudioSession` yourself. Mute state set while disconnected is remembered and applied to the next conversation the client starts.

```swift
@MainActor
final class AudioControlViewModel: ObservableObject {
    @Published var isAgentReady = false
    @Published var isMicMuted = false

    private(set) var client: ConversationClient!

    init() {
        client = ConversationClient(callbacks: ConversationCallbacks(
            onAgentReady: { [weak self] in
                Task { @MainActor in
                    self?.isAgentReady = true
                }
            }
        ))

        // Mirror the client's mute state for the UI
        client.$isMicMuted.assign(to: &$isMicMuted)
    }

    func startConversation(agentId: String) async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: agentId))
    }

    func toggleMicMute() async {
        try? await client.setMicMuted(!client.isMicMuted)
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

### Agent Mute

Silence the agent's voice independently of the microphone and of any other audio your app is
playing. Useful while the user reads or types and does not want to be spoken to. The agent keeps
talking — it just is not heard.

```swift
client.setAgentMuted(true)

// Mirrored for UI binding, mirroring `isMicMuted`.
Toggle("Mute agent", isOn: Binding(
    get: { client.isAgentMuted },
    set: { client.setAgentMuted($0) }
))
```

The setting is scoped to this client's conversations, so it needs no restoring on teardown, and
it carries across sessions — an agent muted in one conversation stays muted in the next.
`reset()` unmutes.

Voice conversations only; text-only conversations have no agent audio, so the value is simply
remembered until a voice conversation starts.

### Raw Audio Observers

Observe decoded PCM from the agent output or local microphone without taking a LiveKit dependency in app code. Prefer this over reaching for transport tracks.

```swift
final class SpectrumObserver: ConversationAudioObserver, @unchecked Sendable {
    func didReceive(_ buffer: AVAudioPCMBuffer) {
        // Time-critical path: copy what you need, then hop off this callback.
        let copy = buffer.copy()
        Task { @MainActor in
            updateVisualizer(copy)
        }
    }
}

let client = ConversationClient()
let observer = SpectrumObserver()
client.addAgentAudioObserver(observer)
client.addMicAudioObserver(observer)
```

`didReceive(_:)` runs on the audio callback path (not the main actor). The buffer is borrowed and read-only. Observers are durable — they re-attach to every conversation the client starts.

---

## Tool Calls

### Client Tools

Client tools allow your agent to execute logic within your app. You must register the tools in the ElevenLabs Dashboard first.

```swift
// Complete example with lifecycle management
@MainActor
final class ConversationViewModel: ObservableObject {
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
        isProcessingTool = true
        defer { isProcessingTool = false }

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

            try await client.complete(
                toolCall,
                with: .init(toolCallId: toolCall.toolCallId, result: result)
            )
        } catch {
            print("Tool execution failed: \(error)")
            try? await client.complete(
                toolCall,
                with: .init(
                    toolCallId: toolCall.toolCallId,
                    result: "Error: \(error.localizedDescription)",
                    isError: true
                )
            )
        }
    }

    func stopObserving() {
        toolObserverTask?.cancel()
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
        .onDisappear {
            viewModel.stopObserving()
        }
    }
}
```

### MCP (Model Context Protocol) Tools

If your agent uses MCP, you can monitor and approve sensitive operations.

```swift
@MainActor
final class MCPViewModel: ObservableObject {
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

    func stopObserving() {
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

For non-reactive integrations, use fine-grained callbacks via `ConversationCallbacks`. Pass them when creating the client — they apply to every conversation it starts.

```swift
let callbacks = ConversationCallbacks(
    onError: { error in
        print("A non-fatal or startup error occurred: \(error)")
    },
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
    }
)

let client = ConversationClient(callbacks: callbacks)
```

---

## Audio Pipeline

The `AudioPipelineConfiguration` allows you to fine-tune the hardware audio behavior.

```swift
let audioConfig = AudioPipelineConfiguration(
    // .inputMixer (default) - uses standard system mixing
    // .voiceProcessing - optimized for speech (AEC/NS)
    // .software(speechThreshold:notificationThrottle:) - silent mute with callbacks
    microphoneMuteMode: .inputMixer,

    // Set to true to minimize latency of the first word
    recordingAlwaysPrepared: true,

    // Bypass system Echo Cancellation / Noise Suppression (Advanced)
    voiceProcessingBypassed: false
)

let config = ConversationConfig(audioConfiguration: audioConfig)
```

---

## Startup Timeouts {#startup-tuning}

Control how long startup waits for the agent and conversation metadata.

```swift
let startupConfig = ConversationStartupConfiguration(
    // Time to wait for the agent after the room connects
    agentReadyTimeout: 10.0,

    // Time to wait for the server to initialize the conversation
    initiationMetadataTimeout: 5.0
)

let config = ConversationConfig(startupConfiguration: startupConfig)
```

---

## Feedback & Context {#feedback-context}

Feedback can be sent whenever the conversation is connected.

```swift
let callbacks = ConversationCallbacks(
    onAgentResponse: { text, eventId in
        print("Agent:", text, "(event:", eventId, ")")
    }
)

let client = ConversationClient(callbacks: callbacks)
_ = try await client.startVoiceConversation(.publicAgent(id: "agent_123"))

func thumbsUp(eventId: Int) async throws {
    guard client.state.isConnected else { return }
    try await client.sendFeedback(.like, eventId: eventId)
}

func thumbsDown(eventId: Int) async throws {
    guard client.state.isConnected else { return }
    try await client.sendFeedback(.dislike, eventId: eventId)
}

try await client.updateContext("user_prefers_detailed_answers=true")
```

---

## Reconnect & Recovery {#reconnect}

The client is reusable, so recovering from a drop is just calling start again on the same client — your UI bindings stay in place.

```swift
@MainActor
final class ReconnectionManager: ObservableObject {
    @Published var showReconnectButton = false
    @Published var isReconnecting = false

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
                    }
                case .connected:
                    self.showReconnectButton = false
                    self.isReconnecting = false
                case .idle, .connecting, .error:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func reconnect() async {
        isReconnecting = true
        defer { isReconnecting = false }

        for attempt in 0..<maxRetries {
            do {
                _ = try await client.startVoiceConversation(.publicAgent(id: agentId))
                return
            } catch {
                // Exponential backoff: 1s, 2s, 4s
                let delay = pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        print("Max reconnection attempts reached")
    }
}

// SwiftUI usage
struct ReconnectView: View {
    @ObservedObject var reconnectionManager: ReconnectionManager

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
```

---

## Advanced Authentication

For complex scenarios where you need to refresh credentials or verify the user's session before starting a conversation, pass a closure instead of a fixed value. It is called once per start, so every conversation — including reconnects — gets a fresh credential.

```swift
let client = ConversationClient()

// Voice: mint a conversation token on your backend
_ = try await client.startVoiceConversation(
    .conversationToken {
        let session = try await myAuthService.getCurrentSession()
        return try await myBackend.fetchToken(for: session)
    }
)

// Text-only: mint a signed WebSocket URL on your backend
_ = try await client.startTextOnlyConversation(
    .signedWebSocketURL { try await myBackend.fetchSignedWebSocketURL() }
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
let client = ConversationClient(logLevel: .debug) // .trace for full event logs
```

---

## Best Practices

### 1. Unified MainActor

Always call SDK methods from the `@MainActor` when interacting with the UI. The SDK handles offloading heavy work to background threads internally.

### 2. Manual Cleanup

Although the SDK uses ARC, we recommend calling `endConversation()` when the user leaves the chat screen to promptly release WebRTC resources. It is safe to call in any state, and it also cancels a start that has not connected yet.

```swift
await client.endConversation()

// To also clear the mirrored state (history, metadata) back to idle defaults:
await client.reset()
```

### 3. Cancelling Startup

If you want to abort connecting (e.g., the user dismisses the screen during startup), run the start in a separate `Task` and cancel it if needed:

```swift
// Start
let connectTask = Task {
    try await client.startVoiceConversation(.publicAgent(id: "agent_123"))
}

// Cancel later
connectTask.cancel()

// Optionally await the result
do {
    let result = try await connectTask.value
    // connected — result.metrics carries startup timings
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
let connectTask = Task {
    try await client.startVoiceConversation(.publicAgent(id: "agent_123"))
}

// Cancel after timeout
Task {
    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
    connectTask.cancel()
}

// Await result (optional)
do {
    let result = try await connectTask.value
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

Always ensure you have requested microphone permissions **before** starting a voice conversation for a smoother user experience, although the SDK will handle basics.
