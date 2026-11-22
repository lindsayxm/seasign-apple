import Foundation

/// Sends one request to Google's token or revoke endpoint. The app uses
/// `GoogleTokenClient.liveHTTP`; tests stand in a fake endpoint.
typealias GoogleHTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// What Google's token endpoint answered to a code exchange or a refresh.
struct GoogleTokens: Sendable, Equatable {
    var access: GoogleSecret
    /// When the access token stops working, by this phone's clock.
    var expiresAt: Date
    /// Sent on the code exchange; usually absent on a refresh, when the
    /// stored one stays in use.
    var refresh: GoogleSecret?
    /// The scopes the user granted, when Google says (it may grant fewer
    /// than were asked for).
    var scopes: Set<String>?

    /// Whether both read scopes, which every connection needs, were granted.
    /// An answer without a `scope` field is taken as granting them. The
    /// write scope is not needed to connect.
    var grantsNeededScopes: Bool {
        guard let scopes else { return true }
        return Set(GoogleOAuthConfig.readScopes).isSubset(of: scopes)
    }

    /// Whether this answer says the write scope was granted. An answer
    /// without a `scope` field never does.
    var grantsWriteScope: Bool {
        GoogleOAuthConfig.allowsAddingEvents(scopes)
    }
}

/// Why a call to Google's token endpoint failed. It carries no token.
enum GoogleTokenError: Error, Equatable {
    /// `invalid_grant`: the refresh token (or code) is no longer good:
    /// revoked, expired (Google ends test-mode sign-ins after 7 days), or
    /// the code was used. The user must connect again.
    case invalidGrant
    /// Another OAuth error (`invalid_client`, `unauthorized_client`, ...):
    /// its code, safe to show (`GoogleAuthorization.safeCode`).
    case rejected(String)
    /// Google could not be reached, timed out, or sent something unreadable.
    case unavailable
    /// The answer lacked the access token, or the refresh token on a code
    /// exchange.
    case incomplete
}

/// Google's OAuth token endpoint for an installed (iOS) client: no client
/// secret, PKCE on the code exchange. Requests go straight from the phone
/// to Google over https; tokens travel in form bodies only, never in a URL.
struct GoogleTokenClient: Sendable {
    var config: GoogleOAuthConfig
    var http: GoogleHTTP
    var now: @Sendable () -> Date = { Date() }

    /// The live endpoint, through the API's session: ephemeral (no cookies,
    /// cache or credential store) and it never follows a redirect.
    static let liveHTTP: GoogleHTTP = { request in
        let (data, response) = try await SeasignAPI.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The authorization code from the redirect for tokens
    /// (`grant_type=authorization_code`).
    func exchange(code: GoogleSecret, verifier: GoogleSecret) async throws(GoogleTokenError) -> GoogleTokens {
        let tokens = try await post(GoogleOAuthConfig.tokenEndpoint, [
            ("client_id", config.clientID),
            ("code", code.secret),
            ("code_verifier", verifier.secret),
            ("grant_type", "authorization_code"),
            ("redirect_uri", config.redirectURI),
        ])
        guard tokens.refresh != nil else { throw .incomplete }
        return tokens
    }

    /// A new access token for the stored refresh token (`grant_type=refresh_token`).
    func refresh(_ refreshToken: GoogleSecret) async throws(GoogleTokenError) -> GoogleTokens {
        try await post(GoogleOAuthConfig.tokenEndpoint, [
            ("client_id", config.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken.secret),
        ])
    }

    /// Asks Google to revoke `token` (a refresh token also ends its access
    /// tokens). Best effort: the answer is not read and errors are dropped.
    func revoke(_ token: GoogleSecret) async {
        let request = Self.formRequest(GoogleOAuthConfig.revokeEndpoint, [("token", token.secret)])
        _ = try? await http(request)
    }

    private func post(_ url: URL, _ fields: [(String, String)]) async throws(GoogleTokenError) -> GoogleTokens {
        let sentAt = now()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http(Self.formRequest(url, fields))
        } catch {
            // Dropped on purpose: a URLError can carry the request.
            throw .unavailable
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard response.statusCode == 200 else {
            if let code = object?["error"] as? String {
                if code == "invalid_grant" { throw .invalidGrant }
                // Google answers 400 or 401 with an OAuth error code.
                if (400..<500).contains(response.statusCode) {
                    throw .rejected(GoogleAuthorization.safeCode(code))
                }
            }
            throw .unavailable
        }
        guard let object else { throw .unavailable }
        guard let access = object["access_token"] as? String, !access.isEmpty else { throw .incomplete }
        let lifetime = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let refresh = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : GoogleSecret($0) }
        let scopes = (object["scope"] as? String).map { Set($0.split(separator: " ").map(String.init)) }
        return GoogleTokens(
            access: GoogleSecret(access),
            expiresAt: sentAt.addingTimeInterval(max(0, lifetime)),
            refresh: refresh,
            scopes: scopes
        )
    }

    /// A POST with an `application/x-www-form-urlencoded` body.
    static func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    /// Percent-encodes everything but the unreserved characters, so `/`,
    /// `+` and `=` in a token arrive as themselves.
    static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
