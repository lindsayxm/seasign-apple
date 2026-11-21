import Foundation
import HTTPTypes
import OpenAPIRuntime
import Security
import SwiftData
import Testing

@testable import Seasign

// MARK: - PKCE, state and the authorization request

@Suite struct GooglePKCETests {
    /// RFC 7636, Appendix B.
    @Test func challengeMatchesTheRFCExample() {
        let pkce = GooglePKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func freshVerifiersAndStatesAreRandomAndWellFormed() {
        let first = GooglePKCE()
        let second = GooglePKCE()
        #expect(first.verifier.secret.count == 64)
        #expect(GooglePKCE.isValidVerifier(first.verifier.secret))
        #expect(first.verifier != second.verifier)
        #expect(first.state != second.state)
        #expect(first.state.count >= 32)
        #expect(first.challenge == GooglePKCE.challenge(for: first.verifier.secret))
        #expect(!first.challenge.contains("=") && !first.challenge.contains("+") && !first.challenge.contains("/"))
    }

    @Test func theVerifierNeverPrints() {
        let pkce = GooglePKCE()
        #expect("\(pkce.verifier)" == "<redacted>")
        #expect(String(reflecting: pkce.verifier) == "<redacted>")
        var dumped = ""
        dump(pkce, to: &dumped)
        #expect(!dumped.contains(pkce.verifier.secret))
    }

    @Test func authorizationURLAsksForCodeWithS256AndBothScopes() throws {
        let pkce = GooglePKCE(verifier: String(repeating: "a", count: 43), state: "state-123")
        let url = GoogleAuthorization.url(config: FakeGoogle.config, pkce: pkce)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == FakeGoogle.clientID)
        #expect(items["redirect_uri"] == "com.googleusercontent.apps.000000000000-testclientnotreal:/oauth2redirect")
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "state-123")
        #expect(items["scope"] == "https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly")
        // The verifier itself never leaves the phone before the exchange.
        #expect(!url.absoluteString.contains(pkce.verifier.secret))
        #expect(items["client_secret"] == nil)
    }

    @Test func theRedirectSchemeIsTheReversedClientIDAndIsRegistered() throws {
        let config = try #require(GoogleOAuthConfig.main, "the app's Info.plist names a Google client ID")
        #expect(config.clientID.hasSuffix(".apps.googleusercontent.com"))
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(config.redirectScheme))
        #expect(config.redirectScheme.hasPrefix("com.googleusercontent.apps."))
        #expect(!config.redirectScheme.contains("$("))
        #expect(config.redirectURI == config.redirectScheme + ":/oauth2redirect")
    }
}

@Suite struct GoogleRedirectTests {
    private let config = FakeGoogle.config
    private let scheme = FakeGoogle.config.redirectScheme

    private func parse(_ query: String, state: String = "abc") -> Result<GoogleSecret, GoogleAuthorization.RedirectProblem> {
        GoogleAuthorization.code(from: URL(string: "\(scheme):/oauth2redirect?\(query)")!, config: config, state: state)
    }

    @Test func aMatchingStateGivesTheCode() {
        #expect(parse("state=abc&code=the-code&scope=x") == .success(GoogleSecret("the-code")))
    }

    @Test func aDeclinedConsentIsDenied() {
        #expect(parse("state=abc&error=access_denied") == .failure(.denied))
    }

    @Test func anotherErrorKeepsOnlyASafeCode() {
        #expect(parse("state=abc&error=invalid_scope") == .failure(.google("invalid_scope")))
        #expect(parse("state=abc&error=%3Cscript%3E") == .failure(.google("unknown")))
    }

    @Test func aMismatchedOrMissingStateIsRefusedEvenWithACode() {
        #expect(parse("state=other&code=the-code") == .failure(.stateMismatch))
        #expect(parse("code=the-code") == .failure(.stateMismatch))
        #expect(parse("state=other&error=access_denied") == .failure(.stateMismatch))
    }

    @Test func anotherSchemeOrNoCodeIsMalformed() {
        let other = GoogleAuthorization.code(from: URL(string: "https://example.com/?state=abc&code=x")!, config: config, state: "abc")
        #expect(other == .failure(.malformed))
        #expect(parse("state=abc") == .failure(.malformed))
        #expect(parse("state=abc&code=") == .failure(.malformed))
    }

    @Test func onlyOurRedirectPathWithNoHostIsTaken() {
        func code(_ rest: String) -> Result<GoogleSecret, GoogleAuthorization.RedirectProblem> {
            GoogleAuthorization.code(from: URL(string: "\(scheme)\(rest)?state=abc&code=the-code")!, config: config, state: "abc")
        }
        #expect(code(":/oauth2redirect") == .success(GoogleSecret("the-code")))
        // The scheme is matched without regard to case, as before.
        #expect(GoogleAuthorization.code(
            from: URL(string: "\(scheme.uppercased()):/oauth2redirect?state=abc&code=the-code")!, config: config, state: "abc"
        ) == .success(GoogleSecret("the-code")))
        #expect(code(":/other") == .failure(.malformed))
        #expect(code(":/oauth2redirect/more") == .failure(.malformed))
        #expect(code(":/") == .failure(.malformed))
        #expect(code("://evil.example/oauth2redirect") == .failure(.malformed))
        #expect(code("://oauth2redirect") == .failure(.malformed))
    }
}

