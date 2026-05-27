import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

/// Diff segment of the main pane. Loads the bundled diff2html shell from
/// `Resources/diff2html/index.html`, then asks `DiffEngine` for the unified
/// diff between the tab's worktree HEAD and a base ref, and pushes the result
/// into the page via `window.yggdrasil.render(diffText)`.
///
/// Base ref resolution: prefer `origin/<repo.default_branch>` when known; fall
/// back to bare `<default_branch>`; finally `origin/main`.
struct DiffSubPane: NSViewRepresentable {
    let services: AppServices
    let tab: YggdrasilTab

    func makeCoordinator() -> Coordinator {
        Coordinator(services: services, tab: tab)
    }

    func makeNSView(context: Context) -> NSView {
        let host = WebViewHost()
        let config = WKWebViewConfiguration()
        // Local file loads — we serve from the app bundle's Resources/diff2html/.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        host.attach(webView: webView)

        let folderRef = Bundle.main.url(forResource: "diff2html", withExtension: nil)
        let url = folderRef?.appendingPathComponent("index.html")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
        if let url, FileManager.default.fileExists(atPath: url.path) {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            YggdrasilLog.ui.error("Bundled diff2html/index.html not found in Yggdrasil.app/Resources")
        }
        return host
    }

    func updateNSView(_: NSView, context _: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let services: AppServices
        let tab: YggdrasilTab

        init(services: AppServices, tab: YggdrasilTab) {
            self.services = services
            self.tab = tab
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation) {
            Task { await self.computeAndPush(webView: webView) }
        }

        @MainActor
        private func computeAndPush(webView: WKWebView) async {
            do {
                let baseRef = resolveBaseRef()
                let diff = try await services.diffEngine.unifiedDiff(
                    worktreePath: tab.worktreePath, baseRef: baseRef
                )
                let payload = diff.isTruncated ? truncatedPlaceholder(diff: diff) : diff.text
                let escaped = payload.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "$", with: "\\$")
                let script = "window.yggdrasil && window.yggdrasil.render(`\(escaped)`);"
                _ = try? await webView.evaluateJavaScript(script)
            } catch {
                YggdrasilLog.ui.warning(
                    "Diff compute failed for tab \(self.tab.id ?? 0, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                let escapedErr = String(describing: error)
                    .replacingOccurrences(of: "`", with: "'")
                let script = "window.yggdrasil && window.yggdrasil.render(`# Diff failed\\n\\n\(escapedErr)`);"
                _ = try? await webView.evaluateJavaScript(script)
            }
        }

        private func resolveBaseRef() -> String {
            // Prefer the linked Repo's default_branch when we have it; otherwise
            // fall back to "origin/main" then "main".
            if let id = tab.id, let task = services.tabs.tasksByTabID[id] {
                if let repo = try? services.database.queue.read(
                    { db in try Repo.fetchOne(db, key: task.repoID) }
                ) {
                    return "origin/\(repo.defaultBranch)"
                }
            }
            return "origin/main"
        }

        private func truncatedPlaceholder(diff: UnifiedDiff) -> String {
            """
            diff --git a/YGGDRASIL-NOTICE b/YGGDRASIL-NOTICE
            new file mode 100644
            --- /dev/null
            +++ b/YGGDRASIL-NOTICE
            @@ -0,0 +1,4 @@
            +Diff too large — over 5 MB.
            +
            +\(diff.files.count) file(s) changed.
            +Use the terminal to inspect: `git diff <base>...HEAD`.
            """
        }
    }
}
