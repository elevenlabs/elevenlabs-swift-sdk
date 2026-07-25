#if canImport(UIKit)
import SwiftUI

/// The audio-reactive orb, driven by the sampled mic and agent levels.
@available(iOS 16, macCatalyst 16, *)
struct ChatOrbView: View {
    /// Observed here so level changes redraw only the orb, not the whole widget.
    @ObservedObject var levels: OrbAudioLevels
    let state: ChatOrbState
    let size: CGFloat
    var theme: ChatWidgetTheme = .default

    var body: some View {
        Orb(
            color1: theme.orbPrimary,
            color2: theme.orbSecondary,
            inputVolume: levels.input,
            outputVolume: levels.output,
            agentState: state.visualizerState
        )
        .frame(width: size, height: size)
    }
}

enum ChatOrbState {
    case connecting
    case listening
    case thinking
    case speaking
    case disconnected

    var visualizerState: VisualizerAgentState {
        switch self {
        case .connecting: .connecting
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .disconnected: .disconnected
        }
    }
}
#endif
