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
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var heldGrants: Set<String> = []

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
        hold(grant: "refresh_token")
    }

    /// Requests of `grant` ("authorization_code" or "refresh_token") wait
    /// until `release()`.
    func hold(grant: String) {
        _ = lock.withLock { heldGrants.insert(grant) }
    }

    func release() {
        let open = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            heldGrants = []
            defer { gates = [] }
            return gates
        }
        for gate in open { gate.resume() }
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
            return (offline, heldGrants.contains(form["grant_type"] ?? ""))
        }
        if waits {
            await withCheckedContinuation { continuation in
                lock.withLock { gates.append(continuation) }
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
/// bodies; answers from a queue per operation (the last repeats). Requests
/// can be held, all of them or one operation's, and how many of each are
/// out at once is counted (for the one-at-a-time watch rule).
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
        var deviceToken: String? = nil
        var environment: String? = nil
    }

    private struct Gate {
        var id: UUID
        var operationID: String
        var continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var answers: [String: [Answer]] = [:]
    private var recorded: [Seen] = []
    private var offline = false
    private var gates: [Gate] = []
    private var holdsAll = false
    private var heldOperations: Set<String> = []
    private var inFlight: [String: Int] = [:]
    private var peaks: [String: Int] = [:]

    func answer(_ operationID: String, _ list: Answer...) {
        lock.withLock { answers[operationID] = list }
    }

    func setOffline(_ value: Bool) {
        lock.withLock { offline = value }
    }

    /// Requests wait until `release()`.
    func hold() {
        lock.withLock { holdsAll = true }
    }

    /// Requests of `operationID` wait until `release(operationID)` or `release()`.
    func hold(_ operationID: String) {
        _ = lock.withLock { heldOperations.insert(operationID) }
    }

    func release() {
        let open = lock.withLock { () -> [Gate] in
            holdsAll = false
            heldOperations = []
            defer { gates = [] }
            return gates
        }
        for gate in open { gate.continuation.resume() }
    }

    func release(_ operationID: String) {
        let open = lock.withLock { () -> [Gate] in
            heldOperations.remove(operationID)
            guard !holdsAll else { return [] }
            let matching = gates.filter { $0.operationID == operationID }
            gates.removeAll { $0.operationID == operationID }
            return matching
        }
        for gate in open { gate.continuation.resume() }
    }

    var seen: [Seen] {
        lock.withLock { recorded }
    }

    func count(_ operationID: String) -> Int {
        seen.filter { $0.operationID == operationID }.count
    }

    /// The most requests of `operationIDs` that were out at the same time.
    func peak(_ operationIDs: String...) -> Int {
        lock.withLock { operationIDs.compactMap { peaks[$0] }.max() ?? 0 }
    }

    /// Requests of `operationID` out now.
    func outstanding(_ operationID: String) -> Int {
        lock.withLock { inFlight[operationID] ?? 0 }
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var entry = Seen(operationID: operationID, token: request.headerFields[RawGoogleTokenHeader.name], calendars: [], timezone: nil)
        if let body {
            let data = try await Data(collecting: body, upTo: 1 << 20)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            entry.calendars = object?["calendars"] as? [String] ?? []
            entry.timezone = object?["timezone"] as? String
            entry.deviceToken = object?["deviceToken"] as? String
            entry.environment = object?["environment"] as? String
        }
        let waits = lock.withLock { () -> Bool in
            recorded.append(entry)
            // Watch and unwatch count together: the API sees both as one device's state.
            let key = Self.isPush(operationID) ? Self.pushKey : operationID
            inFlight[key, default: 0] += 1
            peaks[key] = max(peaks[key] ?? 0, inFlight[key] ?? 0)
            if key != operationID { inFlight[operationID, default: 0] += 1 }
            return holdsAll || heldOperations.contains(operationID)
        }
        defer {
            lock.withLock {
                let key = Self.isPush(operationID) ? Self.pushKey : operationID
                inFlight[key, default: 1] -= 1
                if key != operationID { inFlight[operationID, default: 1] -= 1 }
            }
        }
        if waits {
            // A held request ends when released or when its task is
            // cancelled, whichever comes first.
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock { () -> Bool in
                        if !(holdsAll || heldOperations.contains(operationID)) || Task.isCancelled { return true }
                        gates.append(Gate(id: id, operationID: operationID, continuation: continuation))
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let gate = lock.withLock { () -> Gate? in
                    guard let index = gates.firstIndex(where: { $0.id == id }) else { return nil }
                    return gates.remove(at: index)
                }
                gate?.continuation.resume()
            }
        }
        // As URLSession does: a request whose task is cancelled fails.
        if Task.isCancelled { throw URLError(.cancelled) }
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

    private static func isPush(_ operationID: String) -> Bool {
        operationID == postWatch || operationID == postUnwatch
    }

    /// The key under which watch and unwatch are counted together.
    static let pushKey = "push"

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

    /// A watch answer: per calendar index, nil for ok or an error code;
    /// `expiresAt` nil when no channel was made.
    static func watch(_ statuses: [String?], expiresAt: String?) -> Answer {
        let calendars = statuses.enumerated().map { index, error -> [String: Any] in
            var status: [String: Any] = ["index": index, "ok": error == nil]
            status["error"] = error
            return status
        }
        let object: [String: Any] = ["calendars": calendars, "expiresAt": expiresAt as Any? ?? NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return Answer(status: .ok, json: String(decoding: data, as: UTF8.self))
    }

    static func unwatched(_ removed: Int) -> Answer {
        Answer(status: .ok, json: #"{"removed":\#(removed)}"#)
    }

    static let getCalendars = "getGoogleCalendars"
    static let postEvents = "postGoogleEvents"
    static let postWatch = "postGoogleWatch"
    static let postUnwatch = "postGoogleUnwatch"
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
