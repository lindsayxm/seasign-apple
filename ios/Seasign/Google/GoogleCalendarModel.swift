import Foundation
import Observation
import SwiftData

/// The connected Google account's calendars and their upcoming events.
///
/// Held apart from the pasted calendar links (`EventsModel`), which keep
/// working exactly as before; Today merges the two lists (`TodayEvents`).
/// Sign-in is OAuth 2.0 for installed apps with PKCE: the refresh token goes
/// to the Keychain only, the access token stays in memory (`GoogleAccess`),
/// and the events are read through the API (`POST /v1/google/events`).
/// Nothing here logs, prints or stores a token, code or verifier.
@MainActor
@Observable
final class GoogleCalendarModel {
    /// The API takes at most this many calendars in one request.
    nonisolated static let maxCalendars = 10

    /// Why the last Connect did not connect. Shown in Settings.
    enum ConnectProblem: Error, Equatable {
        /// This build has no Google client ID.
        case notConfigured
        /// The sign-in sheet could not be opened or failed.
        case couldNotOpen
        /// The user declined on Google's page.
        case denied
        /// Google's answer was not for this sign-in, or had no code.
        case badAnswer
        /// Google returned an OAuth error code.
        case google(String)
        /// Google allowed less than both calendar permissions.
        case missingScope
        /// Google could not be reached.
        case unavailable
        /// The sign-in could not be written to the Keychain.
        case notSaved

        var message: String {
            switch self {
            case .notConfigured:
                "Google sign-in isn't set up in this build of Seasign."
            case .couldNotOpen:
                "The Google sign-in page couldn't open. Try again."
            case .denied:
                "You didn't allow Seasign to see your calendars, so nothing was connected."
            case .badAnswer:
                "Google's answer couldn't be checked, so nothing was connected. Try again."
            case .google(let code):
                "Google refused the sign-in (\(code)). Nothing was connected."
            case .missingScope:
                "Seasign needs to see both your calendar list and your events. Connect again and allow both."
            case .unavailable:
                "We couldn't reach Google. Check your connection and try again."
            case .notSaved:
                "The sign-in couldn't be saved on this phone. Try again."
            }
        }
    }

    /// Why the last read of the calendar list or the events failed as a
    /// whole. Events already on Today stay.
    enum StatusProblem: Equatable {
        case unavailable
        case rateLimited
        /// Google did not take a freshly renewed token.
        case authFailed
        /// Google refused to renew the token with this OAuth error code.
        case google(String)
        /// Google refused the calendar list (403 `google_forbidden`).
        case listForbidden
        /// The Keychain could not be read just now.
        case keychain

        var message: String {
            switch self {
            case .unavailable:
                "Google Calendar couldn't be read just now. Events already on Today stay."
            case .rateLimited:
                ServerRateLimit.message
            case .authFailed:
                "Google didn't accept the sign-in just now. Seasign will try again; if this stays, disconnect and connect again."
            case .google(let code):
                "Google refused to renew the sign-in (\(code)). Disconnect and connect again."
            case .keychain:
                "The Google sign-in can't be read from this phone right now. Unlock your phone and try again."
            case .listForbidden:
                "Google refused to list your calendars. Check that the Google Calendar API is turned on in the app's Google Cloud project; if it is, disconnect and connect again, allowing Seasign to see your calendars."
            }
        }
    }

    /// Events younger than this are not asked for again by an unforced
    /// refresh. Just under the poll interval, so each poll asks.
    static let minimumGap: TimeInterval = 4
    /// Google limited one calendar: no poll for this long.
    static let googleRateLimitHold: TimeInterval = 60