// MARK: - Token endpoint

@Suite struct GoogleTokenClientTests {
    private let endpoint = FakeGoogleEndpoint()
    private let clock = TestClock(instant("2026-11-19T12:00:00Z"))

    private var client: GoogleTokenClient {
        let clock = clock
        return GoogleTokenClient(config: FakeGoogle.config, http: endpoint.http, now: { clock.now })
    }

    @Test func theCodeExchangeSendsPKCEAndNoSecretInAFormBody() async throws {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        let tokens = try await client.exchange(code: GoogleSecret(FakeGoogle.code), verifier: GoogleSecret("v-123"))
        let sent = try #require(endpoint.sent.first)
        #expect(sent.url == URL(string: "https://oauth2.googleapis.com/token")!)
        #expect(sent.url.query == nil)
        #expect(sent.method == "POST")
        #expect(sent.contentType == "application/x-www-form-urlencoded")
        #expect(sent.form == [
            "client_id": FakeGoogle.clientID,
            "code": FakeGoogle.code,
            "code_verifier": "v-123",
            "grant_type": "authorization_code",
            "redirect_uri": FakeGoogle.config.redirectURI,
        ])
        #expect(tokens.access.secret == FakeGoogle.access)
        #expect(tokens.refresh?.secret == FakeGoogle.refresh)
        #expect(tokens.expiresAt == clock.now.addingTimeInterval(3599))
        #expect(tokens.grantsNeededScopes)
    }

    @Test func aRefreshSendsTheRefreshToken() async throws {
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let tokens = try await client.refresh(GoogleSecret(FakeGoogle.refresh))
        #expect(endpoint.sent.first?.form == [
            "client_id": FakeGoogle.clientID,
            "grant_type": "refresh_token",
            "refresh_token": FakeGoogle.refresh,
        ])
        #expect(tokens.access.secret == FakeGoogle.access2)
        #expect(tokens.refresh == nil)
    }

    @Test func errorsAreMapped() async {
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await #expect(throws: GoogleTokenError.invalidGrant) { try await client.refresh(GoogleSecret("r")) }
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_client", status: 401))
        await #expect(throws: GoogleTokenError.rejected("invalid_client")) { try await client.refresh(GoogleSecret("r")) }
        endpoint.answer("refresh_token", FakeGoogleEndpoint.Answer(status: 503, json: "<html>"))
        await #expect(throws: GoogleTokenError.unavailable) { try await client.refresh(GoogleSecret("r")) }
        endpoint.setOffline(true)
        await #expect(throws: GoogleTokenError.unavailable) { try await client.refresh(GoogleSecret("r")) }
    }

    @Test func anExchangeWithoutARefreshTokenIsIncomplete() async {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(refresh: nil))
        await #expect(throws: GoogleTokenError.incomplete) {
            try await client.exchange(code: GoogleSecret("c"), verifier: GoogleSecret("v"))
        }
    }

    @Test func aPartialGrantIsSeen() async throws {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(scope: GoogleOAuthConfig.scopes[0]))
        let tokens = try await client.exchange(code: GoogleSecret("c"), verifier: GoogleSecret("v"))
        #expect(!tokens.grantsNeededScopes)
    }

    @Test func revokeSendsTheTokenInTheBodyNotTheURL() async {
        await client.revoke(GoogleSecret(FakeGoogle.refresh))
        let sent = endpoint.sent.first
        #expect(sent?.url == URL(string: "https://oauth2.googleapis.com/revoke")!)
        #expect(sent?.url.query == nil)
        #expect(sent?.form["token"] == FakeGoogle.refresh)
    }

    @Test func formEncodingKeepsSlashPlusAndEquals() {
        #expect(GoogleTokenClient.formEncode("a/b+c=d e") == "a%2Fb%2Bc%3Dd%20e")
    }
}

@Suite @MainActor struct GoogleAccessTests {
    private let endpoint = FakeGoogleEndpoint()
    private let clock = TestClock(instant("2026-11-19T12:00:00Z"))

    private func access(_ store: InMemoryGoogleTokenStore) -> GoogleAccess {
        let clock = clock
        return GoogleAccess(client: GoogleTokenClient(config: FakeGoogle.config, http: endpoint.http, now: { clock.now }), store: store, now: { clock.now })
    }

