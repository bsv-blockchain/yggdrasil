import AppKit
import Combine
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Built lazily on first launch; nil before applicationDidFinishLaunching fires
    /// or when running under XCTest. Published so SwiftUI's RootView re-renders
    /// once the service graph is wired (the build is async w.r.t. SwiftUI's
    /// first body evaluation, so a non-observed property left the window on the
    /// placeholder branch indefinitely).
    @Published private(set) var services: AppServices?

    func applicationDidFinishLaunching(_: Notification) {
        YggdrasilLog.ui
            .info("Yggdrasil did finish launching (pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

        // SwiftUI's WindowGroup restores window frames from UserDefaults. Frames saved
        // from previous sessions may reference monitors that no longer exist, leaving
        // the window off-screen. Watch for windows becoming visible and recenter any
        // whose frame doesn't intersect any currently-attached screen.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in Self.recenterOffscreenWindows() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Self.recenterOffscreenWindows() }

        // Skip building the real service graph under tests — the test bundle has its own
        // mock wiring and we don't want the production DB / Keychain reached during
        // `xcodebuild test`.
        guard !Self.isRunningTests else {
            YggdrasilLog.ui.info("Detected XCTest host; skipping production service wiring")
            return
        }

        do {
            let services = try AppServices()
            self.services = services
            Diagnostics.ensureCrashFolder()
            AppearancePrefsPane.applyPersisted(services: services)
            Task {
                await services.scheduler.start()
                await services.statusPoller.start()
            }
        } catch {
            YggdrasilLog.ui.error("Failed to build AppServices: \(String(describing: error), privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_: Notification) {
        YggdrasilLog.ui.info("Yggdrasil will terminate")
        if let scheduler = services?.scheduler {
            Task { await scheduler.stop() }
        }
        if let poller = services?.statusPoller {
            Task { await poller.stop() }
        }
        // SIGTERM every live agent PTY. SwiftUI's own dismantleNSView paths
        // catch most cases, but the model is the authoritative registry.
        if let pids = services?.sessions.snapshotLivePIDs() {
            for pid in pids {
                YggdrasilLog.pty.info("Sending SIGTERM to agent pid=\(pid, privacy: .public) on app quit")
                kill(pid, SIGTERM)
            }
        }
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTest") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Recenters visible windows onto the screen with the menu bar (the
    /// "primary" screen — `NSScreen.screens.first`). SwiftUI restores frames
    /// from UserDefaults and `NSScreen.main` follows the focused window, so a
    /// window restored to an off-side display reports that display *as* main
    /// and a naive "on main screen" check is a no-op. Use the array order
    /// instead, which is stable across launches and matches the menu-bar
    /// screen.
    private static func recenterOffscreenWindows() {
        let allScreens = NSScreen.screens
        YggdrasilLog.ui.info(
            "Display layout: \(allScreens.count, privacy: .public) screens; main=\(String(describing: NSScreen.main?.frame), privacy: .public)"
        )
        guard let primary = allScreens.first else { return }
        let primaryFrame = primary.visibleFrame
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            if !primaryFrame.contains(center) {
                let newOrigin = NSPoint(
                    x: primaryFrame.midX - window.frame.width / 2,
                    y: primaryFrame.midY - window.frame.height / 2
                )
                window.setFrameOrigin(newOrigin)
                YggdrasilLog.ui.info(
                    "Recentered window '\(window.title, privacy: .public)' to primary screen origin=\(String(describing: newOrigin), privacy: .public)"
                )
            }
        }
    }
}
