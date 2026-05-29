import Foundation
@preconcurrency import WebKit

/// Per-app pool of `WKWebView` instances keyed by tab id. Originally enforced
/// "max 8 live; LRU eviction"; the cap is gone now per the instant-switching
/// requirement — every tab keeps its WebView alive forever so navigation
/// state, scroll position, and page contents are zero-latency on selection.
/// `release(tabID:)` is still honoured for actually-closed tabs.
///
/// All access is `@MainActor` because WKWebView itself is main-thread only.
@MainActor
final class WebViewPool {
    /// Stable identifier for the persistent data store so login survives launches.
    /// Persisted into the `setting` table on first use.
    static let dataStoreSettingKey = "github_webview_uuid"

    private let dataStoreUUID: UUID
    private let dataStore: WKWebsiteDataStore
    private var live: [Int64: WKWebView] = [:]

    init(settingsStore: SettingsStore?) {
        let resolved = WebViewPool.resolveDataStoreUUID(settingsStore: settingsStore)
        self.dataStoreUUID = resolved
        // macOS 14+ persistent data store keyed by UUID — survives across launches
        // because the bytes-on-disk live under
        // ~/Library/WebKit/<bundle id>/WebsiteData/<uuid>/.
        self.dataStore = WKWebsiteDataStore(forIdentifier: resolved)
    }

    /// Acquire (or create) the WKWebView for `tabID`. Once created the view
    /// is retained for the app's lifetime; only `release(tabID:)` removes it.
    func acquireWebView(forTabID tabID: Int64) -> WKWebView {
        if let existing = live[tabID] {
            return existing
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        // Leave the user agent at WebKit's default (Safari-family). A custom UA
        // makes github.com's WebAuthn capability detection serve the degraded
        // "partial passkey support" path; the stock UA is what unlocks full
        // passkey login in-panel once the web-browser entitlement is signed in.
        live[tabID] = webView
        return webView
    }

    /// Drop the WebView for `tabID` (e.g. tab actually removed by the user).
    func release(tabID: Int64) {
        if let view = live.removeValue(forKey: tabID) {
            view.stopLoading()
        }
    }

    /// Read or mint the stable UUID for the persistent WKWebsiteDataStore.
    /// First call writes the UUID into the `setting` table; later calls read
    /// it back. Returns a transient UUID if the settings store is unavailable
    /// (under XCTest) — login won't persist in that case, which is fine.
    private static func resolveDataStoreUUID(settingsStore: SettingsStore?) -> UUID {
        if let settingsStore,
           let existing = try? settingsStore.get(forKey: dataStoreSettingKey),
           let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let fresh = UUID()
        if let settingsStore {
            try? settingsStore.set(fresh.uuidString, forKey: dataStoreSettingKey)
        }
        return fresh
    }
}
