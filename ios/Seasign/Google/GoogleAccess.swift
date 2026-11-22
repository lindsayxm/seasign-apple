import Foundation

/// The Google access token, in memory only, and its renewal from the
/// refresh token in the Keychain. One renewal runs at a time: the poll, the
/// pull and the return to the foreground share it.
@MainActor
final class GoogleAccess {
    /// Why no access token could be had. It carries no token.
    enum Failure: Error, Equatable {
        /// Google refused the refresh token (`invalid_grant`), or none is
        /// stored: the user must connect again.
        case signInEnded
        /// The Keychain could not be read (before the phone's first unlock,
        /// say). The sign-in is probably still there.
        case keychainUnreadable
        /// Google could not be reached or failed; try later.
        case unavailable
        /// Google refused the request with another OAuth error code.
        case rejected(String)
    }

    /// A token with less than this left is renewed before it is used.
    static let renewalMargin: TimeInterval = 120

    private let client: GoogleTokenClient
    private let store: any GoogleTokenStore
    private let now: @Sendable () -> Date
    private var current: (token: GoogleSecret, expiresAt: Date)? {
        didSet { if let current { last = current.token } }
    }
    /// The last token had, kept after `invalidate()` (not after `forget()`)
    /// for the unwatch sent when the sign-in ends: the API forgets the
    /// channels whatever Google makes of the token.
    private var last: GoogleSecret?
    private var renewal: Task<GoogleSecret, any Error>?
    /// Moves on `forget()`, so a renewal that ends afterwards is not kept.
    private var generation = 0
    /// Told the granted scopes when a renewal's answer names them (Google's
    /// docs show `scope` in a refresh answer but do not promise it; an
    /// answer without it says nothing, and this is not called).
    var scopesRenewed: (@MainActor (Set<String>) -> Void)?

    init(client: GoogleTokenClient, store: any GoogleTokenStore, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.store = store
        self.now = now
    }

    /// A token good for at least `renewalMargin`, renewed if needed.
    func token() async throws(Failure) -> GoogleSecret {
        if let current, current.expiresAt.timeIntervalSince(now()) > Self.renewalMargin {
            return current.token
        }
        return try await renew()
    }

    /// The token in memory if it has at least `renewalMargin` left; never renews.
    var validToken: GoogleSecret? {
        guard let current, current.expiresAt.timeIntervalSince(now()) > Self.renewalMargin else { return nil }
        return current.token
    }

    /// The last token had this session, even an expired or refused one; never renews.
    var lastToken: GoogleSecret? {
        current?.token ?? last
    }

    /// Drops the token in memory (after Google refused it with a 401), so
    /// the next `token()` renews it.
    func invalidate() {
        current = nil
    }

    /// Takes the tokens of a new sign-in.
    func set(_ tokens: GoogleTokens) {
        generation += 1
        renewal?.cancel()
        renewal = nil
        current = (tokens.access, tokens.expiresAt)
    }

    /// Forgets everything in memory (on Disconnect or when the sign-in ended).
    func forget() {
        generation += 1
        renewal?.cancel()
        renewal = nil
        current = nil
        last = nil
    }

    private func renew() async throws(Failure) -> GoogleSecret {
        let task: Task<GoogleSecret, any Error>
        if let renewal {
            task = renewal
        } else {
            let started = generation
            let client = client
            let store = store
            task = Task { @MainActor [weak self] in
                let stored: GoogleSecret?
                do {
                    stored = try store.read()
                } catch {
                    throw Failure.keychainUnreadable
                }
                guard let stored else { throw Failure.signInEnded }
                let fresh: GoogleTokens
                do {
                    fresh = try await client.refresh(stored)
                } catch GoogleTokenError.invalidGrant {
                    throw Failure.signInEnded
                } catch GoogleTokenError.rejected(let code) {
                    throw Failure.rejected(code)
                } catch {
                    throw Failure.unavailable
                }
                guard let self, self.generation == started else { throw Failure.unavailable }
                // Google may rotate the refresh token; otherwise the stored one stays.
                if let rotated = fresh.refresh, rotated != stored { try? store.save(rotated) }
                self.current = (fresh.access, fresh.expiresAt)
                if let scopes = fresh.scopes { self.scopesRenewed?(scopes) }
                return fresh.access
            }
            renewal = task
        }
        do {
            let token = try await task.value
            if renewal == task { renewal = nil }
            return token
        } catch {
            if renewal == task { renewal = nil }
            throw (error as? Failure) ?? .unavailable
        }
    }
}
