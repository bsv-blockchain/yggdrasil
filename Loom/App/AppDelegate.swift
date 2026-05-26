import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Built lazily on first launch; nil before applicationDidFinishLaunching fires
    /// or when running under XCTest.
    private(set) var services: AppServices?

    func applicationDidFinishLaunching(_: Notification) {
        LoomLog.ui
            .info("Loom did finish launching (pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

        // Skip building the real service graph under tests — the test bundle has its own
        // mock wiring and we don't want the production DB / Keychain reached during
        // `xcodebuild test`.
        guard !Self.isRunningTests else {
            LoomLog.ui.info("Detected XCTest host; skipping production service wiring")
            return
        }

        do {
            let services = try AppServices()
            self.services = services
            Task {
                await services.scheduler.start()
            }
        } catch {
            LoomLog.ui.error("Failed to build AppServices: \(String(describing: error), privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_: Notification) {
        LoomLog.ui.info("Loom will terminate")
        if let scheduler = services?.scheduler {
            Task { await scheduler.stop() }
        }
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTest") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
