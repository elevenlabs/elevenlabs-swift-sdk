import Foundation

enum AgentStateSignal: Sendable {
    case vadScore(Double)
    case agentStartedSpeaking
    case agentStoppedSpeaking
    case agentResponse
    case userTranscript
    case interruption
    case agentToolRequest
    case agentToolResponse
}

private typealias TimerTask = Task<Void, Never>

@MainActor
final class AgentStateManager {
    private(set) var currentState: ElevenLabs.AgentState = .listening
    var onStateChange: ((ElevenLabs.AgentState) -> Void)?

    private let configuration: AgentStateConfiguration

    private var isUserSpeaking = false
    private var isAgentSpeaking = false

    private var speechTimer: TimerTask?
    private var silenceTimer: TimerTask?
    private var speakingTimer: TimerTask?

    init(configuration: AgentStateConfiguration) {
        self.configuration = configuration
    }

    func processSignal(_ signal: AgentStateSignal) {
        switch signal {
        case let .vadScore(score):
            handleVadScore(score)

        case .agentStartedSpeaking:
            isAgentSpeaking = true
            cancelTimer(&speakingTimer)
            transitionTo(.speaking)

        case .agentStoppedSpeaking:
            isAgentSpeaking = false
            scheduleTimer(&speakingTimer, delay: configuration.speakingToListeningDelay) { [weak self] in
                guard let self, !self.isAgentSpeaking, currentState == .speaking else { return }
                transitionTo(.listening)
            }

        case .agentResponse:
            cancelTimer(&speakingTimer)
            transitionTo(.speaking)

        case .userTranscript:
            if currentState != .speaking { transitionTo(.thinking) }

        case .interruption:
            cancelAllTimers()
            isAgentSpeaking = false
            transitionTo(.listening)

        case .agentToolRequest:
            transitionTo(.thinking)

        case .agentToolResponse:
            transitionTo(.listening)
        }
    }

    private func handleVadScore(_ score: Double) {
        let wasSpeaking = isUserSpeaking
        let isSpeakingNow = score >= configuration.vadSpeakingThreshold
        isUserSpeaking = isSpeakingNow

        if isSpeakingNow, !wasSpeaking {
            cancelTimer(&silenceTimer)
            scheduleTimer(&speechTimer, delay: configuration.minSpeechDuration) { [weak self] in
                guard let self, isUserSpeaking else { return }
                transitionTo(.listening)
            }
        } else if !isSpeakingNow, wasSpeaking {
            cancelTimer(&speechTimer)
            scheduleTimer(&silenceTimer, delay: configuration.minSilenceDuration) { [weak self] in
                guard let self, !self.isUserSpeaking, currentState != .speaking else { return }
                transitionTo(.thinking)
            }
        } else if isSpeakingNow {
            cancelTimer(&silenceTimer)
        }
    }

    private func transitionTo(_ newState: ElevenLabs.AgentState) {
        guard newState != currentState else { return }
        currentState = newState
        onStateChange?(newState)
    }

    private func scheduleTimer(_ timer: inout TimerTask?, delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func cancelTimer(_ timer: inout TimerTask?) {
        timer?.cancel()
        timer = nil
    }

    private func cancelAllTimers() {
        cancelTimer(&speechTimer)
        cancelTimer(&silenceTimer)
        cancelTimer(&speakingTimer)
    }
}