    @Test func aTokenIsReusedUntilCloseToExpiryThenRenewed() async throws {
        let store = InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh))
        let access = access(store)
        access.set(GoogleTokens(access: GoogleSecret(FakeGoogle.access), expiresAt: clock.now.addingTimeInterval(3599), refresh: nil, scopes: nil))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        #expect(try await access.token().secret == FakeGoogle.access)
        clock.advance(3599 - 100)
        #expect(try await access.token().secret == FakeGoogle.access2)
        #expect(endpoint.sent(grant: "refresh_token").count == 1)
        // The stored refresh token stays when Google sends none.
        #expect(store.stored?.secret == FakeGoogle.refresh)
    }

    @Test func concurrentCallersShareOneRenewal() async throws {
        let access = access(InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh)))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        endpoint.holdRefreshes()
        async let first = access.token()
        async let second = access.token()
        async let third = access.token()
        try await Task.sleep(for: .milliseconds(100))
        endpoint.release()
        let tokens = try await [first, second, third]
        #expect(tokens.allSatisfy { $0.secret == FakeGoogle.access2 })
        #expect(endpoint.sent(grant: "refresh_token").count == 1)
    }

    @Test func invalidGrantOrNoStoredTokenEndsTheSignIn() async {
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await #expect(throws: GoogleAccess.Failure.signInEnded) {
            try await access(InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh))).token()
        }
        await #expect(throws: GoogleAccess.Failure.signInEnded) {
            try await access(InMemoryGoogleTokenStore()).token()
        }
        let locked = InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh))
        locked.setFailure(KeychainFailure(status: errSecInteractionNotAllowed))
        await #expect(throws: GoogleAccess.Failure.keychainUnreadable) { try await access(locked).token() }
    }

    @Test func aRotatedRefreshTokenIsStored() async throws {
        let store = InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: "fake-rotated-refresh"))
        _ = try await access(store).token()
        #expect(store.stored?.secret == "fake-rotated-refresh")
    }
}

// MARK: - API calls

@Suite struct GoogleAPITests {
    @Test func theTokenIsSentRawInItsOwnHeader() async throws {
        let stub = GoogleAPIStub()
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("primary-id", "Me", true)]))
        let api = SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub)
        _ = try await api.googleEvents(token: GoogleSecret(FakeGoogle.access), calendars: ["primary-id"], timezone: "America/Chicago")
        _ = try await api.googleCalendars(token: GoogleSecret(FakeGoogle.access))
        #expect(stub.seen.map(\.token) == [FakeGoogle.access, FakeGoogle.access])
        #expect(stub.seen.first?.calendars == ["primary-id"])
        #expect(stub.seen.first?.timezone == "America/Chicago")
    }

    @Test func theMiddlewareUndoesPercentEncodingOfThatHeaderOnly() async throws {
        var request = HTTPRequest(method: .get, scheme: "https", authority: "example.test", path: "/")
        request.headerFields[RawGoogleTokenHeader.name] = "a%2Fb%2Bc%3D"
        request.headerFields[HTTPField.Name("x-other")!] = "a%2Fb"
        let seen = SeenRequest()
        _ = try await RawGoogleTokenHeader().intercept(request, body: nil, baseURL: URL(string: "https://example.test")!, operationID: "x") { request, _, _ in
            seen.set(request)
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(seen.value?.headerFields[RawGoogleTokenHeader.name] == "a/b+c=")
        #expect(seen.value?.headerFields[HTTPField.Name("x-other")!] == "a%2Fb")
    }

    @Test func failuresAreMapped() async {
        let stub = GoogleAPIStub()
        let api = SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub)
        let token = GoogleSecret(FakeGoogle.access)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.unauthorized, "google_auth"))
        await #expect(throws: SeasignAPI.GoogleFailure.googleAuth) { try await api.googleEvents(token: token, calendars: ["a"], timezone: nil) }
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "42"))
        await #expect(throws: SeasignAPI.GoogleFailure.rateLimited(retryAfter: 42)) { try await api.googleEvents(token: token, calendars: ["a"], timezone: nil) }
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.error(.forbidden, "google_forbidden"))
        await #expect(throws: SeasignAPI.GoogleFailure.forbidden) { try await api.googleCalendars(token: token) }
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.error(.badGateway, "google_unavailable"))
        await #expect(throws: SeasignAPI.GoogleFailure.unavailable) { try await api.googleCalendars(token: token) }
    }

    @Test func releaseBuildsSendTheTokenOnlyOverHTTPS() async throws {
        let stub = GoogleAPIStub()
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("primary-id", "Me", true)]))
        let token = GoogleSecret(FakeGoogle.access)

        let plain = SeasignAPI(serverURL: URL(string: "http://example.test")!, transport: stub, keyNeedsHTTPS: true)
        await #expect(throws: SeasignAPI.GoogleFailure.unavailable) { try await plain.googleCalendars(token: token) }
        await #expect(throws: SeasignAPI.GoogleFailure.unavailable) {
            try await plain.googleEvents(token: token, calendars: ["primary-id"], timezone: nil)
        }
        #expect(stub.seen.isEmpty)

        let secure = SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub, keyNeedsHTTPS: true)
        _ = try await secure.googleCalendars(token: token)
        _ = try await secure.googleEvents(token: token, calendars: ["primary-id"], timezone: nil)
        #expect(stub.seen.count == 2)

        // Debug builds talk to `wrangler dev` over http on this Mac.
        let debug = SeasignAPI(serverURL: URL(string: "http://localhost:8787")!, transport: stub, keyNeedsHTTPS: false)
        _ = try await debug.googleCalendars(token: token)
        #expect(stub.seen.count == 3)
    }
}