    private(set) var connection: GoogleConnection
    /// Every calendar on the account's list, in Google's order.
    private(set) var calendars: [GoogleCalendarChoice] = []
    private(set) var snapshot: GoogleEventsSnapshot?
    private(set) var isConnecting = false
    private(set) var connectProblem: ConnectProblem?
    private(set) var statusProblem: StatusProblem?
    /// Set when a calendar could not be turned on (ten are on already).
    private(set) var limitReached = false
    /// Polls and unforced refreshes are not sent before this.
    @ObservationIgnored private(set) var retryNotBefore: Date?

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let store: GoogleCalendarStore
    @ObservationIgnored private let tokens: any GoogleTokenStore
    @ObservationIgnored private let client: GoogleTokenClient?
    @ObservationIgnored private let access: GoogleAccess?
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRefreshing = false
    /// When the last answer arrived (memory only, so a poll that changes
    /// nothing redraws nothing).
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private var failures = 0
    /// Moves on connect, disconnect and when the sign-in ends, so an answer
    /// that arrives afterwards is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isFrozen = false

    /// `config` nil (a build without a client ID) leaves Connect showing
    /// why it cannot work.
    init(
        api: SeasignAPI = SeasignAPI(),
        context: ModelContext,
        config: GoogleOAuthConfig? = .main,
        tokens: any GoogleTokenStore = KeychainGoogleTokenStore(),
        http: @escaping GoogleHTTP = GoogleTokenClient.liveHTTP,
        timeZone: @escaping @MainActor () -> TimeZone,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        store = GoogleCalendarStore(context: context)
        self.tokens = tokens
        self.timeZone = timeZone
        self.now = now
        if let config {
            let client = GoogleTokenClient(config: config, http: http, now: now)
            self.client = client
            access = GoogleAccess(client: client, store: tokens, now: now)
        } else {
            client = nil
            access = nil
        }
        connection = store.connection
        calendars = store.choices()
        if connection == .connected {
            snapshot = store.cachedEvents()?.pruned(at: now())
        } else {
            if store.cachedEvents() != nil { store.cache(nil) }
            if connection == .notConnected {
                // A refresh token left from an earlier install (the Keychain
                // outlives the app) belongs to no connection here.
                try? tokens.delete()
            }
        }
    }

    var config: GoogleOAuthConfig? {
        client?.config
    }

    /// The calendars whose events are shown.
    var chosen: [GoogleCalendarChoice] {
        calendars.filter(\.isOn)
    }

    /// Whether Today should poll: connected with at least one calendar on.
    var canPoll: Bool {
        !isFrozen && connection == .connected && !chosen.isEmpty
    }

    /// The upcoming Google events for Today, in the events' time zone;
    /// empty while the cached ones belong to another zone or nothing is
    /// connected.
    func upcoming(now: Date) -> [UpcomingEvent] {
        guard connection == .connected, let snapshot,
              isFrozen || snapshot.timezone == timeZone().identifier
        else { return [] }
        let on = Set(chosen.map(\.id))
        return EventPicker.upcoming(snapshot.events.filter { on.contains($0.link) }, now: now)
    }

    /// The line under a calendar in Settings; nil when all is well or it
    /// has not been read yet.
    func message(for choice: GoogleCalendarChoice) -> (text: String, isProblem: Bool)? {
        guard choice.isOn, let status = snapshot?.status(for: choice.id) else { return nil }
        if let problem = status.problem { return (problem.message, true) }
        return status.partial ? ("Some events in this calendar couldn't be read.", false) : nil
    }

    // MARK: Connecting

