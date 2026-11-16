import Foundation
import HTTPTypes
import Testing

@testable import Seasign

/// `SeasignAPI.discover` through the generated client and a stub transport.
@Suite struct DiscoverAPITests {
    private let key = APIKey(typed: fakeKey)!

    @Test func decodesTheAnswer() async throws {
        let stub = DiscoverStub()
        let answer = try await stubbedDiscoverAPI(stub).discover(
            key: key, provider: .anthropic, interests: ["tide pools"], timezone: "America/New_York"
        )
        #expect(answer.provider == .anthropic)
        #expect(answer.searchedAt == instant("2026-11-15T23:00:00Z"))
        #expect(answer.items.count == 3)
        #expect(answer.items[0].published == instant("2026-11-15T20:00:00Z"))
        #expect(answer.items[0].interest == "tide pools")
        #expect(answer.items[1].published == nil)
        #expect(answer.items[1].excerpt == nil)
        #expect(answer.items[1].interest == nil)
    }

    /// The key goes in the `X-LLM-Key` header and nowhere else: not in the
    /// path, the query or the body, and not in any other header.
    @Test func theKeyIsInTheHeaderOnly() async throws {
        let stub = DiscoverStub()
        _ = try await stubbedDiscoverAPI(stub).discover(
            key: key, provider: .openai, interests: ["tide pools", "lake ice"], timezone: "America/Chicago"
        )
        let recorded = try #require(stub.requests.first)
        #expect(recorded.request.headerFields[RawKeyHeader.name] == fakeKey)
        #expect(recorded.request.path?.contains(fakeKey) == false)
        for field in recorded.request.headerFields where field.name != RawKeyHeader.name {
            #expect(!field.value.contains(fakeKey))
        }
        let body = String(decoding: recorded.body, as: UTF8.self)
        #expect(!body.contains(fakeKey))
        let object = try #require(try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        #expect(object["provider"] as? String == "openai")
        #expect(object["interests"] as? [String] == ["tide pools", "lake ice"])
        #expect(object["timezone"] as? String == "America/Chicago")
        #expect(Set(object.keys) == ["provider", "interests", "timezone"])
    }

    /// The generated client writes headers as URI components; the key must
    /// still arrive exactly as typed, whatever printable characters it holds.
    @Test(arguments: [
        "test/key+not=real%0000",
        "test-key-not-real_~.0000",
        "!\"#$&'()*,:;<>?@[\\]^`{|}-not-real",
        "test%2Fkey%not%25real",
    ])
    func keysWithAnyPrintableCharacterArriveUnchanged(raw: String) async throws {
        let stub = DiscoverStub()
        let key = try #require(APIKey(typed: raw))
        _ = try await stubbedDiscoverAPI(stub).discover(key: key, provider: .gemini, interests: ["x"], timezone: nil)
        let header = try #require(stub.requests.first?.request.headerFields[RawKeyHeader.name])
        #expect(Array(header.utf8) == Array(raw.utf8))
    }

    @Test func noTimeZoneIsLeftOut() async throws {
        let stub = DiscoverStub()
        _ = try await stubbedDiscoverAPI(stub).discover(key: key, provider: .perplexity, interests: ["x"], timezone: nil)
        let recorded = try #require(stub.requests.first)
        let object = try #require(try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        #expect(object["timezone"] == nil)
    }

