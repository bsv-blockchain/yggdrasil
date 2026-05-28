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

    /// Owns the AppKit "Coding" main-menu items. Built in AppKit (not SwiftUI
    /// `CommandMenu`) because SwiftUI's command routing stops firing menu
    /// actions once `MenuBarExtra` is in the Scene graph.
    private var codingMenu: CodingMenuController?

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

        // Probe tmux now (we'll reuse the result for both AppServices wiring
        // and the startup validator below).
        let tmuxManager = TmuxManager.detect()

        // Hard-fail on missing dependencies. v0.1.0 shipped with a broken
        // libgit2 bundle and crashed every user at dyld time. The fail-hard
        // alert ensures any future regression — bundled dylib missing, gh
        // not installed, tmux gone — surfaces a precise error instead of a
        // silent crash or degraded mode the user can't diagnose.
        let validator = StartupValidator.production(tmuxAvailable: tmuxManager.isAvailable)
        let failures = validator.validate()
        if !failures.isEmpty {
            Self.presentStartupFailureAlertAndExit(failures: failures)
            return
        }

        do {
            let services = try AppServices()
            self.services = services
            Diagnostics.ensureCrashFolder()
            AppearancePrefsPane.applyPersisted(services: services)
            Task {
                await services.startSchedulers()
            }
        } catch {
            YggdrasilLog.ui.error("Failed to build AppServices: \(String(describing: error), privacy: .public)")
        }

        // Forwards scroll-wheel events to the PTY when the embedded program
        // (tmux, mostly) is asking for mouse events. Stays installed for
        // the app's lifetime; a single-monitor cost is negligible.
        TerminalScrollInterceptor.install()

        // Install the AppKit "Coding" menu after the main menu bar is built.
        // SwiftUI sets up the bar during its own scene init; defer one tick
        // so NSApp.mainMenu's View item exists by the time we insert after it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let controller = CodingMenuController(appDelegate: self)
            controller.install()
            self.codingMenu = controller
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // Stay alive (menu bar item still visible) as long as there are
        // background tmux sessions hosting running agents — the user
        // explicitly chose the "agents survive app close" model so the menu
        // bar item is the only handle on those sessions until they're done.
        // When no tmux sessions remain, fall through to the normal
        // last-window-closed → quit behaviour.
        let running = services?.tmux.listSessions() ?? []
        if running.isEmpty {
            return true
        }
        YggdrasilLog.ui.info(
            "Last window closed but \(running.count, privacy: .public) tmux sessions still alive; keeping app + menu bar alive"
        )
        return false
    }

    func applicationWillTerminate(_: Notification) {
        YggdrasilLog.ui.info("Yggdrasil will terminate")
        if let scheduler = services?.scheduler {
            Task { await scheduler.stop() }
        }
        if let poller = services?.statusPoller {
            Task { await poller.stop() }
        }
        // Agents are owned by tmux daemons (see TmuxManager); we deliberately
        // do NOT SIGTERM them here. When this process exits, our PTY masters
        // close and the tmux *clients* detach, but the tmux server keeps the
        // session and its agent process alive. The menu bar's
        // "Close and kill all" button is the explicit teardown path.
    }

    /// Show a blocking NSAlert listing every failed startup check and exit
    /// the process. The alert is the only thing the user sees — main window
    /// never appears, no MenuBarExtra is installed. Exit code 1 so anything
    /// supervising the process (e.g. a launchd job, an installer test) can
    /// distinguish startup-validation failure from a graceful quit.
    private static func presentStartupFailureAlertAndExit(failures: [StartupCheckFailure]) {
        // Surface to Console.app for users who file bug reports without
        // copying the alert text.
        for failure in failures {
            YggdrasilLog.ui.error(
                "Startup check failed (\(failure.tool, privacy: .public)): \(failure.message, privacy: .public)"
            )
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Yggdrasil can't start"
        alert.informativeText = failures
            .map { "• \($0.tool): \($0.message)" }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
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
