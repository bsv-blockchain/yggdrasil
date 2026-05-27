import SwiftUI

/// Design tokens for Yggdrasil. Mirrors the CSS variables in the design's Yggdrasil.html
/// (`--bg`, `--text`, `--accent`, status colors, etc.).
///
/// Resolves dynamically against the SwiftUI environment's `colorScheme` so
/// dark/light/auto modes work without manual rebinding.
enum YggdrasilTheme {

    // MARK: - Brand

    /// Yggdrasil blue — accent. CSS: `--accent: #4670ff`.
    static let accent = Color(hex: 0x4670ff)
    /// CSS: `--accent-deep: #2f4ed8` — gradient endpoint for the workspace mark.
    static let accentDeep = Color(hex: 0x2f4ed8)
    static func accentSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 70/255, green: 112/255, blue: 255/255, opacity: 0.14)
            : Color(red: 70/255, green: 112/255, blue: 255/255, opacity: 0.12)
    }
    /// Ember orange — signal / unread. CSS: `--ember: #ff7a59`.
    static let ember = Color(hex: 0xff7a59)
    static func emberSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 255/255, green: 122/255, blue: 89/255, opacity: 0.16)
            : Color(red: 255/255, green: 122/255, blue: 89/255, opacity: 0.18)
    }

    // MARK: - Backgrounds

    static func bg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0d0e11) : Color(hex: 0xece8df)
    }
    static func bgWindow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x14161b) : Color(hex: 0xf5f1e8)
    }
    static func bgPane(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x181b21) : Color(hex: 0xfbf8f2)
    }
    static func bgPaneSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1d2128) : Color(hex: 0xf0ece2)
    }
    static func bgElev(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x232730) : Color(hex: 0xffffff)
    }
    static func bgHover(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.04)
            : Color.black.opacity(0.035)
    }
    static func bgActive(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.06)
    }

    // MARK: - Borders

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.07)
            : Color(red: 60/255, green: 50/255, blue: 30/255, opacity: 0.10)
    }
    static func borderStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.13)
            : Color(red: 60/255, green: 50/255, blue: 30/255, opacity: 0.18)
    }
    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.06)
            : Color(red: 60/255, green: 50/255, blue: 30/255, opacity: 0.08)
    }

    // MARK: - Text

    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xe8eaef) : Color(hex: 0x1a1814)
    }
    static func textDim(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xa4abb8) : Color(hex: 0x5a5448)
    }
    static func textMute(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x6b7384) : Color(hex: 0x8a8474)
    }
    static func textFaint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x4a5161) : Color(hex: 0xb3ad9b)
    }

    // MARK: - Chips

    static func chipBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.05)
            : Color(red: 60/255, green: 50/255, blue: 30/255, opacity: 0.05)
    }
    static func chipBd(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 60/255, green: 50/255, blue: 30/255, opacity: 0.10)
    }

    // MARK: - Status

    static func statusOK(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x4ade80) : Color(hex: 0x16a34a)
    }
    static func statusWarn(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xfbbf24) : Color(hex: 0xd97706)
    }
    static func statusErr(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xff6b6b) : Color(hex: 0xdc2626)
    }
    static let statusInfo = accent
    static func statusIdle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x6b7384) : Color(hex: 0x8a8474)
    }
}

extension Color {
    /// Hex initializer for the design's `#rrggbb` literals.
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
