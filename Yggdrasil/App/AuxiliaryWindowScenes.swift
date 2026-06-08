import SwiftUI

// Auxiliary tool windows for the four user-triggered pickers. These used to
// be `.sheet`s, but macOS sheets are pinned to the parent window's titlebar
// — the user can't move or resize them. Real `Window` scenes give a free-
// floating, resizable, movable window, which is the behaviour the user asked
// for ("all popup windows should be resizable and be able to move around").
//
// One `Window` (singleton) per id rather than `WindowGroup` (multi-instance)
// because opening "My Issues" twice doesn't make sense — `openWindow(id:)`
// brings the existing instance to the front instead of stacking duplicates.

/// Stable window-id strings. Call sites import these to avoid a typo
/// silently routing `openWindow(id:)` to a non-existent scene.
enum AuxiliaryWindowID {
    static let newTab = "yggdrasil.window.newTab"
    static let assignedPicker = "yggdrasil.window.assignedPicker"
    static let reviewPicker = "yggdrasil.window.reviewPicker"
    static let issueDetails = "yggdrasil.window.issueDetails"
}

/// + New Session window.
struct NewTabWindowScene: Scene {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Scene {
        Window("New Session", id: AuxiliaryWindowID.newTab) {
            AuxiliaryWindowHost(appDelegate: appDelegate) { services in
                NewTabSheet(services: services)
            }
        }
        // `.contentMinSize` keeps the inner `.frame(minWidth: ...)` as the
        // floor but lets the user grow the window past idealWidth/Height
        // freely. `.contentSize` (the other choice) would lock the window
        // to the content's frame, which is what we just escaped from.
        .windowResizability(.contentMinSize)
    }
}

/// Open Assigned task picker.
struct AssignedTaskWindowScene: Scene {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Scene {
        Window("Assigned Tasks", id: AuxiliaryWindowID.assignedPicker) {
            AuxiliaryWindowHost(appDelegate: appDelegate) { services in
                AssignedTaskPicker(services: services)
            }
        }
        .windowResizability(.contentMinSize)
    }
}

/// Review-requested picker (same view as assigned, different mode).
struct ReviewPickerWindowScene: Scene {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Scene {
        Window("Review Requests", id: AuxiliaryWindowID.reviewPicker) {
            AuxiliaryWindowHost(appDelegate: appDelegate) { services in
                AssignedTaskPicker(services: services, mode: .review)
            }
        }
        .windowResizability(.contentMinSize)
    }
}

/// My Issues table picker.
struct IssueDetailsWindowScene: Scene {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Scene {
        Window("My Issues", id: AuxiliaryWindowID.issueDetails) {
            AuxiliaryWindowHost(appDelegate: appDelegate) { services in
                IssueDetailsPicker(services: services)
            }
        }
        .windowResizability(.contentMinSize)
    }
}

/// Bridges the `Window` scene to AppDelegate.services. Services is built
/// asynchronously in `applicationDidFinishLaunching`, so on a cold launch the
/// scene's body runs before services exists — show a placeholder until it's
/// wired (mirrors the main `RootView` pattern).
private struct AuxiliaryWindowHost<Content: View>: View {
    @ObservedObject var appDelegate: AppDelegate
    @ViewBuilder let content: (AppServices) -> Content

    var body: some View {
        if let services = appDelegate.services {
            content(services)
        } else {
            Text("Loading…")
                .foregroundStyle(.secondary)
                .frame(minWidth: 320, minHeight: 200)
        }
    }
}