    /// Signs in to Google. `signIn` opens Google's page (the URL) in a web
    /// authentication session that ends on the given custom scheme, and
    /// returns the redirect URL; it throws `GoogleSignInCancelled` when the
    /// user closes the sheet.
    func connect(signIn: @MainActor (URL, String) async throws -> URL) async {
        guard !isConnecting, !isFrozen else { return }
        guard let client, let access else {
            connectProblem = .notConfigured
            return
        }
        isConnecting = true
        connectProblem = nil
        defer { isConnecting = false }

        let pkce = GooglePKCE()
        let callback: URL
        do {
            callback = try await signIn(GoogleAuthorization.url(config: client.config, pkce: pkce), client.config.redirectScheme)
        } catch is GoogleSignInCancelled {
            return
        } catch {
            connectProblem = .couldNotOpen
            return
        }
        let code: GoogleSecret
        switch GoogleAuthorization.code(from: callback, config: client.config, state: pkce.state) {
        case .success(let value):
            code = value
        case .failure(.denied):
            connectProblem = .denied
            return
        case .failure(.google(let error)):
            connectProblem = .google(error)
            return
        case .failure:
            connectProblem = .badAnswer
            return
        }

        let fresh: GoogleTokens
        do {
            fresh = try await client.exchange(code: code, verifier: pkce.verifier)
        } catch GoogleTokenError.invalidGrant {
            connectProblem = .google("invalid_grant")
            return
        } catch GoogleTokenError.rejected(let error) {
            connectProblem = .google(error)
            return
        } catch GoogleTokenError.incomplete {
            connectProblem = .badAnswer
            return
        } catch {
            connectProblem = .unavailable
            return
        }
        guard fresh.grantsNeededScopes, let refreshToken = fresh.refresh else {
            // Nothing is kept; the partial grant is handed back to Google.
            let token = fresh.refresh ?? fresh.access
            Task { await client.revoke(token) }
            connectProblem = .missingScope
            return
        }
        do {
            try tokens.save(refreshToken)
        } catch {
            Task { await client.revoke(refreshToken) }
            connectProblem = .notSaved
            return
        }
        generation += 1
        access.set(fresh)
        retryNotBefore = nil
        failures = 0
        statusProblem = nil
        setConnection(.connected)
        await loadCalendars()
        await refresh(force: true)
    }

    /// Fetches the account's calendar list and folds it into the choices.
    func loadCalendars() async {
        guard !isFrozen, connection == .connected, access != nil else { return }
        let started = generation
        let list: [GoogleCalendarEntry]
        do {
            list = try await withToken { api, token in try await api.googleCalendars(token: token) }
        } catch {
            guard started == generation else { return }
            handle(error)
            return
        }
        guard started == generation else { return }
        statusProblem = nil
        let existing = calendars.map { (id: $0.id, calendarID: $0.calendarID, isOn: $0.isOn) }
        store.replaceChoices(with: GoogleCalendarMerge.merge(existing: existing, fetched: list))
        calendars = store.choices()
        if let snapshot { setSnapshot(snapshot.keeping(Set(chosen.map(\.id)))) }
    }

    /// Turns a calendar's events on or off on Today. At most ten are on.
    func setOn(_ choice: GoogleCalendarChoice, _ on: Bool) {
        guard choice.isOn != on else { return }
        if on, chosen.count >= Self.maxCalendars {
            limitReached = true
            return
        }
        limitReached = false
        choice.isOn = on
        store.save()
        calendars = store.choices()
        if let snapshot { setSnapshot(snapshot.keeping(Set(chosen.map(\.id)))) }
    }

    /// Disconnects: drops the token from memory and the Keychain, the
    /// calendars and the cached events, then asks Google to revoke the
    /// sign-in (best effort; nothing waits on it).
    func disconnect() async {
        guard !isFrozen else { return }
        generation += 1
        let token = try? tokens.read()
        try? tokens.delete()
        access?.forget()
        store.deleteChoices()
        calendars = []
        setSnapshot(nil)
        lastFetch = nil
        retryNotBefore = nil
        failures = 0
        statusProblem = nil
        connectProblem = nil
        limitReached = false
        setConnection(.notConnected)
        if let token, let client { await client.revoke(token) }
    }

    // MARK: Events