private final class SeenRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: HTTPRequest?
    func set(_ value: HTTPRequest) { lock.withLock { request = value } }
    var value: HTTPRequest? { lock.withLock { request } }
}

// MARK: - Pure rules

@Suite struct GoogleRulesTests {
    private let now = instant("2026-11-19T12:00:00Z")

    @Test func linkAndGoogleEventsMergeSoonestFirstThreeAtMost() {
        let link = UUID()
        let google = UUID()
        let links = [
            UpcomingEvent(link: link, title: "Dentist", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000), allDay: false),
            UpcomingEvent(link: link, title: "Over", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), allDay: false),
            UpcomingEvent(link: link, title: "Later", start: now.addingTimeInterval(86400), end: now.addingTimeInterval(90000), allDay: false),
        ]
        let fromGoogle = [
            UpcomingEvent(link: google, title: "Coffee", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600), allDay: false),
            UpcomingEvent(link: google, title: "Swim", start: now.addingTimeInterval(10800), end: now.addingTimeInterval(14400), allDay: false),
        ]
        let next = TodayEvents.next(links: links, google: fromGoogle, now: now)
        #expect(next.map(\.title) == ["Coffee", "Dentist", "Swim"])
        let labels = TodayEvents.labels(links: links, google: [], now: now, timeZone: TimeZone(identifier: "UTC")!, clock: .twelveHour)
        #expect(labels.map(\.title) == ["Dentist", "Later"])
    }

    @Test func allDayAndTimedEventsOfBothKindsMergeInOneOrder() {
        // Noon on Thursday 19 November in Chicago.
        let noon = instant("2026-11-19T18:00:00Z")
        let chicago = TimeZone(identifier: "America/Chicago")!
        let link = UUID()
        let google = UUID()
        let links = [
            UpcomingEvent(link: link, title: "Dentist", start: instant("2026-11-19T20:00:00Z"), end: instant("2026-11-19T21:00:00Z"), allDay: false),
            // Tomorrow, all day: the same instant as the Google flight below.
            UpcomingEvent(link: link, title: "Trip", start: instant("2026-11-20T06:00:00Z"), end: instant("2026-11-21T06:00:00Z"), allDay: true, date: "2026-11-20"),
            // Yesterday, all day: over.
            UpcomingEvent(link: link, title: "Gone", start: instant("2026-11-18T06:00:00Z"), end: instant("2026-11-19T06:00:00Z"), allDay: true, date: "2026-11-18"),
        ]
        let fromGoogle = [
            UpcomingEvent(link: google, title: "Early flight", start: instant("2026-11-20T06:00:00Z"), end: instant("2026-11-20T08:00:00Z"), allDay: false),
            // Today, all day: began before now, still running.
            UpcomingEvent(link: google, title: "Holiday", start: instant("2026-11-19T06:00:00Z"), end: instant("2026-11-20T06:00:00Z"), allDay: true, date: "2026-11-19"),
        ]
        #expect(TodayEvents.next(links: links, google: fromGoogle, now: noon, limit: 4).map(\.title)
            == ["Holiday", "Dentist", "Trip", "Early flight"])
        // Either order of the two lists gives the same answer.
        #expect(TodayEvents.next(links: fromGoogle, google: links, now: noon, limit: 4).map(\.title)
            == ["Holiday", "Dentist", "Trip", "Early flight"])

        let labels = TodayEvents.labels(links: links, google: fromGoogle, now: noon, timeZone: chicago, clock: .twelveHour)
        #expect(labels.map(\.title) == ["Holiday", "Dentist", "Trip"])
        #expect(labels.map(\.time) == ["ALL DAY", "2:00PM", "FRI ALL DAY"])
    }

    @Test func pollingRunsOnlyWhileActiveOnTodayAndConnected() {
        #expect(GooglePoll.isOn(appActive: true, todayOnScreen: true, canPoll: true))
        #expect(!GooglePoll.isOn(appActive: false, todayOnScreen: true, canPoll: true))
        #expect(!GooglePoll.isOn(appActive: true, todayOnScreen: false, canPoll: true))
        #expect(!GooglePoll.isOn(appActive: true, todayOnScreen: true, canPoll: false))
        #expect(GooglePoll.interval == .seconds(5))
    }

    @Test func failuresBackOffUpToTwoMinutes() {
        #expect((0...8).map { GooglePoll.backoff(failures: $0) } == [0, 5, 10, 20, 40, 80, 120, 120, 120])
    }

    @Test func aNewListKeepsChoicesTurnsOnThePrimaryFirstAndDropsGoneCalendars() {
        let fetched = [
            GoogleCalendarEntry(id: "me", name: "Me", primary: true),
            GoogleCalendarEntry(id: "family", name: "Family", primary: false),
        ]
        let first = GoogleCalendarMerge.merge(existing: [], fetched: fetched)
        #expect(first.map(\.isOn) == [true, false])

        let familyID = first[1].id
        let again = GoogleCalendarMerge.merge(
            existing: [(first[0].id, "me", false), (familyID, "family", true), (UUID(), "gone", true)],
            fetched: fetched + [GoogleCalendarEntry(id: "new", name: "New", primary: false)]
        )
        #expect(again.map(\.entry.id) == ["me", "family", "new"])
        #expect(again.map(\.isOn) == [false, true, false])
        #expect(again[1].id == familyID)
    }

    @Test func choicesOfCalendarsNoLongerListedDoNotCountAsChosen() {
        let rows = GoogleCalendarMerge.merge(
            existing: [(UUID(), "old-account", true)],
            fetched: [GoogleCalendarEntry(id: "new-primary", name: "", primary: true)]
        )
        #expect(rows.map(\.isOn) == [true])
    }

    @Test func atMostTenStayOn() {
        let existing = (0..<12).map { (UUID(), "c\($0)", true) }
        let fetched = (0..<12).map { GoogleCalendarEntry(id: "c\($0)", name: "", primary: false) }
        let rows = GoogleCalendarMerge.merge(existing: existing.map { (id: $0.0, calendarID: $0.1, isOn: $0.2) }, fetched: fetched)
        #expect(rows.filter(\.isOn).count == 10)
    }

    @Test func passingFailuresKeepEventsAndOthersDropThem() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let old = GoogleEventsSnapshot(
            events: [
                UpcomingEvent(link: a, title: "A", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200), allDay: false),
                UpcomingEvent(link: b, title: "B", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200), allDay: false),
                UpcomingEvent(link: c, title: "C", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200), allDay: false),
            ],
            statuses: [], timezone: "UTC", fetchedAt: now
        )
        let answer = GoogleEventsAnswer(events: [], calendars: [
            .init(index: 0, ok: false, partial: false, error: .rateLimited),
            .init(index: 1, ok: false, partial: false, error: .forbidden),
            .init(index: 2, ok: false, partial: false, error: .notFound),
        ])
        let fresh = GoogleEventsSnapshot.make(from: answer, calendars: [a, b, c], timezone: "UTC", previous: old, now: now)
        #expect(fresh.events.map(\.title) == ["A"])
        #expect(fresh.status(for: b)?.problem == .forbidden)
    }
}

