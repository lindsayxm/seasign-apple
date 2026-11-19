import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import Seasign

/// Made-up Google values. None has the shape of a real Google token (no
/// `ya29.` or `1//` prefix); the access token holds `/`, `+` and `=` so the
/// raw-header test can see they arrive as themselves.
enum FakeGoogle {
    static let clientID = "000000000000-testclientnotreal.apps.googleusercontent.com"
    static let config = GoogleOAuthConfig(clientID: clientID)
    static let access = "fake-access-token/not+real="
    static let access2 = "fake-access-token-two/not+real="
    static let refresh = "fake-refresh-token/not+real"
    static let code = "fake-auth-code/not+real"
    static let bothScopes = GoogleOAuthConfig.scopes.joined(separator: " ")
}

/// Stands in for Google's token and revoke endpoints. Answers each grant
/// type from a queue (the last answer repeats), records every form sent,
/// and can hold a refresh until released, to test that renewals are shared.
final class FakeGoogleEndpoint: @unchecked Sendable {
    struct Answer {
        var status: Int
        var json: String
    }

    struct Sent {
        var url: URL
        var method: String?
        var contentType: String?
        var form: [String: String]
    }

    private let lock = NSLock()
    private var answers: [String: [Answer]] = [:]
    private var recorded: [Sent] = []
    private var offline = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holdsRefresh = false

    static func tokens(access: String = FakeGoogle.access, refresh: String? = FakeGoogle.refresh, expiresIn: Int = 3599, scope: String = FakeGoogle.bothScopes) -> Answer {
        var object: [String: Any] = ["access_token": access, "expires_in": expiresIn, "token_type": "Bearer", "scope": scope]
        object["refresh_token"] = refresh
        let data = try! JSONSerialization.data(withJSONObject: object)
        return Answer(status: 200, json: String(decoding: data, as: UTF8.self))
    }

    static func error(_ code: String, status: Int = 400) -> Answer {
        Answer(status: status, json: #"{"error":"\#(code)","error_description":"Made-up description."}"#)
    }

    /// Answers for `grant` ("authorization_code" or "refresh_token").
    func answer(_ grant: String, _ list: Answer...) {
        lock.withLock { answers[grant] = list }
    }

    func setOffline(_ value: Bool) {
        lock.withLock { offline = value }
    }

    /// Refreshes wait until `release()`.
    func holdRefreshes() {
        lock.withLock { holdsRefresh = true }
    }

    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdsRefresh = false
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    var sent: [Sent] {
        lock.withLock { recorded }
    }

    func sent(grant: String) -> [Sent] {
        sent.filter { $0.form["grant_type"] == grant }
    }

    var revoked: [String] {
        sent.filter { $0.url == GoogleOAuthConfig.revokeEndpoint }.compactMap { $0.form["token"] }
    }

    var http: GoogleHTTP {
        { [self] request in try await self.handle(request) }
    }

    private func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let form = Self.parseForm(request.httpBody ?? Data())
        let sent = Sent(
            url: request.url!,
            method: request.httpMethod,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            form: form
        )
        let (isOffline, waits) = lock.withLock { () -> (Bool, Bool) in
            recorded.append(sent)
            return (offline, holdsRefresh && form["grant_type"] == "refresh_token")
        }
        if waits {
            await withCheckedContinuation { continuation in
                lock.withLock { gate = continuation }
            }
        }
        if isOffline { throw URLError(.notConnectedToInternet) }
        let response = { (status: Int) in
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        }
        if request.url == GoogleOAuthConfig.revokeEndpoint {
            return (Data(), response(200))
        }
        let grant = form["grant_type"] ?? ""
        let answer = lock.withLock { () -> Answer in
            var list = answers[grant] ?? [Self.error("invalid_request")]
            let first = list.first!
            if list.count > 1 { list.removeFirst() }
            answers[grant] = list
            return first
        }
        return (Data(answer.json.utf8), response(answer.status))
    }

