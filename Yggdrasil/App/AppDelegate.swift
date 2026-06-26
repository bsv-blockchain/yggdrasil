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

        // Hard-fail on missing dependencies. v0.1.0 shipped with a broken
        // libgit2 bundle and crashed every user at dyld time. The fail-hard
        // alert ensures any future regression — bundled dylib missing or
        // gh not installed — surfaces a precise error instead of a silent
        // crash or degraded mode the user can't diagnose.
        let validator = StartupValidator.production()
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
            // One-shot cleanup: tear down any leftover yggdrasil-* tmux
            // sessions from previous versions of the app (we used to back
            // every tab with a tmux session). Runs best-effort in the
            // background; harmless if tmux isn't installed.
            Task.detached(priority: .background) {
                Self.cleanupLegacyTmuxSessions()
            }
            Task {
                await services.startSchedulers()
            }
        } catch {
            YggdrasilLog.ui.error("Failed to build AppServices: \(String(describing: error), privacy: .public)")
        }

        // Rewrites Shift+Enter to ESC+CR so Claude Code and similar agents
        // see "insert newline" instead of "submit". This is the only PTY-
        // input interceptor we keep — scroll-wheel + selection now work
        // natively via SwiftTerm since we dropped tmux mouse-mode.
        TerminalKeyInterceptor.install()
        // Bridges the mouse to full-screen / mouse-reading agents (e.g. Claude
        // Code's fullscreen renderer): forwards the wheel (which SwiftTerm never
        // sends to the app) and keeps mouse reporting in sync with the agent's
        // live mouse mode so clicks/selection work without breaking native
        // selection when the agent isn't reading the mouse.
        TerminalMouseInterceptor.install()

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
        // Agents now run as direct children of the app's PTY view — no
        // background daemon to keep alive — so closing the last window
        // exits the app immediately.
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
        // Agents are direct children of our PTY masters; closing the
        // masters as the process exits propagates SIGHUP to them. No
        // further teardown needed.
    }

    /// Best-effort tear-down of any leftover `yggdrasil-*` tmux sessions
    /// from when this app shipped with tmux-backed agent survival. We
    /// query the legacy `yggdrasil` socket; if the socket isn't there
    /// (fresh user, tmux uninstalled) every call exits 1 and we move on.
    /// Runs once at launch and never again — orphans only existed in
    /// versions ≤ 0.1.1.
    private static func cleanupLegacyTmuxSessions() {
        let tmux = "/opt/homebrew/bin/tmux"
        guard FileManager.default.fileExists(atPath: tmux) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-L", "yggdrasil", "kill-server"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Silently ignore — best-effort cleanup, not a hard dependency.
        }
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

    static var isRunningTests: Bool {
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
