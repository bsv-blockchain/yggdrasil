import Foundation
@preconcurrency import WebKit

/// Per-app pool of `WKWebView` instances keyed by tab id. Enforces the spec's
/// "max 8 live; LRU eviction" — when a 9th tab acquires, the least-recently-
/// used WebView is taken offline and its `interactionState` is captured so the
/// next acquire for that tab restores scroll position / form state.
///
/// All access is `@MainActor` because WKWebView itself is main-thread only.
@MainActor
final class WebViewPool {
    static let defaultCapacity = 8
    /// Stable identifier for the persistent data store so login survives launches.
    /// Persisted into the `setting` table on first use.
    static let dataStoreSettingKey = "github_webview_uuid"

    private let dataStoreUUID: UUID
    private let dataStore: WKWebsiteDataStore
    private var live: [Int64: WKWebView] = [:]
    private var savedInteractionStates: [Int64: Any] = [:]
    private var tracker: LRUTracker<Int64>

    init(settingsStore: SettingsStore?, capacity: Int = WebViewPool.defaultCapacity) {
        self.tracker = LRUTracker<Int64>(capacity: capacity)
        let resolved = WebViewPool.resolveDataStoreUUID(settingsStore: settingsStore)
        self.dataStoreUUID = resolved
        // macOS 14+ persistent data store keyed by UUID — survives across launches
        // because the bytes-on-disk live under
        // ~/Library/WebKit/<bundle id>/WebsiteData/<uuid>/.
        self.dataStore = WKWebsiteDataStore(forIdentifier: resolved)
    }

    /// Acquire (or create) the WKWebView for `tabID`. Touches the LRU tracker.
    /// If a 9th tab acquires, the oldest WebView is evicted: its
    /// `interactionState` is captured into `savedInteractionStates` so a future
    /// re-acquire for that tab restores scroll/form state.
    func acquireWebView(forTabID tabID: Int64) -> WKWebView {
        if let existing = live[tabID] {
            tracker.touch(tabID)
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Loom/0.1 (macOS) WebKit"
        live[tabID] = webView

        // Restore prior interactionState if we had evicted this tab earlier.
        if let saved = savedInteractionStates[tabID] {
            webView.interactionState = saved
            savedInteractionStates[tabID] = nil
        }

        if let evicted = tracker.touch(tabID) {
            evict(tabID: evicted)
        }
        return webView
    }

    /// Drop the WebView for `tabID` (e.g. tab removed). Also clears any saved
    /// interaction state.
    func release(tabID: Int64) {
        if let view = live.removeValue(forKey: tabID) {
            view.stopLoading()
        }
        savedInteractionStates[tabID] = nil
        tracker.remove(tabID)
    }

    // MARK: - Internals

    private func evict(tabID: Int64) {
        guard let view = live.removeValue(forKey: tabID) else { return }
        savedInteractionStates[tabID] = view.interactionState
        view.stopLoading()
        LoomLog.ui.info("WebView pool evicted tabID=\(tabID, privacy: .public)")
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