    static func parseForm(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }
}

/// Answers the API's `/v1/google/*` routes. Records the request headers and
/// bodies; answers from a queue per operation (the last repeats).
final class GoogleAPIStub: ClientTransport, @unchecked Sendable {
    struct Answer {
        var status: HTTPResponse.Status
        var json: String
        var retryAfter: String? = nil
    }

    struct Seen {
        var operationID: String
        var token: String?
        var calendars: [String]
        var timezone: String?
    }

    private let lock = NSLock()
    private var answers: [String: [Answer]] = [:]
    private var recorded: [Seen] = []
    private var offline = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holds = false

    func answer(_ operationID: String, _ list: Answer...) {
        lock.withLock { answers[operationID] = list }
    }

    func setOffline(_ value: Bool) {
        lock.withLock { offline = value }
    }

    /// Requests wait until `release()`.
    func hold() {
        lock.withLock { holds = true }
    }

    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holds = false
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    var seen: [Seen] {
        lock.withLock { recorded }
    }

    func count(_ operationID: String) -> Int {
        seen.filter { $0.operationID == operationID }.count
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var entry = Seen(operationID: operationID, token: request.headerFields[RawGoogleTokenHeader.name], calendars: [], timezone: nil)
        if let body {
            let data = try await Data(collecting: body, upTo: 1 << 20)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            entry.calendars = object?["calendars"] as? [String] ?? []
            entry.timezone = object?["timezone"] as? String
        }
        let waits = lock.withLock { () -> Bool in
            recorded.append(entry)
            return holds
        }
        if waits {
            await withCheckedContinuation { continuation in
                lock.withLock { gate = continuation }
            }
        }
        let (isOffline, answer) = lock.withLock { () -> (Bool, Answer?) in
            var list = answers[operationID] ?? []
            let first = list.first
            if list.count > 1 { list.removeFirst() }
            answers[operationID] = list
            return (offline, first)
        }
        if isOffline { throw URLError(.cannotConnectToHost) }
        guard let answer else { throw URLError(.badServerResponse) }
        var response = HTTPResponse(status: answer.status)
        response.headerFields[.contentType] = "application/json"
        if let retryAfter = answer.retryAfter {
            response.headerFields[HTTPField.Name("Retry-After")!] = retryAfter
        }
        return (response, HTTPBody(answer.json))
    }

    static func calendars(_ list: [(id: String, name: String, primary: Bool)]) -> Answer {
        let items = list.map { ["id": $0.id, "name": $0.name, "primary": $0.primary, "selected": true] as [String: Any] }
        let data = try! JSONSerialization.data(withJSONObject: ["calendars": items])
        return Answer(status: .ok, json: String(decoding: data, as: UTF8.self))
    }

    /// `events`: (calendar index, title, start, end). `statuses`: per index,
    /// nil for ok or an error code.
    static func events(_ events: [(Int, String, String, String)], statuses: [String?]) -> Answer {
        let items = events.map { ["calendar": $0.0, "title": $0.1, "start": $0.2, "end": $0.3, "allDay": false] as [String: Any] }
        let calendars = statuses.enumerated().map { index, error -> [String: Any] in
            var status: [String: Any] = ["index": index, "ok": error == nil, "partial": false]
            status["error"] = error
            return status
        }
        let data = try! JSONSerialization.data(withJSONObject: ["events": items, "calendars": calendars])
        return Answer(status: .ok, json: String(decoding: data, as: UTF8.self))
    }

    static func error(_ status: HTTPResponse.Status, _ code: String, retryAfter: String? = nil) -> Answer {
        Answer(status: status, json: #"{"error":"\#(code)","message":"Made-up message."}"#, retryAfter: retryAfter)
    }

    static let getCalendars = "getGoogleCalendars"
    static let postEvents = "postGoogleEvents"
}

/// A clock the tests move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        value = start
    }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}
