#if canImport(UIKit)
import ElevenLabs
import SwiftUI

enum ChatOrbState {
    case connecting
    case listening
    case speaking
    case disconnected
    case unknown
    
    var visualizerState: VisualizerAgentState {
        switch self {
        case .connecting:
            return .connecting
        case .listening:
            return .listening
        case .speaking:
            return .speaking
        case .disconnected:
            return .disconnected
        case .unknown:
            return .unknown
        }
    }
}

struct ChatOrbView: View {
    let state: ChatOrbState
    /// Agent (output) levels — the orb's primary driver. The orb's Metal render
    /// loop *pulls* these (see `audio:` below), so audio-rate updates drive the
    /// orb at 60fps without ever re-rendering SwiftUI. Plain refs on purpose:
    /// observing them here would defeat that and churn the view at audio rate.
    let agentLevels: AudioLevelMonitor
    /// User mic (input) levels — secondary, a subtle swirl while the user speaks.
    let userLevels: AudioLevelMonitor
    var size: CGFloat
    var theme: ChatWidgetTheme = .default

    var body: some View {
        // Both speakers drive the petals from their own frequency bands (see
        // OrbShader.metal): each petal follows the louder of its agent and mic
        // band. The agent's scalar level also drives the ring pulse and the
        // user's scalar level the flow swirl, so you can still tell who's
        // talking. The render loop *pulls* this each frame, so audio-rate
        // updates never re-render SwiftUI.
        Orb(
            color1: theme.orbPrimary,
            color2: theme.orbSecondary,
            agentState: state.visualizerState,
            audio: {
                OrbAudioSample(
                    agentLevel: agentLevels.current.average,
                    userLevel: userLevels.current.average,
                    agentBands: agentLevels.current.bands,
                    userBands: userLevels.current.bands
                )
            }
        )
        .frame(width: size, height: size)
    }
}


#endif
