import CryptoKit
import Foundation
import Security

/// A Google OAuth secret: an access token, a refresh token, an authorization
/// code or the PKCE verifier. Held only as long as it is needed.
///
/// Like `APIKey`, it prints, reflects and debug-prints as `<redacted>`, so a
/// token that ends up in an interpolation, a `dump`, a test failure or a
/// debugger summary shows nothing. It is not `Codable`: the refresh token is
/// stored only in the Keychain (`GoogleTokenStore`) and nothing else is kept.
struct GoogleSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The secret itself. Read only where a request is built.
    let secret: String

    init(_ secret: String) {
        self.secret = secret
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The app's Google OAuth client: the iOS client the user made in Google
/// Cloud for this bundle ID. The client ID is set in one place, the
/// `GOOGLE_CLIENT_ID` build setting in `ios/project.yml`, which writes it to
/// the Info.plist (`GoogleClientID`) and registers the redirect scheme
/// derived from it (`CFBundleURLTypes`). A client ID is not a secret.
struct GoogleOAuthConfig: Sendable, Equatable {
    var clientID: String

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Read-only access to events, and to the list of calendars.
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    ]

    private static let clientSuffix = ".apps.googleusercontent.com"

    /// The client ID without `.apps.googleusercontent.com`.
    private var clientNumber: String {
        clientID.hasSuffix(Self.clientSuffix) ? String(clientID.dropLast(Self.clientSuffix.count)) : clientID
    }

    /// The client ID in reverse DNS form, which Google accepts as an iOS
    /// client's redirect scheme: `com.googleusercontent.apps.<number>`.
    var redirectScheme: String {
        "com.googleusercontent.apps." + clientNumber
    }

    /// The redirect URI, the same in the authorization request and the code
    /// exchange (Google requires them to match).
    var redirectURI: String {
        redirectScheme + ":/oauth2redirect"
    }

    /// The app's own client, from its Info.plist; nil when the build has none.
    static var main: GoogleOAuthConfig? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String,
              id.hasSuffix(clientSuffix), id.count > clientSuffix.count
        else { return nil }
        return GoogleOAuthConfig(clientID: id)
    }
}

/// PKCE (RFC 7636, `S256`) and the `state` value for one sign-in.
struct GooglePKCE: Sendable {
    /// 64 characters of the unreserved alphabet (48 random bytes, base64url).
    let verifier: GoogleSecret
    let challenge: String
    /// Random, checked against the redirect to refuse an answer this sign-in
    /// did not ask for.
    let state: String

    init() {
        self.init(verifier: Self.randomBase64URL(bytes: 48), state: Self.randomBase64URL(bytes: 32))
    }

    init(verifier: String, state: String) {
        self.verifier = GoogleSecret(verifier)
        challenge = Self.challenge(for: verifier)
        self.state = state
    }

    /// BASE64URL(SHA256(ASCII(verifier))), without padding.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBase64URL(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // Not expected; fall back to the system generator, still random.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    /// The characters RFC 7636 allows in a verifier.
    static func isValidVerifier(_ text: String) -> Bool {
        (43...128).contains(text.utf8.count)
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-._~".unicodeScalars.contains($0) }
    }
}

/// The page the sign-in sheet opens, and what came back from it.
enum GoogleAuthorization {
    /// Google's consent page for `config` with `pkce`.
    static func url(config: GoogleOAuthConfig, pkce: GooglePKCE) -> URL {
        var components = URLComponents(url: GoogleOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        // `+` is a space to some servers; spell it out.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Why the redirect did not carry a usable code.
    enum RedirectProblem: Error, Equatable {
        /// `error=access_denied`: the user declined.
        case denied
        /// Another `error=` from Google: its code (`[a-z_]`, at most 40
        /// characters, else "unknown"), safe to show.
        case google(String)
        /// The `state` is missing or not this sign-in's.
        case stateMismatch
        /// Not our redirect, or no code in it.
        case malformed
    }

    /// The authorization code from the redirect `url`, after checking that it
    /// is our redirect URI (scheme, no host, path) and this sign-in's
    /// (`state`). The URL is read once and not kept.
    static func code(from url: URL, config: GoogleOAuthConfig, state: String) -> Result<GoogleSecret, RedirectProblem> {
        guard url.scheme?.lowercased() == config.redirectScheme.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: config.redirectURI),
              (components.host ?? "") == (expected.host ?? ""),
              components.path == expected.path
        else { return .failure(.malformed) }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        // The state is checked first, so an answer to another request says
        // nothing about this one, error or not.
        guard let returned = value("state"), returned == state else { return .failure(.stateMismatch) }
        if let error = value("error") {
            if error == "access_denied" { return .failure(.denied) }
            return .failure(.google(safeCode(error)))
        }
        guard let code = value("code"), !code.isEmpty else { return .failure(.malformed) }
        return .success(GoogleSecret(code))
    }

    /// An OAuth error code as it may be shown: lowercase letters and `_`,
    /// at most 40 characters; anything else is "unknown".
    static func safeCode(_ text: String) -> String {
        let allowed = text.count <= 40 && !text.isEmpty
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
        return allowed ? text : "unknown"
    }
}
