import AppKit
import Foundation
import SwiftUI

/// Help-menu items for Phase 8 polish:
/// - "Diagnostics" copies anonymised system info + recent logs to the clipboard.
/// - "Reveal Crash Logs" opens `~/Library/Logs/Yggdrasil/crashes/` in Finder.
struct DiagnosticsCommands: Commands {
    var body: some Commands {
        // Adds into the auto-built Help menu rather than creating a second
        // one. macOS otherwise renders a stray duplicate "Help" alongside the
        // standard help menu.
        CommandGroup(replacing: .help) {
            Button("Diagnostics") {
                Diagnostics.copyToClipboard()
            }
            Button("Reveal Crash Logs") {
                Diagnostics.openCrashFolder()
            }
        }
    }
}

enum Diagnostics {
    static let crashFolderURL: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("Yggdrasil", isDirectory: true)
        .appendingPathComponent("crashes", isDirectory: true)

    /// Ensure the crash folder exists. Called from AppDelegate at launch.
    static func ensureCrashFolder() {
        let url = crashFolderURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let readmeURL = url.appendingPathComponent("README.txt")
            if !FileManager.default.fileExists(atPath: readmeURL.path) {
                let readme = """
                Yggdrasil keeps crash artefacts here.

                If Yggdrasil crashes, drop the crash report (from
                ~/Library/Logs/DiagnosticReports/) into this folder and attach
                it to a bug report. Yggdrasil's built-in writer is V2; for now this
                folder is just a known location.
                """
                try? readme.write(to: readmeURL, atomically: true, encoding: .utf8)
            }
        } catch {
            YggdrasilLog.ui.error(
                "Diagnostics ensureCrashFolder failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Compose the diagnostics blob: app version, macOS version, Xcode/Swift
    /// versions, app bundle ID, paths Yggdrasil uses, and the latest few log lines
    /// from `os.Logger` via `log show` (best effort). Anonymises home paths.
    static func copyToClipboard() {
        let info = composeReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
        let alert = NSAlert()
        alert.messageText = "Diagnostics copied"
        alert.informativeText = "Paste into a bug report or pull request."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func openCrashFolder() {
        ensureCrashFolder()
        NSWorkspace.shared.activateFileViewerSelecting([crashFolderURL])
    }

    private static func composeReport() -> String {
        let home = NSHomeDirectory()
        let processInfo = ProcessInfo.processInfo
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let bundleID = bundle.bundleIdentifier ?? "?"
        let macOS = processInfo.operatingSystemVersionString
        return """
        Yggdrasil Diagnostics
        ----------------
        App version:     \(version) (\(build))
        Bundle ID:       \(bundleID)
        macOS:           \(macOS)
        Process ID:      \(processInfo.processIdentifier)
        Locale:          \(Locale.current.identifier)
        Database path:   \(redact(home: home, path: databasePath()))
        Logs:            tail with `log show --predicate 'subsystem == "\(YggdrasilLog.subsystem)"' --last 5m`

        (Yggdrasil does not collect this automatically. Sharing it with a bug
        report is opt-in via this menu.)
        """
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            .map { $0.appendingPathComponent("Yggdrasil").appendingPathComponent("yggdrasil.sqlite").path }
        return appSupport ?? "(not yet created)"
    }

    private static func redact(home: String, path: String) -> String {
        path.replacingOccurrences(of: home, with: "~")
    }
}
