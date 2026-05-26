import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        LoomLog.ui
            .info("Loom did finish launching (pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public))")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_: Notification) {
        LoomLog.ui.info("Loom will terminate")
    }
}
