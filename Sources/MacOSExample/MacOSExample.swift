import ElevenLabsSDK
import Foundation

// We'll use concurrency, so an @main struct with an async main
@main
struct MacOSExample {
    static func main() async {
        print("=== MinimalExample on macOS ===")

        // 1) Build a basic callback struct to observe conversation events
        let callbacks = ElevenLabsSDK.Callbacks(
            onConnect: { conversationId in
                print("[onConnect] conversationId =", conversationId)
            },
            onMessage: { text, role in
                print("[onMessage] role: \(role) -> \"\(text)\"")
            },
            onError: { message, error in
                print("[onError] message:", message, "error:", String(describing: error))
            },
            onModeChange: { mode in
                print("[onModeChange] ->", mode)
            },
            onVolumeUpdate: { level in
                print("[onVolumeUpdate] volume =", level)
            }
        )

        // 2) Create a SessionConfig. Provide your real agentId or a signedUrl
        let config = ElevenLabsSDK.SessionConfig(agentId: "FEmnOqz0KYoXJXUbhLc5")
        
        do {
            // 3) Start the conversation session
            let conversation = try await ElevenLabsSDK.Conversation.startSession(
                config: config,
                callbacks: callbacks
            )
            print("Conversation started. ID = \(conversation.getId())")

            // The audio engine is now running; talk into your Mac's microphone.
            // We'll see transcripts and agent responses in the console.

            // 4) Wait for the user to press Enter to end
            print("Press ENTER to end the session.")
            _ = readLine()

            // 5) Gracefully stop the conversation
            conversation.endSession()
            print("Session ended. Exiting...")
        } catch {
            print("Failed to start session:", error)
        }
    }
}