    @Test(arguments: [
        (400, "invalid_request", SeasignAPI.DiscoverFailure.invalidRequest),
        (401, "invalid_key", .invalidKey),
        (402, "quota_exceeded", .quotaExceeded),
        (429, "rate_limited", .rateLimited),
        (500, "internal_error", .internalError),
        (502, "provider_error", .providerError),
        (504, "timeout", .timeout),
        (503, "internal_error", .unavailable),
        // A redirect is never followed (see RedirectTests); if one comes
        // back it is a failure like any status the API does not send.
        (307, "internal_error", .unavailable),
        (301, "internal_error", .unavailable),
    ])
    func eachErrorStatusMapsToItsFailure(status: Int, code: String, expected: SeasignAPI.DiscoverFailure) async {
        let stub = DiscoverStub()
        // The server's message holds the key, as a misbehaving server might.
        stub.answer(.init(code: status), #"{"error":"\#(code)","message":"bad key \#(fakeKey)"}"#)
        do {
            _ = try await stubbedDiscoverAPI(stub).discover(key: key, provider: .anthropic, interests: ["x"], timezone: nil)
            Issue.record("expected a failure")
        } catch {
            #expect(error as? SeasignAPI.DiscoverFailure == expected)
            #expect(!String(describing: error).contains(fakeKey))
            #expect(!String(reflecting: error).contains(fakeKey))
            #expect(!error.localizedDescription.contains(fakeKey))
        }
    }

    /// A time zone the API might not know is left out rather than sent: the
    /// API would answer 400 to every search.
    @Test(arguments: ["GMT-0500", "Mars/Olympus_Mons", "EST", ""])
    func aDoubtfulTimeZoneIsLeftOut(zone: String) async throws {
        let stub = DiscoverStub()
        _ = try await stubbedDiscoverAPI(stub).discover(key: key, provider: .anthropic, interests: ["x"], timezone: zone)
        let recorded = try #require(stub.requests.first)
        let object = try #require(try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        #expect(object["timezone"] == nil)
        #expect(object["interests"] as? [String] == ["x"])
    }

    @Test func gmtIsSentAsUTC() async throws {
        let stub = DiscoverStub()
        _ = try await stubbedDiscoverAPI(stub).discover(key: key, provider: .anthropic, interests: ["x"], timezone: "GMT")
        let recorded = try #require(stub.requests.first)
        let object = try #require(try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        #expect(object["timezone"] as? String == "UTC")
    }

    // MARK: https only for the key (Release builds)

    /// With the Release rule on, a server that is not https never receives
    /// the key: nothing reaches the transport at all.
    @Test(arguments: ["http://example.test", "HTTP://example.test", "ftp://example.test", "example.test"])
    func withTheHTTPSRuleOnAPlainServerGetsNothing(server: String) async throws {
        let stub = DiscoverStub()
        let api = SeasignAPI(serverURL: try #require(URL(string: server)), transport: stub, keyNeedsHTTPS: true)
        await #expect(throws: SeasignAPI.DiscoverFailure.unavailable) {
            try await api.discover(key: key, provider: .anthropic, interests: ["x"], timezone: nil)
        }
        #expect(stub.count == 0)
    }

    @Test(arguments: ["https://example.test", "HTTPS://example.test"])
    func withTheHTTPSRuleOnAnHTTPSServerIsCalled(server: String) async throws {
        let stub = DiscoverStub()
        let api = SeasignAPI(serverURL: try #require(URL(string: server)), transport: stub, keyNeedsHTTPS: true)
        _ = try await api.discover(key: key, provider: .anthropic, interests: ["x"], timezone: nil)
        #expect(stub.count == 1)
        #expect(stub.requests.first?.request.headerFields[RawKeyHeader.name] == fakeKey)
    }

    /// Debug builds talk to `wrangler dev` over plain http.
    @Test func withTheHTTPSRuleOffAPlainServerIsCalled() async throws {
        let stub = DiscoverStub()
        let api = SeasignAPI(serverURL: URL(string: "http://localhost:8787")!, transport: stub, keyNeedsHTTPS: false)
        _ = try await api.discover(key: key, provider: .anthropic, interests: ["x"], timezone: nil)
        #expect(stub.count == 1)
    }

    /// The rule follows the build: on in Release, off in Debug (tests run Debug).
    @Test func theRuleIsOffOnlyInDebugBuilds() {
        #if DEBUG
        #expect(SeasignAPI.keyNeedsHTTPSByDefault == false)
        #else
        #expect(SeasignAPI.keyNeedsHTTPSByDefault == true)
        #endif
        #expect(SeasignAPI.defaultServerURL.scheme == (SeasignAPI.keyNeedsHTTPSByDefault ? "https" : "http"))
    }

    /// The shared session keeps nothing between requests.
    @Test func theSessionStoresNoCookiesCacheOrCredentials() {
        let configuration = SeasignAPI.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(SeasignAPI.session.delegate is RefuseRedirects)
    }

    @Test func anUnreadableAnswerIsUnavailable() async {
        let stub = DiscoverStub()
        stub.answer(.ok, #"{"items":[{"title":1}],"provider":"anthropic"}"#)
        await #expect(throws: SeasignAPI.DiscoverFailure.unavailable) {
            try await stubbedDiscoverAPI(stub).discover(key: key, provider: .anthropic, interests: ["x"], timezone: nil)
        }
    }

    /// A transport error is wrapped by the generated client in an error that
    /// describes the request, header included. None of it may come through.
    @Test func aTransportErrorCarriesNothingOfTheRequest() async {
        let stub = DiscoverStub()
        stub.fail(with: EchoingError(text: "x-llm-key: " + fakeKey))
        do {
            _ = try await stubbedDiscoverAPI(stub).discover(key: key, provider: .anthropic, interests: ["x"], timezone: nil)
            Issue.record("expected a failure")
        } catch {
            #expect(error as? SeasignAPI.DiscoverFailure == .unavailable)
            var dumped = ""
            dump(error, to: &dumped)
            #expect(!dumped.contains(fakeKey))
            #expect(!String(reflecting: error).contains(fakeKey))
        }
    }
}
