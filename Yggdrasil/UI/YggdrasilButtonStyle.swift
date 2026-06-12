import SwiftUI

/// Drop-in replacement for `.buttonStyle(.plain)` on Yggdrasil's icon, pill,
/// and segment buttons.
///
/// `.plain` only hit-tests the rendered glyph, so a 24×22 icon button is
/// really only tappable on the ~11pt symbol — users had to aim at the
/// top-left corner to land a click. `.contentShape(Rectangle())` makes the
/// button's whole laid-out frame (icon + padding + background) tappable.
///
/// `.plain` also gives no press feedback. The opacity + slight scale dip on
/// `isPressed` makes a click feel registered. Neither affects layout, so this
/// is a safe swap anywhere `.plain` is used on a framed label.
struct YggdrasilButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.4 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == YggdrasilButtonStyle {
    /// `.buttonStyle(.yggdrasilIcon)` — full-frame hit target + press feedback.
    static var yggdrasilIcon: YggdrasilButtonStyle {
        YggdrasilButtonStyle()
    }
}
