import AppKit
import SwiftUI

/// Two-pane horizontal splitter that exposes its divider position as a
/// `@Binding<Double>` so callers can persist it (per-tab, in our case).
///
/// SwiftUI's `HSplitView` doesn't expose its divider state — width is
/// negotiated entirely by the OS NSSplitView under the hood, and nothing
/// reaches Swift code. This view replaces it with a deterministic
/// fraction-of-width split + a drag handle on the divider.
///
/// Minimum widths: each pane is held at a floor of 200pt so the user
/// can't drag a pane closed accidentally. Clamping is also applied on
/// load so a previously-persisted out-of-range fraction lands inside
/// `[minPaneWidth/total, 1 - minPaneWidth/total]`.
struct DraggableHSplit<Primary: View, Secondary: View>: View {
    @Binding var fraction: Double
    let primary: () -> Primary
    let secondary: () -> Secondary

    /// `fraction` value at the start of the current drag. `DragGesture`
    /// reports a CUMULATIVE translation (distance from drag start, not
    /// per-event delta), so the new width has to be computed against
    /// this start value — adding translation to the live `primaryWidth`
    /// would create a feedback loop that visibly accelerates the drag.
    @State private var dragStartFraction: Double?

    private let minPaneWidth: CGFloat = 200
    private let dividerWidth: CGFloat = 1
    /// Wider invisible hit zone around the 1pt divider so the drag
    /// handle is comfortably grabbable.
    private let dividerHitZone: CGFloat = 8

    var body: some View {
        GeometryReader { geom in
            let total = geom.size.width
            let minFraction = total > 0 ? minPaneWidth / total : 0
            let maxFraction = 1 - minFraction
            let clamped = max(minFraction, min(maxFraction, fraction))
            let primaryWidth = (total - dividerWidth) * clamped
            HStack(spacing: 0) {
                primary()
                    .frame(width: primaryWidth)
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: dividerWidth)
                    .overlay(
                        Color.clear
                            .frame(width: dividerHitZone)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(coordinateSpace: .global)
                                    .onChanged { value in
                                        guard total > 0 else { return }
                                        let start = dragStartFraction ?? fraction
                                        if dragStartFraction == nil {
                                            dragStartFraction = start
                                        }
                                        let startWidth = (total - dividerWidth) * start
                                        let newWidth = startWidth + value.translation.width
                                        let newFraction = newWidth / (total - dividerWidth)
                                        fraction = max(minFraction, min(maxFraction, newFraction))
                                    }
                                    .onEnded { _ in
                                        dragStartFraction = nil
                                    }
                            )
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                secondary()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
