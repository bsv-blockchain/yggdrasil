import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

/// SwiftUI wrapper around a pooled `WKWebView` for the GitHub sub-pane.
///
/// The actual `WKWebView` lifecycle is owned by `services.webViewPool`; this
/// representable just hands the pool the tab id and URL and hosts whatever
/// view the pool returns. Spec §Phase 5:
/// - Persistent `WKWebsiteDataStore(forIdentifier:)` — login survives restarts.
/// - Max 8 live web views, LRU eviction with `interactionState` save/restore.
/// - Reload via the MainPaneView reload Notification.
/// - Offline fallback when the load fails.
struct GitHubWebView: NSViewRepresentable {
    let services: AppServices
    let tab: YggdrasilTab
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(pool: services.webViewPool, tabID: tab.id ?? 0)
    }

    func makeNSView(context: Context) -> NSView {
        let host = WebViewHost()
        let webView = services.webViewPool.acquireWebView(forTabID: tab.id ?? 0)
        webView.navigationDelegate = context.coordinator
        host.attach(webView: webView)

        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.observeReloadNotifications(for: webView)
        return host
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let host = nsView as? WebViewHost else { return }
        let webView = services.webViewPool.acquireWebView(forTabID: tab.id ?? 0)
        if host.attached !== webView {
            host.attach(webView: webView)
            if webView.url == nil {
                webView.load(URLRequest(url: url))
            }
        }
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.removeReloadObserver()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let pool: WebViewPool
        let tabID: Int64
        private var reloadObserver: NSObjectProtocol?
        weak var lastWebView: WKWebView?

        init(pool: WebViewPool, tabID: Int64) {
            self.pool = pool
            self.tabID = tabID
            super.init()
        }

        func observeReloadNotifications(for webView: WKWebView) {
            lastWebView = webView
            reloadObserver = NotificationCenter.default.addObserver(
                forName: MainPaneView.reloadGitHubNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let id = note.object as? Int64,
                      id == self.tabID,
                      let view = self.lastWebView else { return }
                view.reload()
            }
        }

        func removeReloadObserver() {
            if let observer = reloadObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation,
            withError error: Error
        ) {
            YggdrasilLog.ui.warning(
                "GitHub WebView load failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}

/// Thin NSView wrapper that hosts one WKWebView via Auto Layout. Lets us swap
/// the inner WebView (when the pool evicts and recreates) without re-creating
/// the SwiftUI representable.
final class WebViewHost: NSView {
    private(set) weak var attached: WKWebView?

    func attach(webView: WKWebView) {
        subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        attached = webView
    }
}

// MARK: - Find

/// Drives Cmd-F for both the GitHub and Diff panes (both host their WKWebView
/// in a `WebViewHost`). Uses WebKit's native incremental find, which
/// highlights and scrolls to matches.
extension WebViewHost: PaneFinder {
    func paneFind(_ query: String, forward: Bool) {
        guard let webView = attached, !query.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true
        webView.find(query, configuration: config) { _ in }
    }

    func paneClearFind() {
        attached?.evaluateJavaScript(
            "window.getSelection && window.getSelection().removeAllRanges()",
            completionHandler: nil
        )
    }
}
