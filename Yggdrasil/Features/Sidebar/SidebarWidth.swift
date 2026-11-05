import Foundation

/// The sidebar's width, which the user sets by dragging its edge. Kept
/// across launches, like the panes' divider.
enum SidebarWidth {
    static let defaultsKey = "yggdrasil.sidebarWidth"
    static let standard: Double = 320
    static let minimum: Double = 260
    static let maximum: Double = 720
    /// What the main pane keeps, however wide the sidebar is dragged.
    static let mainPaneMinimum: Double = 480
    /// The hairline between the sidebar and the main pane.
    static let dividerWidth: Double = 1

    static func clamped(_ width: Double, windowWidth: Double) -> Double {
        let roomLeft = windowWidth - mainPaneMinimum - dividerWidth
        return max(minimum, min(width, maximum, roomLeft))
    }
}
