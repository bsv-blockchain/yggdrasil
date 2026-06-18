import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

/// Diff segment of the main pane. Loads the bundled diff renderer from
/// `Resources/diff2html/index.html`, then asks `DiffEngine` for the unified
/// diff between the tab's worktree HEAD and a base ref, and pushes the result
/// into the page via `window.yggdrasil.render(diffText)`.
///
/// Scope toggle: the page's toolbar shows a segmented control with
/// "Uncommitted" / "Branch". The selection round-trips to Swift via a
/// `WKScriptMessageHandler` so we can re-run `git diff` with the right
/// args and push the new payload back. The "Branch" option is hidden
/// when the worktree is checked out on the repo's default branch
/// (no merge-base to draw against).
///
/// Persistence: the chosen scope is stored per-tab in UserDefaults under
/// `yggdrasil.diffScope.<tabID>`.
struct DiffSubPane: NSViewRepresentable {
    let services: AppServices
    let tab: YggdrasilTab
    /// True when this pane belongs to the currently-selected tab. Drives
    /// the FSEventStream watcher — we only spend a kernel watcher on
    /// the pane the user is actually looking at (the parent layout
    /// mounts every tab at opacity 0 for instant switching, so without
    /// this every diff pane would maintain its own stream).
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(services: services, tab: tab)
    }

    func makeNSView(context: Context) -> NSView {
        let host = WebViewHost()
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Channel for the JS toolbar to talk back when the user picks a scope.
        config.userContentController.add(context.coordinator, name: "yggdrasil")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
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

    func updateNSView(_: NSView, context: Context) {
        // Propagate active-state into the coordinator on every layout
        // pass so the watcher starts when the user selects this tab and
        // stops when they switch away.
        context.coordinator.setActive(isActive)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let services: AppServices
        let tab: YggdrasilTab
        weak var webView: WKWebView?
        private var scope: DiffScope
        private var watcher: WorktreeWatcher?

        init(services: AppServices, tab: YggdrasilTab) {
            self.services = services
            self.tab = tab
            self.scope = Self.loadScope(for: tab)
        }

        deinit {
            watcher?.stop()
        }

        func webView(_: WKWebView, didFinish _: WKNavigation) {
            Task { await self.applyThemeAndRender() }
        }

        /// Called from `updateNSView` with the current selection state.
        /// When the user switches to this tab we register an
        /// FSEventStream on the worktree so saves / git operations
        /// re-render the diff automatically. When they switch away the
        /// stream is invalidated so the kernel isn't watching 20
        /// directories for 20 background tabs.
        @MainActor
        func setActive(_ active: Bool) {
            if active {
                if watcher == nil {
                    let w = WorktreeWatcher(path: tab.worktreePath) { [weak self] in
                        guard let self else { return }
                        Task { await self.applyThemeAndRender() }
                    }
                    w.start()
                    watcher = w
                    // Also re-render now in case files changed while we
                    // weren't watching.
                    Task { await self.applyThemeAndRender() }
                }
            } else if let w = watcher {
                w.stop()
                watcher = nil
            }
        }

        /// JS → Swift channel. JSON payload: { "type": "scope",
        /// "value": "uncommitted" | "branch" }.
        func userContentController(
            _: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "scope":
                if let raw = body["value"] as? String,
                   let newScope = Self.parseScope(raw),
                   newScope != scope {
                    scope = newScope
                    Self.persistScope(newScope, for: tab)
                    Task { await self.applyThemeAndRender() }
                }
            default:
                break
            }
        }

        @MainActor
        private func applyThemeAndRender() async {
            guard let webView else { return }
            let theme = NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua ? "dark" : "light"
            _ = try? await webView.evaluateJavaScript(
                "window.yggdrasil && window.yggdrasil.setTheme(\"\(theme)\");"
            )

            // Decide whether the "Branch" mode is meaningful for this tab.
            // If the current branch IS the default branch, the merge-base
            // collapses to HEAD and the comparison is empty/meaningless.
            let baseRef = resolveBaseRef()
            let currentBranch = await services.diffEngine.currentBranch(worktreePath: tab.worktreePath)
            let defaultBranch = resolveDefaultBranch()
            let onDefault = currentBranch != nil && currentBranch == defaultBranch
            let scopeForCompute: DiffScope = onDefault ? .uncommitted : scope
            // If we've been forced to uncommitted because we're on the
            // default branch, reflect that in the persisted state too so
            // it doesn't surprise the user when they switch branches.
            if onDefault, scope != .uncommitted {
                scope = .uncommitted
                Self.persistScope(.uncommitted, for: tab)
            }
            // Tell the JS toolbar which modes to offer + which one is on.
            await pushScopeUI(branchEnabled: !onDefault, selected: scopeForCompute, on: webView)
            // Describe what we're diffing so the empty state can name the
            // branch/base/scope instead of rendering a blank pane.
            await pushContext(
                branch: currentBranch, base: baseRef, scope: scopeForCompute, on: webView
            )

            do {
                let diff = try await services.diffEngine.unifiedDiff(
                    worktreePath: tab.worktreePath, baseRef: baseRef, scope: scopeForCompute
                )
                let payload = diff.isTruncated ? truncatedPlaceholder(diff: diff) : diff.text
                let escaped = payload.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "$", with: "\\$")
                _ = try? await webView.evaluateJavaScript(
                    "window.yggdrasil && window.yggdrasil.render(`\(escaped)`);"
                )
            } catch {
                YggdrasilLog.ui.warning(
                    "Diff compute failed for tab \(self.tab.id ?? 0, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                let escapedErr = String(describing: error)
                    .replacingOccurrences(of: "`", with: "'")
                _ = try? await webView.evaluateJavaScript(
                    "window.yggdrasil && window.yggdrasil.render(`# Diff failed\\n\\n\(escapedErr)`);"
                )
            }
        }

        private func pushScopeUI(
            branchEnabled: Bool, selected: DiffScope, on webView: WKWebView
        ) async {
            let selectedStr = Self.scopeRaw(selected)
            let script = """
            window.yggdrasil && window.yggdrasil.setScopeOptions \
            && window.yggdrasil.setScopeOptions(\
            { branchEnabled: \(branchEnabled), selected: "\(selectedStr)" }\
            );
            """
            _ = try? await webView.evaluateJavaScript(script)
        }

        private func pushContext(
            branch: String?, base: String, scope: DiffScope, on webView: WKWebView
        ) async {
            let script = """
            window.yggdrasil && window.yggdrasil.setContext \
            && window.yggdrasil.setContext(\
            { branch: "\(Self.jsEscape(branch ?? ""))", \
            base: "\(Self.jsEscape(base))", \
            scope: "\(Self.scopeRaw(scope))" }\
            );
            """
            _ = try? await webView.evaluateJavaScript(script)
        }

        /// Escape a string for embedding in a double-quoted JS literal.
        private static func jsEscape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        private func resolveBaseRef() -> String {
            if let id = tab.id, let task = services.tabs.tasksByTabID[id],
               let repo = try? services.database.queue.read(
                   { db in try Repo.fetchOne(db, key: task.repoID) }
               ) {
                return "origin/\(repo.defaultBranch)"
            }
            return "origin/main"
        }

        private func resolveDefaultBranch() -> String {
            if let id = tab.id, let task = services.tabs.tasksByTabID[id],
               let repo = try? services.database.queue.read(
                   { db in try Repo.fetchOne(db, key: task.repoID) }
               ) {
                return repo.defaultBranch
            }
            return "main"
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

        // MARK: - Scope persistence

        private static func scopeKey(_ tab: YggdrasilTab) -> String {
            "yggdrasil.diffScope.\(tab.id.map(String.init) ?? "unknown")"
        }

        static func loadScope(for tab: YggdrasilTab) -> DiffScope {
            let raw = UserDefaults.standard.string(forKey: scopeKey(tab))
            return raw.flatMap(parseScope) ?? .branchAndUncommitted
        }

        static func persistScope(_ scope: DiffScope, for tab: YggdrasilTab) {
            UserDefaults.standard.set(scopeRaw(scope), forKey: scopeKey(tab))
        }

        static func parseScope(_ raw: String) -> DiffScope? {
            switch raw {
            case "uncommitted": .uncommitted
            case "branch": .branchAndUncommitted
            default: nil
            }
        }

        static func scopeRaw(_ scope: DiffScope) -> String {
            switch scope {
            case .uncommitted: "uncommitted"
            case .branchAndUncommitted: "branch"
            }
        }
    }
}
