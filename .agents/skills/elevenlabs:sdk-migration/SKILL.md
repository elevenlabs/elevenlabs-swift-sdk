---
name: elevenlabs:sdk-migration
description: Migrate an app on any Apple platform (iOS, macOS, visionOS, tvOS) from the ElevenLabs Swift SDK (elevenlabs-swift-sdk) v3 to v4. Use when updating code that uses ElevenLabs.startConversation, ElevenLabs.configure, the Conversation object, ConversationConfig callbacks, messages, DisconnectionReason, or related APIs from this package. Also trigger when users mention upgrading the ElevenLabs Swift SDK, fixing breaking changes after bumping the package version, moving to the latest ElevenLabs SDK, or encountering compile errors referencing removed ElevenLabs symbols after a package update.
license: MIT
---

# Swift SDK Migration Guide (v3 → v4)

Migration guide for the `ElevenLabs` Swift package's breaking changes in v4.

The core change: the static `ElevenLabs.startConversation(...)` functions that returned one-shot `Conversation` objects are gone. v4's entry point is **`ConversationClient`** — a `@MainActor ObservableObject` the app creates once, holds (e.g. as a `@StateObject`), and reuses for many conversations. Its `@Published` properties stay stable across conversations, so UI binds once instead of re-wiring per call. The `Conversation` type is no longer public.

## Migration order

Follow these steps in sequence — each builds on the previous one.

