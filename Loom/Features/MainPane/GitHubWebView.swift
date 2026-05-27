import AppKit
@preconcurrency import WebKit
import SwiftUI

/// Placeholder for the GitHub WebView. Phase 5 Task 3 replaces this with the
/// full WKWebView-backed view (pool, persistent data store, offline state).
struct GitHubWebView: View {
    let services: AppServices
    let tab: LoomTab
    let url: URL

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(url.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("WebView coming in the next commit")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
