import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Built lazily on first launch; nil before applicationDidFinishLaunching fires
    /// or when running under XCTest.
    private(set) var services: AppServices?

    func applicationDidFinishLaunching(_: Notification) {
        YggdrasilLog.ui
            .info("Yggdrasil did finish launching (pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

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
}
