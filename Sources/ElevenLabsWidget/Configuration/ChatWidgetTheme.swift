#if os(iOS)
import SwiftUI

/// Visual styling for ``ChatWidget``. Defaults mirror the ElevenLabs web widget.
public struct ChatWidgetTheme: Equatable, Sendable {
    /// Hairline borders around buttons and the composer.
    public var border: Color
    /// Saturated red used for the end-call glyph.
    public var destructive: Color
    /// Soft fill behind the end-call button.
    public var destructiveTint: Color
    /// Primary (darker) color in the orb gradient.
    public var orbPrimary: Color
    /// Secondary (lighter) color in the orb gradient.
    public var orbSecondary: Color

    public init(
        border: Color = ChatWidgetTheme.default.border,
        destructive: Color = ChatWidgetTheme.default.destructive,
        destructiveTint: Color = ChatWidgetTheme.default.destructiveTint,
        orbPrimary: Color = ChatWidgetTheme.default.orbPrimary,
        orbSecondary: Color = ChatWidgetTheme.default.orbSecondary
    ) {
        self.border = border
        self.destructive = destructive
        self.destructiveTint = destructiveTint
        self.orbPrimary = orbPrimary
        self.orbSecondary = orbSecondary
    }

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
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
#endif
