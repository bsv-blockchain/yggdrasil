import AppKit
import AuthenticationServices
import Foundation

/// Production `WebAuthPresenter` backed by `ASWebAuthenticationSession`.
///
/// The system presents a Safari-backed sheet for the GitHub authorize URL.
/// Because that sheet runs in the platform's secure web context, **passkeys
/// (WebAuthn) work natively** — including iCloud Keychain passkeys and security
/// keys — with NO special browser entitlement. The sheet redirects to our
/// custom scheme (`yggdrasil://oauth-callback`) once GitHub finishes auth, and
/// we hand the callback URL back to the orchestrator.
@MainActor
final class ASWebAuthPresenter: NSObject, WebAuthPresenter, ASWebAuthenticationPresentationContextProviding {
    /// Held for the lifetime of the sheet — ASWebAuthenticationSession aborts
    /// the moment it deallocates, so a local would be cancelled immediately.
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                self?.activeSession = nil
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.missingCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // Use the shared session so existing GitHub login / passkey state is
            // available; ephemeral would force a fresh, cookie-less context.
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                continuation.resume(throwing: OAuthError.userCancelled)
            }
        }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible })
            ?? NSApp.windows.first
            ?? ASPresentationAnchor()
    }
}
