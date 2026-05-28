import SwiftUI

/// GitHub account pane: sign in via the system auth sheet (passkeys supported)
/// or sign out. When signed in through OAuth, that token is used for all GitHub
/// API calls in preference to the `gh` CLI.
struct AccountPrefsPane: View {
    let services: AppServices

    @State private var signedIn = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub Account").font(.title3).bold()

            if !services.oauthConfig.isConfigured {
                Label(
                    "GitHub OAuth isn't configured. Set the client id/secret (see RELEASE.md) to enable passkey sign-in.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
                .font(.callout)
            }

            HStack(spacing: 8) {
                Image(systemName: signedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(signedIn ? .green : .secondary)
                Text(signedIn
                    ? "Signed in to GitHub (OAuth token in use)."
                    : "Not signed in — GitHub API uses your `gh` CLI token, if any.")
                    .font(.callout)
            }

            HStack(spacing: 10) {
                if signedIn {
                    Button("Sign Out", role: .destructive) { signOut() }
                        .disabled(busy)
                } else {
                    Button("Sign in to GitHub") { signIn() }
                        .disabled(busy || !services.oauthConfig.isConfigured)
                }
                if busy { ProgressView().controlSize(.small) }
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Text("Sign-in opens a secure system window. Passkeys, security keys, and password login all work there — no browser entitlement required.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .onAppear { signedIn = services.oauthStore.readToken() != nil }
    }

    private func signIn() {
        busy = true
        errorText = nil
        Task {
            do {
                try await services.oauthLogin.login()
                signedIn = true
            } catch OAuthError.userCancelled {
                // User dismissed the sheet — not an error worth surfacing.
            } catch {
                errorText = "Sign-in failed: \(error)"
            }
            busy = false
        }
    }

    private func signOut() {
        busy = true
        errorText = nil
        Task {
            await services.oauthLogin.logout()
            signedIn = false
            busy = false
        }
    }
}
