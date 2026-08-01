#if os(iOS)
import AVFoundation
import Foundation
import UIKit

/// A transient message shown across the top of the drawer.
struct ChatWidgetBanner: Equatable {
    let message: String
    /// Permission problems can't be fixed in-app, so those banners offer Settings.
    let offersSettings: Bool

    init(_ message: String, offersSettings: Bool = false) {
        self.message = message
        self.offersSettings = offersSettings
    }
}

enum MicrophonePermission {
    static var isDenied: Bool {
        if #available(iOS 17, macCatalyst 17, *) {
            return AVAudioApplication.shared.recordPermission == .denied
        }
        return AVAudioSession.sharedInstance().recordPermission == .denied
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