    /// Fetches the chosen calendars' events in one request, unless one is
    /// running, a hold is on, or (unforced) the last answer is under
    /// `minimumGap` old. If it fails as a whole, what is on screen stays.
    func refresh(force: Bool = false) async {
        guard !isFrozen, connection == .connected, access != nil else { return }
        let on = chosen
        guard !on.isEmpty else {
            setSnapshot(nil)
            return
        }
        let zone = timeZone().identifier
        if let snapshot, snapshot.timezone != zone { setSnapshot(nil) }
        let ids = on.map(\.id)
        if let snapshot {
            let pruned = snapshot.pruned(at: now())
            if pruned != snapshot { setSnapshot(pruned) }
            let covers = Set(pruned.statuses.map(\.calendar)) == Set(ids)
            if !force, covers, let lastFetch, now().timeIntervalSince(lastFetch) < Self.minimumGap { return }
        }
        guard !isRefreshing else { return }
        if let retryNotBefore, now() < retryNotBefore { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let started = generation
        let googleIDs = on.map(\.calendarID)
        let answer: GoogleEventsAnswer
        do {
            answer = try await withToken { api, token in
                try await api.googleEvents(token: token, calendars: googleIDs, timezone: zone)
            }
        } catch {
            guard started == generation else { return }
            handle(error)
            return
        }
        // Disconnected, reconnected, or the calendars or zone changed while
        // the request was out: whatever changed them asks again.
        guard started == generation, ids == chosen.map(\.id), zone == timeZone().identifier else { return }
        failures = 0
        statusProblem = nil
        retryNotBefore = nil
        lastFetch = now()
        let fresh = GoogleEventsSnapshot.make(from: answer, calendars: ids, timezone: zone, previous: snapshot, now: now())
        if fresh.statuses.contains(where: { $0.problem == .rateLimited }) {
            hold(Self.googleRateLimitHold)
        }
        setSnapshot(fresh)
    }

    /// Runs `call` with an access token; on a 401 `google_auth` renews the
    /// token and tries once more.
    private func withToken<T>(_ call: (SeasignAPI, GoogleSecret) async throws -> T) async throws -> T {
        guard let access else { throw SeasignAPI.GoogleFailure.unavailable }
        let token = try await access.token()
        do {
            return try await call(api, token)
        } catch SeasignAPI.GoogleFailure.googleAuth {
            access.invalidate()
            let renewed = try await access.token()
            do {
                return try await call(api, renewed)
            } catch SeasignAPI.GoogleFailure.googleAuth {
                throw RepeatedAuthFailure()
            }
        }
    }

    private struct RepeatedAuthFailure: Error {}

    private func handle(_ error: any Error) {
        switch error {
        case let failure as GoogleAccess.Failure:
            switch failure {
            case .signInEnded:
                endSignIn(.expired)
            case .keychainUnreadable:
                statusProblem = .keychain
                hold(30)
            case .unavailable:
                statusProblem = .unavailable
                backOff()
            case .rejected(let code):
                statusProblem = .google(code)
                hold(Self.googleRateLimitHold)
            }
        case is RepeatedAuthFailure:
            statusProblem = .authFailed
            hold(Self.googleRateLimitHold)
        case let failure as SeasignAPI.GoogleFailure:
            switch failure {
            case .forbidden:
                // Both scopes were checked at sign-in, so this is more
                // likely the Calendar API being off in the Cloud project.
                // The connection and the events stay.
                statusProblem = .listForbidden
                hold(Self.googleRateLimitHold)
            case .rateLimited(let seconds):
                statusProblem = .rateLimited
                hold(TimeInterval(seconds))
            case .googleAuth, .invalidRequest, .unavailable:
                statusProblem = .unavailable
                backOff()
            }
        default:
            statusProblem = .unavailable
            backOff()
        }
    }

    /// The sign-in no longer works: Settings asks to connect again and
    /// Today drops the Google events. The calendar choices stay, for when
    /// the same account connects again.
    private func endSignIn(_ state: GoogleConnection) {
        generation += 1
        try? tokens.delete()
        access?.forget()
        setSnapshot(nil)
        retryNotBefore = nil
        failures = 0
        statusProblem = nil
        setConnection(state)
    }

    private func backOff() {
        failures += 1
        hold(GooglePoll.backoff(failures: failures))
    }

    private func hold(_ seconds: TimeInterval) {
        retryNotBefore = now().addingTimeInterval(seconds)
    }

    private func setConnection(_ state: GoogleConnection) {
        connection = state
        store.setConnection(state)
    }

    private func setSnapshot(_ value: GoogleEventsSnapshot?) {
        // A poll that changes nothing but the time neither writes the
        // cache nor redraws Today.
        if let value, value.sameContent(as: snapshot) { return }
        guard value != snapshot else { return }
        snapshot = value
        store.cache(value)
    }
}

/// Thrown by the sign-in closure when the user closes the sheet; not a problem.
struct GoogleSignInCancelled: Error {}

/// When Today polls Google, and how it backs off.
enum GooglePoll {
    /// How often Today asks while it is on screen and the app is active.
    static let interval: Duration = .seconds(5)