1. **Update the package version.**
2. **Replace entry points** — swap `ElevenLabs.startConversation(...)` for a held `ConversationClient` and its start methods.
3. **Move callbacks** — from `ConversationConfig` / start-call parameters to `ConversationCallbacks` passed at client creation.
4. **Update state observation** — `messages` → `chatHistory`, `.active` → `.connected`, mute and tool-result API changes.
5. **Build and fix residual errors** — use the [error mapping table](#compile-error-mapping) below.
6. **Simplify v3 workarounds** *(optional)* — remove re-binding, reconnect, and guard code the reusable client makes unnecessary.
7. **Offer the drop-in widget** *(optional)* — if the app hand-rolls chat UI, `ChatWidget` may replace it.

## Installation

While v4 is in prerelease, pin the exact version — SwiftPM's `from:` ranges do not resolve prerelease tags:

```swift
dependencies: [
    .package(url: "https://github.com/elevenlabs/elevenlabs-swift-sdk.git", exact: "4.0.0-alpha.1")
]
```

Once a stable `4.0.0` tag exists, use `from: "4.0.0"` instead.

## Replace `ElevenLabs.startConversation` with `ConversationClient`

Every v3 start variant maps to one of two methods on `ConversationClient`, distinguished by credential type. Voice conversations take a `ConversationAuth.Voice`; text-only conversations take a `ConversationAuth.TextOnly`. The `textOnly` flag on `ConversationOverrides` no longer exists.

| v3 call | v4 replacement |
| --- | --- |
| `ElevenLabs.startConversation(agentId:)` | `client.startVoiceConversation(.publicAgent(id:))` |
| `ElevenLabs.startConversation(conversationToken:)` | `client.startVoiceConversation(.conversationToken(token))` |
| `ElevenLabs.startConversation(tokenProvider: { ... })` | `client.startVoiceConversation(.conversationToken { ... })` |
| `ElevenLabs.startConversation(agentId:config:)` with `textOnly: true` | `client.startTextOnlyConversation(.publicAgent(id:))` |
| `ElevenLabs.startConversation(signedWebSocketURL:)` | `client.startTextOnlyConversation(.signedWebSocketURL(url))` |
| `ElevenLabs.startConversation(auth: ElevenLabsConfiguration..., config:)` | the matching `ConversationAuth` case on the appropriate start method |

**Before:**

```swift
@Published var conversation: Conversation?

func startChat() async {
    conversation = try? await ElevenLabs.startConversation(agentId: "your-agent-id")
}
```

**After:**

```swift
let client = ConversationClient()

func startChat() async {
    _ = try? await client.startVoiceConversation(.publicAgent(id: "your-agent-id"))
}
```

When migrating:

- Replace optional `Conversation?` storage with a non-optional `ConversationClient` created up front. Calls like `sendMessage` throw `ConversationError.notConnected` instead of needing nil-checks.
- The start methods return a `ConversationStartResult` (call info + startup timing metrics). Discard it with `_ =` unless the app used v3's `startupMetrics`.
- Startup failures throw `ConversationStartupError`, which carries the failed `stage`, partial `metrics`, and underlying `ConversationError`.
- Starting while a previous conversation is live ends it first — the latest start wins. Remove any manual "end before restart" logic.
- Credentials stay backend-minted: conversation tokens (voice) and signed WebSocket URLs (text-only) must come from the user's backend. Never embed an ElevenLabs API key in the app.
- v3's `ConversationConfig` still exists in v4 for overrides (agent/TTS/dynamic variables/timeouts) and is passed to the start call: `startVoiceConversation(auth, config: config)`.

If the codebase creates **multiple `Conversation` objects** (e.g. different screens each start their own), ask the user whether they want:

1. **One shared `ConversationClient`** injected into the screens that need it (one live conversation at a time; state visible everywhere), or
2. **One client per screen** (independent state per screen, matching the v3 structure most closely).

This affects state sharing and object lifetimes — do not assume, ask before proceeding.

## Move callbacks to `ConversationCallbacks`

v3 accepted callbacks on `ConversationConfig` and as `startConversation` parameters. In v4 all event callbacks live in a `ConversationCallbacks` struct passed once at client creation; they apply to every conversation the client starts.

**Before:**

```swift
let config = ConversationConfig(
    onAgentResponse: { text, _ in print("Agent: \(text)") },
    onUserTranscript: { text, _ in print("User: \(text)") }
)
let conversation = try await ElevenLabs.startConversation(
    agentId: "your-agent-id",
    config: config,
    onDisconnect: { reason in print("Ended: \(reason)") }
)
```

**After:**

```swift
let client = ConversationClient(callbacks: ConversationCallbacks(
    onDisconnect: { reason in print("Ended: \(reason)") },
    onAgentResponse: { text, _ in print("Agent: \(text)") },
    onUserTranscript: { text, _ in print("User: \(text)") }
))
```

When migrating:

- `onDisconnect` now receives an `EndReason` (`.userEnded`, `.agentEnded`, `.remoteDisconnected`) instead of `DisconnectionReason`. The agent invoking its `end_call` tool reports as `.agentEnded`.
- `onStartupStateChange` is gone — startup stages arrive through `state == .connecting(stage)`.
- Callback closures are typed `@Sendable` and are not actor-isolated. The SDK delivers them on the main thread, but under Swift 6 strict concurrency the compiler still requires a hop (`Task { @MainActor in ... }` or `MainActor.assumeIsolated`) before touching main-actor state inside them. In Swift 5 mode, existing v3 callback bodies work unchanged.
- Argument order in the `ConversationCallbacks` initializer follows its declaration order (`onAgentReady`, `onDisconnect`, `onError`, `onSpeechDetectedWhileMuted`, `onAgentResponse`, ..., `onUserTranscript`, ...); reorder call sites accordingly.

## Update state and transcript observation

`messages: [Message]` is replaced by `chatHistory: [any ChatHistoryItem]`, which interleaves messages and tool calls. Streamed agent replies update in place (keyed by server response ID) and carry an `isFinal` flag.

**Before:**

```swift
ForEach(conversation.messages) { message in
    Text(message.content)
}
```

**After:**

```swift
ForEach(client.chatHistory.compactMap(\.message)) { message in
    Text(message.content)
}
```

`ConversationState.active` is renamed `.connected`, and `.connecting` carries the startup stage:

**Before:**

```swift
case .active(let info): Text("Connected to \(info.agentId)")
case .connecting: Text("Connecting…")
```

**After:**

```swift
case .connected(let info): Text("Connected to \(info.agentId)")
case .connecting(let stage): Text("Connecting… (\(stage))")
```

`case .connecting:` without the binding also compiles — only bind the stage if the UI shows it. If the v3 app showed a generic spinner while connecting, suggest an upgrade: the stage enables real progress UI (token fetch → room connect → waiting for agent), and `ConversationStartResult.metrics` gives per-phase timings for startup telemetry.

When migrating:

- Remove observation of `startupState` and `startupMetrics` — the former is inside `.connecting`, the latter is returned by the start call.
- `pendingToolCalls`, `conversationMetadata`, `mcpToolCalls`, and `mcpConnectionStatus` are unchanged, just on the client.
- After a conversation ends, the client keeps the last state for display; `client.reset()` clears it back to idle defaults (useful when dismissing a screen).

## Update microphone and tool-result APIs

Mic mute is consolidated, and there is a new mute for the agent's voice. Both persist across conversations on the same client.

**Before:**

```swift
conversation.isMuted            // started as true before connect
try await conversation.toggleMute()
try await conversation.setMuted(true)
```

**After:**

```swift
client.isMicMuted               // starts false
try await client.setMicMuted(true)
try await client.setMicMuted(!client.isMicMuted)  // toggle

client.setAgentMuted(true)      // new: silence the agent without ending the call
```

> **Behavioral note:** v3's `isMuted` reported `true` until connected; v4's `isMicMuted` starts `false`. UI that showed a "muted" indicator based on the initial value will render differently — verify the intended default with the user if it matters.

For hosts that manage their own `AVAudioSession`, `AudioPipelineConfiguration.recordingAlwaysPrepared` defaults to `true` while a voice conversation is active and is disabled when the conversation ends. Set it to `false` if the host does not want the SDK to keep the recording engine warm during the conversation:

```swift
config.audioConfiguration = AudioPipelineConfiguration(recordingAlwaysPrepared: false)
```

`sendToolResult` takes a `ClientToolResultEvent` instead of loose parameters:

**Before:**

```swift
try await conversation.sendToolResult(for: call.toolCallId, result: result)
try await conversation.sendToolResult(for: call.toolCallId, result: ["error": msg], isError: true)
```

**After:**

```swift
let event = ClientToolResultEvent(toolCallId: call.toolCallId, result: result)
try await client.complete(call, with: event)

let failure = ClientToolResultEvent(
    toolCallId: call.toolCallId,
    result: "Something went wrong",
    isError: true
)
try await client.complete(call, with: failure)
```

`complete(_:with:)` ignores results from an earlier conversation, sends the result when `call.expectsResponse` is `true`, and otherwise removes the call locally with `markToolCallCompleted`. Hosts using the lower-level APIs must make the same distinction:

```swift
if call.expectsResponse {
    try await client.sendToolResult(event)
} else {
    client.markToolCallCompleted(call.toolCallId)
}
```

`result` accepts a `String` directly or any `Encodable` (JSON-encoded, throwing initializer). Where the app distinguishes kinds of tool failure, suggest the new `errorType:` parameter (`.userRejected`, `.clientTimeout`, `.externalServer`, ...) so the agent orchestrator can react to the category, not just a generic error. `sendMessage`, `interruptAgent`, `updateContext`, `sendFeedback`, and `sendMCPToolApproval` are unchanged apart from living on the client.

## Replace LiveKit track access with audio observers

v3 exposed LiveKit audio tracks (`inputTrack`, `agentAudioTrack`) and re-exported LiveKit types (`ElevenLabs.LocalAudioTrack`, `.RemoteAudioTrack`, `.AudioTrack`, `.IceServer`, etc.). None of these are public in v4. Code that consumed raw audio migrates to `ConversationAudioObserver`:

```swift
final class Visualizer: ConversationAudioObserver, @unchecked Sendable {
    func didReceive(_ buffer: AVAudioPCMBuffer) {
        // Audio-thread callback: copy what you need, then hop off.
    }
}

client.addAgentAudioObserver(visualizer)  // agent's voice
client.addMicAudioObserver(visualizer)    // local microphone
```

Observers are durable — they re-attach to every conversation the client starts. Code that muted or attenuated the agent's `RemoteAudioTrack` volume maps to `client.setAgentMuted(_:)`. Code that used LiveKit types for network configuration maps to `WebRTCConfiguration` (`.automatic` / `.relayOnly`) on `ConversationConfig`.

## Replace global configuration

`ElevenLabs.configure(...)` and the `ElevenLabs` namespace are removed:

```swift
// Before
ElevenLabs.configure(ElevenLabs.Configuration(logLevel: .info))

// After — logging per client, endpoints per session
let client = ConversationClient(logLevel: .info)
let config = ConversationConfig(
    endpoints: Endpoints(apiBase: URL(string: "https://your-proxy.example.com")!)
)
```

## Removed with no direct replacement

| v3 API | Guidance |
| --- | --- |
| `audioDevices`, `selectedAudioDeviceID` | Removed. Enumerate and route devices with `AVAudioSession` directly. |
| `latestAudioEvent`, `latestAudioAlignment` | Use the `onAudioAlignment` callback, or an audio observer for raw audio. |
| Feedback-availability callback | Call `sendFeedback` with a message's `eventId` when the app wants to send feedback. |
| `ConversationOptions` | Fold anything the app set there into `ConversationConfig`. |

## Compile-error mapping

After the mechanical changes, build and resolve leftovers with this table:

| Compile error | Fix |
| --- | --- |
| `module 'ElevenLabs' has no member named 'startConversation'` | Replace the static call with a `ConversationClient` start method. |
| `module 'ElevenLabs' has no member named 'configure'` | Use `ConversationClient(logLevel:)` and per-session `ConversationConfig`. |
| `cannot find type 'Conversation' in scope` | The type is internal now — hold/pass `ConversationClient` instead. |
| `cannot find type 'ElevenLabsConfiguration' in scope` | Map to the matching `ConversationAuth.Voice` / `ConversationAuth.TextOnly` case. |
| `has no member 'messages'` | Use `chatHistory.compactMap(\.message)`. |
| `type '...' has no member 'active'` | Rename the pattern to `.connected`. |
| `has no member 'toggleMute' / 'setMuted' / 'setMicrophoneMuted' / 'isMuted'` | Use `setMicMuted(_:)` / `isMicMuted`. |
| `incorrect argument label in call (have 'for:result:'...)` on `sendToolResult` | Wrap in `ClientToolResultEvent(toolCallId:result:)`. |
| `cannot find type 'DisconnectionReason' in scope` | Use `EndReason`. |
| `cannot find type 'LocalAudioTrack' / 'RemoteAudioTrack' in scope` | Migrate to `ConversationAudioObserver`. |
| `extra argument 'textOnly' in call` / `has no member 'textOnly'` | Use `startTextOnlyConversation(...)` instead of the flag. |
| `result of call ... is unused` warning on a start method | Assign to `_` or use the returned `ConversationStartResult`. |

## Simplify v3 workarounds (optional)

Because every v3 conversation was a fresh object, apps accumulated plumbing that the reusable client makes unnecessary. After the migration compiles, scan for these patterns and **propose** removing them — list what you found and ask the user which to apply, since each deletes working code:

- **Per-start re-binding.** v3 code re-creates Combine subscriptions, `onReceive` chains, or delegate wiring inside every start call because each `Conversation` was new. With one client, bind once — in `init`, `viewDidLoad`, or the SwiftUI body — and delete the re-wiring. Same for audio observers: they re-attach to every session automatically.

  ```swift
  // v3 pattern — delete the re-subscription
  func startChat() async {
      conversation = try? await ElevenLabs.startConversation(agentId: "your-agent-id")
      conversation?.$messages.sink { ... }.store(in: &cancellables)  // re-wired every call
  }

  // v4 — subscribe once at setup; every conversation flows through it
  init() {
      client.$chatHistory.sink { ... }.store(in: &cancellables)
  }
  ```

- **`if let conversation` UI branches.** The client always exists, so optionality branches collapse into a `switch client.state` — `.idle` covers what `nil` used to mean.
- **Reconnect scaffolding.** Reconnecting is calling start again on the same client; view models or factories that rebuild the conversation object and re-attach observers after a drop can go.
- **Double-start guards.** v3 threw `alreadyStarted` on reuse, so apps guard against it or end manually before restarting. In v4 the latest start wins and ends the previous session itself.
- **Mute restoration.** Code that re-applies a saved mute state after each start is redundant — `isMicMuted` and `isAgentMuted` carry across conversations on the same client.
- **Leave-during-connect workarounds.** v4 tears startup down cleanly at any stage: cancel the `Task` running the start, or call `endConversation()` while connecting. A start checks cancellation before binding its session, so an already-cancelled task cannot displace a live conversation. Delete flags or deferred-teardown code that waited for the connection to finish before ending it.
- **Custom transcript reconciliation.** If the app merges, dedupes, or filters streaming agent messages before display, delete that — `chatHistory` updates messages in place (keyed by response ID) and marks completion with `isFinal`.

## Adopt the drop-in widget (optional)

v4 adds an `ElevenLabsWidget` library (iOS 16+) with `ChatWidget`: a floating launcher opening a chat drawer with voice calls, a text composer, a live transcript, and an audio-reactive orb — plus `ChatWidgetController` for host-side control.

If the app hand-rolls conversation UI (transcript list, mic button, connection indicator), tell the user `ChatWidget` could replace that code and ask whether they want to adopt it — do not replace working custom UI unprompted:

```swift
import ElevenLabsWidget

ZStack {
    YourAppContent()
    ChatWidget(mode: .voiceAndText(.publicAgent(id: "your-agent-id")))
}
```

Modes: `.voiceAndText`, `.voiceOnly`, `.textOnly`, `.voiceOrTextOnly(voice:textOnly:)` — each carrying the matching `ConversationAuth` credentials.

## Verification

1. Build the app (`xcodebuild` or `swift build` for packages) and work through the error-mapping table until clean.
2. If tests exist, run them.
3. Remind the user to smoke-test one voice conversation end-to-end: start, speak, observe the transcript, mute/unmute, end — and one text-only conversation if the app uses that mode.
