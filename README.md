![convo](https://github.com/user-attachments/assets/1793b8ac-a273-4d70-ba53-f55a78179ba6)

# Elevenlabs Conversational AI Swift SDK (experimental)

> [!WARNING]
> This SDK is currently in development. Please do not depend on it for any production use-cases.

Elevenlabs Conversational AI Swift SDK is a framework designed to integrate ElevenLabs' powerful conversational AI capabilities into your Swift applications. Leverage advanced audio processing and seamless WebSocket communication to create interactive and intelligent conversational voivce experiences.

> [!NOTE]  
> This library is launching to primarily support Conversational AI. The support for speech synthesis and other more generic use cases is planned for the future.

## Install

Add the Elevenlabs Conversational AI Swift SDK to your project using Swift Package Manager:

1. Open Your Project in Xcode
   - Navigate to your project directory and open it in Xcode.
2. Add Package Dependency
   - Go to `File` > `Add Packages...`
3. Enter Repository URL
   - Input the following URL: `https://github.com/elevenlabs/ElevenLabsSwift`
4. Select Version
5. Import the SDK
   ```swift
   import ElevenLabsSDK
   ```
6. Ensure `NSMicrophoneUsageDescription` is added to your Info.plist to explain microphone access.

## Usage

### Setting Up a Conversation Session

1. Configure the Session
   Create a `SessionConfig` with either an `agendId` or `signedUrl`.

   ```swift
   let config = ElevenLabsSDK.SessionConfig(agentId: "your-agent-id")
   ```

2. Define Callbacks
   Implement callbacks to handle various conversation events.

   ```swift
   var callbacks = ElevenLabsSDK.Callbacks()
   callbacks.onConnect = { conversationId in
       print("Connected with ID: \(conversationId)")
   }
   callbacks.onMessage = { message, role in
       print("\(role.rawValue): \(message)")
   }
   callbacks.onError = { error, info in
       print("Error: \(error), Info: \(String(describing: info))")
   }
   callbacks.onStatusChange = { status in
       print("Status changed to: \(status.rawValue)")
   }
   callbacks.onModeChange = { mode in
       print("Mode changed to: \(mode.rawValue)")
   }
   ```

3. Start the Conversation
   Initiate the conversation session asynchronously.

   ```swift
   Task {
       do {
           let conversation = try await ElevenLabsSDK.Conversation.startSession(config: config, callbacks: callbacks)
           // Use the conversation instance as needed
       } catch {
           print("Failed to start conversation: \(error)")
       }
   }
   ```

### Manage the Session

- End Session

  ```swift
  conversation.endSession()
  ```

- Control Recording

  ```swift
  conversation.startRecording()
  conversation.stopRecording()
  ```

## Example

Explore practical implementations and examples in our [ElevenLabs Examples repository](https://github.com/elevenlabs/elevenlabs-examples). (Coming soon)
