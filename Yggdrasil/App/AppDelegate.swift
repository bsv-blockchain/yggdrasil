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

        // One-shot rescue for windows whose restored frame lands on a screen that
        // is no longer connected at all. Multi-monitor users move windows around;
        // we must not second-guess that. Only act if the frame intersects *no*
        // currently-attached screen — i.e. the window is genuinely invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.rescueOrphanedWindows() }

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

    /// One-shot rescue for windows that SwiftUI restored onto a screen the OS
    /// no longer reports — e.g. a monitor that was attached on the previous
    /// launch but is gone now. Runs once, shortly after launch, and only
    /// touches windows whose frame intersects *zero* currently-attached
    /// screens. A window the user dragged to any connected screen (including
    /// an out-of-the-way one) is left exactly where it is.
    private static func rescueOrphanedWindows() {
        let screens = NSScreen.screens
        guard !screens.isEmpty, let primary = screens.first else { return }
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            let onSomeScreen = screens.contains { $0.frame.intersects(window.frame) }
            if !onSomeScreen {
                let primaryFrame = primary.visibleFrame
                window.setFrameOrigin(NSPoint(
                    x: primaryFrame.midX - window.frame.width / 2,
                    y: primaryFrame.midY - window.frame.height / 2
                ))
                YggdrasilLog.ui.info(
                    "Rescued orphaned window '\(window.title, privacy: .public)' to primary screen"
                )
            }
        }
    }
}
