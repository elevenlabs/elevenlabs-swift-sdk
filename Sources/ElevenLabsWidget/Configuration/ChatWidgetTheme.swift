#if canImport(UIKit)
import Foundation
import SwiftUI

/// Visual styling for `ChatWidget`.
///
/// Pass a customized theme via `ChatWidgetConfig.theme`. The defaults match the
/// widget's stock look — neutral chrome with a blue→cyan orb gradient and a red
/// destructive accent, mirroring the ElevenLabs web widget.
///
/// Designed to grow incrementally. Add fields as new tokens are needed; old
/// fields keep their semantic. Avoid renaming — call sites depend on it.
public struct ChatWidgetTheme: Equatable {
    /// Hairline borders around buttons, input fields, and attachment pills.
    public var border: Color

    /// Saturated red used for end-call / stop glyphs.
    public var destructive: Color

    /// Soft fill behind end-conversation / destructive buttons.
    public var destructiveTint: Color

    /// Primary (darker) color in the orb gradient.
    public var orbPrimary: Color

    /// Secondary (lighter) color in the orb gradient.
    public var orbSecondary: Color

    public init(
        border: Color,
        destructive: Color,
        destructiveTint: Color,
        orbPrimary: Color,
        orbSecondary: Color
    ) {
        self.border = border
        self.destructive = destructive
        self.destructiveTint = destructiveTint
        self.orbPrimary = orbPrimary
        self.orbSecondary = orbSecondary
    }

    /// Stock theme. Values mirror the ElevenLabs web widget defaults
    /// (`border_color` `#e1e1e1`, avatar `#2792dc`→`#9ce6e6`).
    public static let `default` = ChatWidgetTheme(
        border: Color(hex: 0xE1E1E1),
        destructive: Color(hex: 0xFF1900),
        destructiveTint: Color(hex: 0xFDE4E3),
        orbPrimary: Color(hex: 0x2792DC),
        orbSecondary: Color(hex: 0x9CE6E6)
    )
}

extension Color {
    /// Build a `Color` from a 24-bit `0xRRGGBB` value, matching the hex strings
    /// used by the web widget config (e.g. `#2792dc` → `0x2792DC`).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Hand-tuned colors used across the widget chrome that aren't part of the
/// public `ChatWidgetTheme` yet.
enum WidgetColor {
    /// Outline for unselected feedback stars / comment field.
    static let starOutline = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)
}
#endif
