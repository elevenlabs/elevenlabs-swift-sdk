#if canImport(UIKit)
import SwiftUI

/// Default launcher: a mini orb in the corner of the host UI.
@available(iOS 16, macCatalyst 16, *)
struct FloatingChatButton: View {
    @ObservedObject var vm: ChatWidgetViewModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ChatOrbView(
                levels: vm.audioLevels,
                state: vm.orbState,
                size: 58,
                theme: vm.widgetConfig.theme
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vm.widgetConfig.strings.openChatLabel)
    }
}
#endif