    /// Whether Today should poll: the app active, Today itself on screen
    /// (no sheet over it), and Google connected with a calendar on.
    static func isOn(appActive: Bool, todayOnScreen: Bool, canPoll: Bool) -> Bool {
        appActive && todayOnScreen && canPoll
    }

    /// After `failures` failed requests in a row: 5, 10, 20, 40, 80, then
    /// 120 seconds.
    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let doubled = 5.0 * pow(2.0, Double(min(failures - 1, 10)))
        return min(120, doubled)
    }
}

/// The events Today shows: pasted-link and Google events in one list.
enum TodayEvents {
    /// The next `limit` events of both, soonest first (`EventPicker`'s order).
    static func next(links: [UpcomingEvent], google: [UpcomingEvent], now: Date, limit: Int = 3) -> [UpcomingEvent] {
        EventPicker.next(links + google, now: now, limit: limit)
    }

    static func labels(
        links: [UpcomingEvent], google: [UpcomingEvent], now: Date,
        timeZone: TimeZone, clock: ClockStyle, limit: Int = 3
    ) -> [EventLabel] {
        next(links: links, google: google, now: now, limit: limit).map {
            EventLabel(event: $0, now: now, timeZone: timeZone, clock: clock)
        }
    }
}

#if DEBUG
extension GoogleCalendarModel {
    /// Debug-only (`-debugGoogle YES`): a connected account with three
    /// calendars (two on, one with a problem) and two events, held in a store
    /// in memory with no token at all. Nothing is fetched, nothing is sent to
    /// Google, and the user's store and the real Keychain are not touched.
    static func sample(now: Date = Date(), timeZone: TimeZone = .current) throws -> GoogleCalendarModel {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = GoogleCalendarStore(context: context)
        store.setConnection(.connected)
        let personal = UUID()
        let family = UUID()
        let holidays = UUID()
        store.replaceChoices(with: [
            .init(id: personal, entry: GoogleCalendarEntry(id: "sample-primary", name: "Personal", primary: true), isOn: true),
            .init(id: family, entry: GoogleCalendarEntry(id: "sample-family", name: "Family", primary: false), isOn: true),
            .init(id: holidays, entry: GoogleCalendarEntry(id: "sample-holidays", name: "Holidays", primary: false), isOn: false),
        ])
        let soon = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900 + 1800)
        store.cache(GoogleEventsSnapshot(
            events: [
                UpcomingEvent(link: personal, title: "Coffee with Sam", start: soon, end: soon.addingTimeInterval(1800), allDay: false),
                UpcomingEvent(link: family, title: "Swim practice", start: soon.addingTimeInterval(7200), end: soon.addingTimeInterval(10800), allDay: false),
            ],
            statuses: [
                .init(calendar: personal, problem: nil, partial: false),
                .init(calendar: family, problem: .rateLimited, partial: false),
            ],
            timezone: timeZone.identifier,
            fetchedAt: now
        ))
        let model = GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: "https://sample.invalid")!),
            context: context,
            config: nil,
            tokens: InMemoryGoogleTokenStore(),
            timeZone: { timeZone },
            now: { now }
        )
        model.isFrozen = true
        return model
    }
}
#endif
