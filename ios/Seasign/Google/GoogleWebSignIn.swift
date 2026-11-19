import AuthenticationServices
import UIKit

/// Opens Google's sign-in page in an `ASWebAuthenticationSession` and returns
/// the redirect URL. The session is ephemeral: it shares no cookies with
/// Safari and leaves none behind, so the Google account is chosen on this
/// sheet each time and nothing of the sign-in stays in the browser.
///
/// The redirect URL holds the one-time authorization code; it is handed to
/// `GoogleCalendarModel.connect` and not kept or logged.
@MainActor
final class GoogleWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Kept while the sheet is up; a session that is not retained ends.
    private var session: ASWebAuthenticationSession?

    func signIn(url: URL, callbackScheme: String) async throws -> URL {
        session?.cancel()
        return try await withCheckedThrowingContinuation { continuation in
            // `@Sendable`: the SDK does not say which thread calls this.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable [weak self] callback, error in
                Task { @MainActor in self?.session = nil }
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleSignInCancelled())
                } else {
                    // The underlying error is dropped: it may describe the URL.
                    continuation.resume(throwing: URLError(.cannotConnectToHost))
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: URLError(.cannotConnectToHost))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let window = active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first {
                return window
            }
            return ASPresentationAnchor()
        }
    }
}