// MARK: - The model

@Suite @MainActor struct GoogleCalendarModelTests {
    private let endpoint = FakeGoogleEndpoint()
    private let stub = GoogleAPIStub()
    private let clock = TestClock(instant("2026-11-19T18:00:00Z"))
    private let zone = TimeZone(identifier: "America/Chicago")!

    private func model(_ context: ModelContext, store: InMemoryGoogleTokenStore) -> GoogleCalendarModel {
        let clock = clock
        let zone = zone
        return GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub),
            context: context,
            config: FakeGoogle.config,
            tokens: store,
            http: endpoint.http,
            timeZone: { zone },
            now: { clock.now }
        )
    }

    /// What the sign-in sheet would hand back: Google's redirect for the
    /// state in the authorization URL, or something else.
    private func redirect(_ build: @escaping (String) -> String) -> @MainActor (URL, String) async throws -> URL {
        { url, scheme in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?\(build(state))")!
        }
    }

    private func answerConnectedAccount() {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("me@example.test", "Me", true), ("family-id", "Family", false)]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil]
        ))
    }

    private func connected(_ context: ModelContext, store: InMemoryGoogleTokenStore) async -> GoogleCalendarModel {
        answerConnectedAccount()
        let model = model(context, store: store)
        await model.connect(signIn: redirect { "state=\($0)&code=\(FakeGoogle.code)&scope=x" })
        return model
    }

    private func titles(_ model: GoogleCalendarModel) -> [String] {
        model.upcoming(now: clock.now).map(\.title)
    }

    @Test func connectingStoresTheRefreshTokenChoosesThePrimaryAndShowsItsEvents() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == FakeGoogle.refresh)
        #expect(model.calendars.map(\.displayName) == ["Me", "Family"])
        #expect(model.chosen.map(\.calendarID) == ["me@example.test"])
        #expect(titles(model) == ["Coffee"])
        // One events request for the chosen calendars, with the access token.
        let events = stub.seen.filter { $0.operationID == GoogleAPIStub.postEvents }
        #expect(events.count == 1)
        #expect(events.first?.calendars == ["me@example.test"])
        #expect(events.first?.timezone == "America/Chicago")
        #expect(events.first?.token == FakeGoogle.access)
        // The PKCE verifier went to the token endpoint with the code.
        let exchange = try #require(endpoint.sent(grant: "authorization_code").first)
        #expect(GooglePKCE.isValidVerifier(exchange.form["code_verifier"] ?? ""))
        #expect(exchange.form["code"] == FakeGoogle.code)
    }

    @Test func nothingSecretIsInTheStores() async throws {
        let container = try SeasignSchema.inMemoryContainer()
        let context = ModelContext(container)
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        #expect(model.connection == .connected)
        let cached = try context.fetch(FetchDescriptor<CachedGoogleEvents>())
        #expect(cached.count == 1)
        let texts = cached.map { String(decoding: $0.payload, as: UTF8.self) }
            + (try context.fetch(FetchDescriptor<GoogleAccount>())).map(\.stateRaw)
            + (try context.fetch(FetchDescriptor<GoogleCalendarChoice>())).flatMap { [$0.calendarID, $0.name] }
        for secret in [FakeGoogle.access, FakeGoogle.refresh, FakeGoogle.code, "fake"] {
            #expect(!texts.contains { $0.contains(secret) })
        }
    }

    @Test func aRedirectForAnotherStateOrADeclineConnectsNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        answerConnectedAccount()
        let model = model(context, store: store)

        await model.connect(signIn: redirect { _ in "state=forged&code=\(FakeGoogle.code)" })
        #expect(model.connectProblem == .badAnswer)
        await model.connect(signIn: redirect { "state=\($0)&error=access_denied" })
        #expect(model.connectProblem == .denied)
        await model.connect(signIn: { _, _ in throw GoogleSignInCancelled() })
        #expect(model.connectProblem == nil)

        #expect(model.connection == .notConnected)
        #expect(store.stored == nil)
        #expect(endpoint.sent.isEmpty)
        #expect(stub.seen.isEmpty)
    }

    @Test func aPartialGrantIsHandedBackAndNotKept() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = model(context, store: store)
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(scope: GoogleOAuthConfig.scopes[0]))
        await model.connect(signIn: redirect { "state=\($0)&code=c" })
        #expect(model.connectProblem == .missingScope)
        #expect(model.connection == .notConnected)
        #expect(store.stored == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked == [FakeGoogle.refresh])
    }

    @Test func aRefusedExchangeShowsGooglesCode() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = model(context, store: InMemoryGoogleTokenStore())
        endpoint.answer("authorization_code", FakeGoogleEndpoint.error("invalid_client", status: 401))
        await model.connect(signIn: redirect { "state=\($0)&code=c" })
        #expect(model.connectProblem == .google("invalid_client"))
        #expect(model.connectProblem?.message.contains("invalid_client") == true)
    }

    @Test func aRejectedTokenIsRenewedOnceAndAskedAgain() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        stub.answer(
            GoogleAPIStub.postEvents,
            GoogleAPIStub.error(.unauthorized, "google_auth"),
            GoogleAPIStub.events([(0, "Lunch", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil])
        )
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let before = stub.count(GoogleAPIStub.postEvents)
        await model.refresh(force: true)
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        #expect(stub.seen.last?.token == FakeGoogle.access2)
        #expect(endpoint.sent(grant: "refresh_token").count == 1)
        #expect(titles(model) == ["Lunch"])
    }

    @Test func aSecondRejectionHoldsInsteadOfLooping() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.unauthorized, "google_auth"))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let before = stub.count(GoogleAPIStub.postEvents)
        await model.refresh(force: true)
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        #expect(model.statusProblem == .authFailed)
        #expect(model.connection == .connected)
        #expect(titles(model) == ["Coffee"])
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
    }

    @Test func anEndedSignInAsksToConnectAgainDropsEventsAndSurvivesRelaunch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        clock.advance(3600)  // the access token has expired
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        #expect(model.connection == .expired)
        #expect(model.upcoming(now: clock.now).isEmpty)
        #expect(store.stored == nil)
        #expect(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).isEmpty)
        // The choices stay for when the same account connects again.
        #expect(model.calendars.count == 2)

        let relaunched = self.model(context, store: store)
        #expect(relaunched.connection == .expired)
        #expect(!relaunched.canPoll)
        let sent = stub.seen.count
        await relaunched.refresh(force: true)
        #expect(stub.seen.count == sent)
    }

    @Test func aNetworkFailureWhileRenewingKeepsTheConnectionAndTheEvents() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        clock.advance(3600)
        endpoint.setOffline(true)
        await model.refresh()
        #expect(model.connection == .connected)
        #expect(model.statusProblem == .unavailable)
        #expect(titles(model) == ["Coffee"])
        #expect(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).count == 1)
    }

    @Test func ourRateLimitHoldsPollsUntilTheDelayHasPassed() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        await model.refresh(force: true)
        #expect(model.statusProblem == .rateLimited)
        #expect(titles(model) == ["Coffee"])
        let count = stub.count(GoogleAPIStub.postEvents)
        clock.advance(10)
        await model.refresh()
        await model.refresh(force: true)
        #expect(stub.count(GoogleAPIStub.postEvents) == count)
        clock.advance(25)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == count + 1)
        #expect(model.statusProblem == nil)
    }

    @Test func googleLimitingACalendarBacksOffAndKeepsItsEvents() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: ["rate_limited"]))
        clock.advance(5)
        await model.refresh()
        #expect(titles(model) == ["Coffee"])
        let count = stub.count(GoogleAPIStub.postEvents)
        clock.advance(30)
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == count)
        clock.advance(31)
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == count + 1)
    }

    @Test func pollsAreSpacedAndAnUnchangedAnswerWritesNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        let count = stub.count(GoogleAPIStub.postEvents)
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == count)  // under 4 s since the last
        let cachedAt = try context.fetch(FetchDescriptor<CachedGoogleEvents>()).first?.fetchedAt
        clock.advance(5)
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == count + 1)
        #expect(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).first?.fetchedAt == cachedAt)
    }

    @Test func aNewLaunchShowsCachedGoogleEventsBeforeAnyRequest() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = await connected(context, store: store)
        let sent = stub.seen.count
        let relaunched = model(context, store: store)
        #expect(relaunched.connection == .connected)
        #expect(titles(relaunched) == ["Coffee"])
        #expect(relaunched.canPoll)
        #expect(stub.seen.count == sent)
    }

    @Test func turningACalendarOffTakesItsEventsOffTodayAndTenIsTheLimit() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        let me = try #require(model.calendars.first)
        model.setOn(me, false)
        #expect(titles(model).isEmpty)
        #expect(!model.canPoll)

        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars((0..<12).map { ("c\($0)", "C\($0)", $0 == 0) }))
        await model.loadCalendars()
        for choice in model.calendars.prefix(10) { model.setOn(choice, true) }
        #expect(model.chosen.count == 10)
        model.setOn(model.calendars[11], true)
        #expect(model.limitReached)
        #expect(model.chosen.count == 10)
    }

    @Test func disconnectClearsEverythingAndRevokes() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        await model.disconnect()
        #expect(model.connection == .notConnected)
        #expect(store.stored == nil)
        #expect(model.calendars.isEmpty)
        #expect(model.snapshot == nil)
        #expect(model.upcoming(now: clock.now).isEmpty)
        #expect(try context.fetch(FetchDescriptor<GoogleCalendarChoice>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).isEmpty)
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(!model.canPoll)
    }

    @Test func anAnswerArrivingAfterDisconnectIsDropped() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        stub.hold()
        clock.advance(5)
        let inFlight = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        await model.disconnect()
        stub.release()
        await inFlight.value
        #expect(model.connection == .notConnected)
        #expect(model.snapshot == nil)
        #expect(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).isEmpty)
    }

    /// Waits (up to two seconds) until `condition` holds, for a request that
    /// another task has started.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func aCancelledPollShowsNothingAndDoesNotHoldTheNextAsk() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        clock.advance(5)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.hold()
        // The poll's task is cancelled mid-request: the app left the
        // foreground, or a sheet opened over Today.
        let poll = Task { await model.refresh() }
        try await waitUntil { stub.count(GoogleAPIStub.postEvents) == before + 1 }
        poll.cancel()
        await poll.value
        stub.release()
        #expect(model.statusProblem == nil)
        #expect(model.retryNotBefore == nil)
        #expect(model.connection == .connected)
        #expect(titles(model) == ["Coffee"])

        // Back on Today: the first poll asks at once, unforced.
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Lunch", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil]
        ))
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        #expect(titles(model) == ["Lunch"])
        #expect(model.statusProblem == nil)
    }

    @Test func aPollCancelledWhileTheTokenIsRenewedShowsNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        clock.advance(3600)  // the access token has expired
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        endpoint.holdRefreshes()
        let before = stub.count(GoogleAPIStub.postEvents)
        let poll = Task { await model.refresh() }
        try await waitUntil { endpoint.sent(grant: "refresh_token").count == 1 }
        poll.cancel()
        endpoint.release()
        await poll.value
        #expect(model.statusProblem == nil)
        #expect(model.retryNotBefore == nil)
        #expect(model.connection == .connected)

        // The renewal finished anyway, so the next ask reuses its token.
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) > before)
        #expect(stub.seen.last?.token == FakeGoogle.access2)
        #expect(endpoint.sent(grant: "refresh_token").count == 1)
        #expect(model.statusProblem == nil)
    }

    @Test func settingsClosingMidLoadShowsNothingAndDoesNotHoldTheNextAsk() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        clock.advance(5)
        let lists = stub.count(GoogleAPIStub.getCalendars)
        stub.hold()
        let load = Task { _ = await model.loadCalendars() }
        try await waitUntil { stub.count(GoogleAPIStub.getCalendars) == lists + 1 }
        load.cancel()
        await load.value
        stub.release()
        #expect(model.statusProblem == nil)
        #expect(model.retryNotBefore == nil)
        #expect(model.calendars.map(\.displayName) == ["Me", "Family"])

        // Today polls at once when Settings has closed.
        let events = stub.count(GoogleAPIStub.postEvents)
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == events + 1)
        // And Settings reads the list again when it opens again.
        await model.loadCalendars()
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists + 2)
        #expect(model.statusProblem == nil)
    }

    @Test func aRealFailureStillShowsAndHolds() async throws {
        // The cancellation rule does not hide failures of a task still running.
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        clock.advance(5)
        stub.setOffline(true)
        await model.refresh()
        #expect(model.statusProblem == .unavailable)
        #expect(model.retryNotBefore != nil)
    }

    @Test func ourRateLimitAlsoHoldsTheCalendarList() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        await model.refresh(force: true)
        #expect(model.statusProblem == .rateLimited)
        let lists = stub.count(GoogleAPIStub.getCalendars)
        clock.advance(10)
        await model.loadCalendars()
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists)
        #expect(model.calendars.map(\.displayName) == ["Me", "Family"])
        #expect(model.statusProblem == .rateLimited)
        clock.advance(25)
        await model.loadCalendars()
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists + 1)
        #expect(model.statusProblem == nil)
    }

    @Test func disconnectDuringTheCodeExchangeIsNotUndone() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        // The sign-in ends, so Settings shows Connect again and Disconnect.
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        #expect(model.connection == .expired)

        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2))
        endpoint.hold(grant: "authorization_code")
        let seen = stub.seen.count
        let connecting = Task { await model.connect(signIn: redirect { "state=\($0)&code=\(FakeGoogle.code)" }) }
        try await waitUntil { endpoint.sent(grant: "authorization_code").count == 2 }
        #expect(model.isConnecting)
        await model.disconnect()
        // The not-connected state shows at once, before the exchange returns.
        #expect(!model.isConnecting)
        endpoint.release()
        await connecting.value

        #expect(model.connection == .notConnected)
        #expect(model.connectProblem == nil)
        #expect(store.stored == nil)
        #expect(model.calendars.isEmpty)
        #expect(model.snapshot == nil)
        #expect(!model.canPoll)
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<GoogleCalendarChoice>()).isEmpty)
        #expect(stub.seen.count == seen)
        // The grant that arrived after Disconnect is handed back to Google.
        try await waitUntil { endpoint.revoked.contains(FakeGoogle.refresh) }

        // A later Connect works as normal.
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        await model.connect(signIn: redirect { "state=\($0)&code=\(FakeGoogle.code)" })
        #expect(model.connection == .connected)
        #expect(store.stored?.secret == FakeGoogle.refresh)
    }

    @Test func aRefusedCalendarListIsAStatusNotADisconnection() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.error(.forbidden, "google_forbidden"))
        await model.loadCalendars()
        #expect(model.connection == .connected)
        #expect(model.statusProblem == .listForbidden)
        #expect(model.statusProblem?.message.contains("Google Calendar API") == true)
        #expect(store.stored?.secret == FakeGoogle.refresh)
        #expect(titles(model) == ["Coffee"])
    }

    @Test func anotherAccountConnectedAfterTheSignInEndedStartsWithItsPrimaryOn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        #expect(model.connection == .expired)

        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("other@example.test", "Other", true), ("work-id", "Work", false)]))
        await model.connect(signIn: redirect { "state=\($0)&code=\(FakeGoogle.code)" })
        #expect(model.connection == .connected)
        #expect(model.calendars.map(\.calendarID) == ["other@example.test", "work-id"])
        #expect(model.chosen.map(\.calendarID) == ["other@example.test"])
    }

    @Test func aLeftoverTokenFromAnEarlierInstallIsRemoved() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh))
        _ = model(context, store: store)
        #expect(store.stored == nil)
    }

    @Test func aBuildWithoutAClientIDSaysSo() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = GoogleCalendarModel(context: context, config: nil, tokens: InMemoryGoogleTokenStore(), timeZone: { .gmt })
        await model.connect(signIn: { _, _ in Issue.record("no sheet without a client"); throw GoogleSignInCancelled() })
        #expect(model.connectProblem == .notConfigured)
    }
}

// MARK: - Keychain

@Suite(.serialized) struct GoogleKeychainTests {
    @Test func theRefreshTokenIsAThisDeviceOnlyKeychainItem() throws {
        let store = KeychainGoogleTokenStore(service: "seasign.google-refresh-token.tests")
        try store.delete()
        #expect(try store.read() == nil)
        try store.save(GoogleSecret(FakeGoogle.refresh))
        #expect(try store.read()?.secret == FakeGoogle.refresh)
        #expect(try store.storedAccessibility() == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        try store.save(GoogleSecret("fake-refresh-two"))
        #expect(try store.read()?.secret == "fake-refresh-two")
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()
    }

    @Test func theAppUsesItsOwnServiceApartFromTheLLMKey() {
        #expect(KeychainGoogleTokenStore().service != KeychainKeyStore().service)
    }
}
