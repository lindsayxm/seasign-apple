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
        /// Connect again from a working connection did not end with write
        /// access (declined, or the permission unticked). The connection
        /// reads as before.
        case addingNotAllowed
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
            case .addingNotAllowed:
                "Google didn't allow Seasign to add events, so it still only reads your calendars. Connect again when you want to add events."
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
    /// Disconnect waits at most this long for stopping the push channels (a
    /// watch already out, then the unwatch) before it revokes the sign-in.
    nonisolated static let unwatchWait: Duration = .seconds(10)

    private(set) var connection: GoogleConnection
    /// Every calendar on the account's list, in Google's order.
    private(set) var calendars: [GoogleCalendarChoice] = []
    private(set) var snapshot: GoogleEventsSnapshot?
    private(set) var isConnecting = false
    private(set) var connectProblem: ConnectProblem?
    private(set) var statusProblem: StatusProblem?
    /// Set when a calendar could not be turned on (ten are on already).
    private(set) var limitReached = false
    /// The scopes Google granted this connection, as stored; nil when
    /// unknown (a connection made before write access was asked for).
    private(set) var grantedScopes: Set<String>?
    /// Google's id of the calendar the user chose for new events; nil
    /// means the primary calendar.
    private(set) var newEventsCalendarID: String?
    /// Polls and unforced refreshes are not sent before this.
    @ObservationIgnored private(set) var retryNotBefore: Date?
    /// The hold is our own 429's delay (not a back-off or Google's limit).
    @ObservationIgnored private var holdIsServerLimit = false
    /// Settings asked for the calendar list during a hold, so it was not
    /// read; it is read when the hold ends while Settings stays open.
    private(set) var listHeld = false
    /// When the calendar list was last read (memory only).
    @ObservationIgnored private var listLoadedAt: Date?
    /// The push channels for the chosen calendars (task 158).
    @ObservationIgnored let watch: GoogleWatchKeeper

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let store: GoogleCalendarStore
    @ObservationIgnored private let tokens: any GoogleTokenStore
    @ObservationIgnored private let client: GoogleTokenClient?
    @ObservationIgnored private let access: GoogleAccess?
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private let pushWindow: Duration
    @ObservationIgnored private let pushDeadline: Duration
    @ObservationIgnored private let unwatchWait: Duration
    @ObservationIgnored private var isRefreshing = false
    /// Waiting for the running refresh to end (a push behind a poll).
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    /// A push came in that no fetch has started on yet.
    @ObservationIgnored private var pushPending = false
    /// The fetch every push arriving now shares.
    @ObservationIgnored private var pushFetch: Task<GooglePushOutcome, Never>?
    /// Moves with each Connect, so only the latest one clears `isConnecting`.
    @ObservationIgnored private var connectAttempt = 0
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
        now: @escaping @Sendable () -> Date = { Date() },
        environment: APNsEnvironment = .current,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        pushWindow: Duration = GooglePushHandling.coalescingWindow,
        pushDeadline: Duration = GooglePushHandling.deadline,
        unwatchWait: Duration = GoogleCalendarModel.unwatchWait
    ) {
        self.api = api
        store = GoogleCalendarStore(context: context)
        self.tokens = tokens
        self.timeZone = timeZone
        self.now = now
        self.sleep = sleep
        self.pushWindow = pushWindow
        self.pushDeadline = pushDeadline
        self.unwatchWait = unwatchWait
        watch = GoogleWatchKeeper(api: api, context: context, environment: environment, now: now)
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
        grantedScopes = store.grantedScopes
        newEventsCalendarID = store.newEventsCalendarID
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
        watch.host = self
        access?.scopesRenewed = { [weak self] scopes in self?.scopesRenewed(scopes) }
    }

    var config: GoogleOAuthConfig? {
        client?.config
    }

    /// The calendars whose events are shown.
    var chosen: [GoogleCalendarChoice] {
        calendars.filter(\.isOn)
    }

    // MARK: Adding events (task 169; used by the add path, task 171)

    /// Whether events can be added: connected, and Google granted the write
    /// scope (`GoogleOAuthConfig.allowsAddingEvents`). False for a
    /// connection made before write access was asked for, which otherwise
    /// works as before; Settings then offers "Connect again to add events".
    var canAddEvents: Bool {
        connection == .connected && GoogleOAuthConfig.allowsAddingEvents(grantedScopes)
    }

    /// The calendars new events may go to, in Google's order (owner only;
    /// see `GoogleAccessRole.takesNewEvents`).
    var newEventsCalendars: [GoogleCalendarChoice] {
        GoogleNewEventsCalendar.offered(calendars)
    }

    /// Where a new event goes: the chosen calendar while it is offered,
    /// else the primary one; nil when neither is offered (no list read yet,
    /// or roles not known).
    var newEventsCalendar: GoogleCalendarChoice? {
        GoogleNewEventsCalendar.resolve(calendars, storedID: newEventsCalendarID)
    }

    /// Settings' "New events go to". Choosing the primary calendar stores
    /// nothing, so it stays the default whatever its id.
    func setNewEventsCalendar(_ choice: GoogleCalendarChoice) {
        guard connection == .connected, choice.takesNewEvents else { return }
        let id: String? = choice.isPrimary ? nil : choice.calendarID
        newEventsCalendarID = id
        store.setNewEventsCalendarID(id)
    }

    /// A token renewal named the scopes; they replace the stored ones if
    /// they differ. (An answer without them changes nothing.)
    private func scopesRenewed(_ scopes: Set<String>) {
        guard connection == .connected, scopes != grantedScopes else { return }
        grantedScopes = scopes
        store.setGrantedScopes(scopes)
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
        connectAttempt += 1
        let attempt = connectAttempt
        isConnecting = true
        connectProblem = nil
        // A Disconnect (or a newer Connect) has already cleared it otherwise.
        defer { if attempt == connectAttempt { isConnecting = false } }
        // A Disconnect tapped while this runs (the expired state shows one)
        // moves the generation; this sign-in then keeps nothing.
        let started = generation

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
        guard started == generation else { return }
        let code: GoogleSecret
        switch GoogleAuthorization.code(from: callback, config: client.config, state: pkce.state) {
        case .success(let value):
            code = value
        case .failure(.denied):
            connectProblem = connection == .connected ? .addingNotAllowed : .denied
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
        } catch {
            // Disconnected meanwhile: there is nothing to report.
            guard started == generation else { return }
            switch error {
            case GoogleTokenError.invalidGrant:
                connectProblem = .google("invalid_grant")
            case GoogleTokenError.rejected(let reason):
                connectProblem = .google(reason)
            case GoogleTokenError.incomplete:
                connectProblem = .badAnswer
            default:
                connectProblem = .unavailable
            }
            return
        }
        guard started == generation else {
            // Disconnected during the exchange: the new grant is handed back
            // to Google and nothing is kept.
            let token = fresh.refresh ?? fresh.access
            Task { await client.revoke(token) }
            return
        }
        // Connect again from a working connection (to add write access): a
        // failure leaves that connection exactly as it was. Nothing is
        // revoked then, since Google's docs do not say whether revoking the
        // new token would also end the grant the connection runs on.
        let wasConnected = connection == .connected
        guard fresh.grantsNeededScopes, let refreshToken = fresh.refresh else {
            // Nothing is kept; the partial grant is handed back to Google.
            if !wasConnected {
                let token = fresh.refresh ?? fresh.access
                Task { await client.revoke(token) }
            }
            connectProblem = .missingScope
            return
        }
        do {
            try tokens.save(refreshToken)
        } catch {
            if !wasConnected { Task { await client.revoke(refreshToken) } }
            connectProblem = .notSaved
            return
        }
        generation += 1
        access.set(fresh)
        retryNotBefore = nil
        failures = 0
        statusProblem = nil
        setConnection(.connected)
        // A new grant: exactly what this answer says (nil when it says
        // nothing, which reads as no write access).
        grantedScopes = fresh.scopes
        store.setGrantedScopes(fresh.scopes)
        if wasConnected, !fresh.grantsWriteScope { connectProblem = .addingNotAllowed }
        await loadCalendars()
        await refresh(force: true)
    }

    /// Fetches the account's calendar list and folds it into the choices,
    /// unless a hold is on (our 429's delay, a back-off); the list kept from
    /// last time stays. With no list at all (the first load failed), only
    /// our 429 holds it back. Returns how long to wait before asking again
    /// when the list is still missing or was held back; nil otherwise.
    @discardableResult
    func loadCalendars() async -> TimeInterval? {
        guard !isFrozen, connection == .connected, access != nil else {
            listHeld = false
            return nil
        }
        if let wait = listHold() {
            listHeld = true
            return wait
        }
        listHeld = false
        let started = generation
        let list: [GoogleCalendarEntry]
        do {
            list = try await withToken { api, token in try await api.googleCalendars(token: token) }
        } catch {
            // Cancelled (Settings closed mid-load): not a failure, so no
            // status and no hold (see `refresh`).
            guard started == generation, !Task.isCancelled else { return nil }
            handle(error)
            guard calendars.isEmpty, let retryNotBefore else { return nil }
            listHeld = true
            return max(1, retryNotBefore.timeIntervalSince(now()))
        }
        guard started == generation else { return nil }
        listLoadedAt = now()
        statusProblem = nil
        let existing = calendars.map { (id: $0.id, calendarID: $0.calendarID, isOn: $0.isOn) }
        store.replaceChoices(with: GoogleCalendarMerge.merge(existing: existing, fetched: list))
        calendars = store.choices()
        if let snapshot { setSnapshot(snapshot.keeping(Set(chosen.map(\.id)))) }
        watch.sync(.calendars)
        return nil
    }

    /// While Settings is open: reads the calendar list, and again each time
    /// a hold that kept it back ends (or a first load that failed can be
    /// tried again). Ends when Settings closes (the task is cancelled).
    func loadCalendarsWhileShown() async {
        defer { listHeld = false }
        // Connect has just read it (Settings restarts this when a Connect ends).
        if !calendars.isEmpty, let listLoadedAt, now().timeIntervalSince(listLoadedAt) < Self.listJustRead { return }
        while !Task.isCancelled {
            guard let wait = await loadCalendars() else { return }
            await sleep(wait)
        }
    }

    /// What Settings restarts `loadCalendarsWhileShown` on: true once
    /// connected with no Connect running, so a Connect made in Settings whose
    /// own list load failed is followed by the retries.
    var listLoadKey: Bool {
        connection == .connected && !isConnecting
    }

    /// A list read this recently is not read again when Settings (re)starts its load.
    static let listJustRead: TimeInterval = 5

    /// How long the hold has left if it keeps the list from being read.
    private func listHold() -> TimeInterval? {
        guard let retryNotBefore, now() < retryNotBefore else { return nil }
        // A missing list ignores back-offs: Settings would otherwise say
        // it is loading while nothing is.
        guard holdIsServerLimit || !calendars.isEmpty else { return nil }
        return retryNotBefore.timeIntervalSince(now())
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
        watch.sync(.calendars)
    }

    /// Disconnects: drops the token from memory and the Keychain, the
    /// calendars and the cached events, and shows the not-connected state at
    /// once (even while a Connect is still exchanging its code). Then, best
    /// effort and in this order: stops the push channels (after any watch
    /// already out), and asks Google to revoke the sign-in; revoking first
    /// would leave the API no token to stop the channels with. The revoke
    /// waits for the channels at most `unwatchWait`. When the
    /// device token has not arrived yet, the watch keeper alone keeps one
    /// access token in memory for the unwatch it owes (`GoogleWatchKeeper.stop`).
    func disconnect() async {
        guard !isFrozen else { return }
        generation += 1
        connectAttempt += 1
        isConnecting = false
        let token = try? tokens.read()
        let valid = access?.validToken
        let last = access?.lastToken
        let mayNeedUnwatch = watch.mayNeedUnwatch
        let channelsLeft = watch.channelsMayBeLeft
        watch.forget()
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
        listHeld = false
        setConnection(.notConnected)
        grantedScopes = nil
        newEventsCalendarID = nil
        if mayNeedUnwatch {
            let disconnected = generation
            let stopping = Task { [weak self, watch, client] in
                var unwatchToken = valid
                if unwatchToken == nil, let token, let client {
                    // One fresh token for the unwatch alone; it is not kept.
                    unwatchToken = try? await client.refresh(token).access
                }
                // A Connect finished meanwhile: its keeper state is not
                // wiped, and its own watch replaces this device's channels.
                guard let self, self.generation == disconnected else { return }
                // Without a device token yet, the keeper keeps this token for an
                // unwatch sent when the device token arrives (after the revoke
                // below: the API forgets the channels whatever Google says).
                await watch.stop(using: unwatchToken ?? last, channelsLeft: channelsLeft)
            }
            // The revoke waits for this at most `unwatchWait`, so it is never
            // left undone for long (the app could be closed meanwhile). The
            // unwatch is not cancelled; if it is still out, it ends by itself,
            // and the API forgets the channels whatever Google says of the token.
            await PushDeadline.race(stopping, deadline: unwatchWait, fallback: ())
        }
        if let token, let client { await client.revoke(token) }
    }

    // MARK: Events

    /// Fetches the chosen calendars' events in one request, unless one is
    /// running, a hold is on, or (unforced) the last answer is under
    /// `minimumGap` old. If it fails as a whole, what is on screen stays.
    func refresh(force: Bool = false) async {
        await fetch(force: force)
    }

    /// What one `fetch` did.
    enum FetchResult: Equatable {
        /// Nothing was asked (a hold, too soon, one running, not connected).
        case skipped
        case unchanged
        case changed
        case failed
    }

    /// `refresh`, saying what came of it.
    @discardableResult
    private func fetch(force: Bool) async -> FetchResult {
        guard !isFrozen, connection == .connected, access != nil else { return .skipped }
        let on = chosen
        guard !on.isEmpty else {
            setSnapshot(nil)
            return .skipped
        }
        let zone = timeZone().identifier
        if let snapshot, snapshot.timezone != zone { setSnapshot(nil) }
        let ids = on.map(\.id)
        if let snapshot {
            let pruned = snapshot.pruned(at: now())
            if pruned != snapshot { setSnapshot(pruned) }
            let covers = Set(pruned.statuses.map(\.calendar)) == Set(ids)
            if !force, covers, let lastFetch, now().timeIntervalSince(lastFetch) < Self.minimumGap { return .skipped }
        }
        guard !isRefreshing else { return .skipped }
        if let retryNotBefore, now() < retryNotBefore { return .skipped }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters = []
            for waiter in waiters { waiter.resume() }
        }

        let started = generation
        let holdAtStart = retryNotBefore
        let googleIDs = on.map(\.calendarID)
        let answer: GoogleEventsAnswer
        do {
            answer = try await withToken { api, token in
                try await api.googleEvents(token: token, calendars: googleIDs, timezone: zone)
            }
        } catch {
            // Cancelled (the app left the foreground, a sheet opened over
            // Today, Settings closed): not a failure. No status and no hold,
            // so the ask on return goes out at once.
            guard started == generation, !Task.isCancelled else { return .skipped }
            handle(error)
            return .failed
        }
        // Disconnected, reconnected, or the calendars or zone changed while
        // the request was out: whatever changed them asks again.
        guard started == generation, ids == chosen.map(\.id), zone == timeZone().identifier else { return .skipped }
        answered(holdAtStart: holdAtStart)
        lastFetch = now()
        let fresh = GoogleEventsSnapshot.make(from: answer, calendars: ids, timezone: zone, previous: snapshot, now: now())
        if fresh.statuses.contains(where: { $0.problem == .rateLimited }) {
            holdAtLeast(Self.googleRateLimitHold)
        }
        return setSnapshot(fresh) ? .changed : .unchanged
    }

    /// An events request sent while `retryNotBefore` was `holdAtStart` was
    /// answered: as after a successful poll, the failures are over, unless
    /// another request (the day screen's and Today's can overlap) failed
    /// while this one was out and set a hold that has not passed. That hold
    /// (our 429's `Retry-After`, a back-off) stands, with its status and
    /// failure count: this answer is no newer news about the limit.
    private func answered(holdAtStart: Date?) {
        if let retryNotBefore, retryNotBefore != holdAtStart, now() < retryNotBefore { return }
        failures = 0
        statusProblem = nil
        retryNotBefore = nil
    }

    /// Google limited a calendar: hold for `seconds`, but never shorten a
    /// longer hold that is already on (`answered` may have kept one).
    private func holdAtLeast(_ seconds: TimeInterval) {
        if let retryNotBefore, retryNotBefore >= now().addingTimeInterval(seconds) { return }
        hold(seconds)
    }

    // MARK: The day screen (task 170)

    /// What `dayEvents` came to.
    enum DayRead: Equatable {
        /// No Google events to show: not connected, or no calendar on.
        case off
        /// Nothing was asked: a hold is on, or the answer arrived after a
        /// disconnect, a reconnect or a change of calendars, or was cancelled.
        case skipped
        /// The chosen calendars' answer; `calendars` are the choices' ids in
        /// the order their Google ids were sent.
        case answer(GoogleEventsAnswer, calendars: [UUID])
        /// The API refused the request (400). For a day request that is
        /// most likely the day being out of range: a request for today sent
        /// just before midnight that arrived after it. The caller works out
        /// the date again; nothing is held back and no status is set.
        case refused
        /// The request failed as a whole; handled as Today's poll handles a
        /// failure (token renewal, holds, back-off, the sign-in ending).
        case failed
    }

    /// Whether this is the DEBUG sample (`-debugGoogle YES`), which asks
    /// nothing. Always false in a Release build.
    var isSample: Bool {
        isFrozen
    }

    /// The day screen's read: every event of the chosen calendars that
    /// overlaps `day` (`YYYY-MM-DD` in `timezone`), ended ones included.
    /// Goes through the same token renewal and failure handling as Today's
    /// poll (a failure sets the same holds, back-off and status), and is
    /// held back by the same holds; an answer clears them as a successful
    /// poll does, except a hold set while it was out (`answered`). It never touches Today's snapshot, its cache, `lastFetch`
    /// or `isRefreshing`.
    func dayEvents(day: String, timezone: String) async -> DayRead {
        guard !isFrozen, connection == .connected, access != nil else { return .off }
        let on = chosen
        guard !on.isEmpty else { return .off }
        if let retryNotBefore, now() < retryNotBefore { return .skipped }
        let started = generation
        let holdAtStart = retryNotBefore
        let ids = on.map(\.id)
        let googleIDs = on.map(\.calendarID)
        let answer: GoogleEventsAnswer
        do {
            answer = try await withToken { api, token in
                try await api.googleEvents(token: token, calendars: googleIDs, timezone: timezone, day: day)
            }
        } catch {
            // Cancelled (the day screen closed, the app left the
            // foreground): not a failure, as in `fetch`.
            guard started == generation, !Task.isCancelled else { return .skipped }
            // Not `handle`: a day refused at midnight must not put Today's
            // poll into back-off or show a problem in Settings.
            if case SeasignAPI.GoogleFailure.invalidRequest? = error as? SeasignAPI.GoogleFailure { return .refused }
            handle(error)
            return .failed
        }
        guard started == generation, ids == chosen.map(\.id) else { return .skipped }
        // Google answered: as after a successful poll, the failures are over
        // (unless a hold was set while this request was out).
        answered(holdAtStart: holdAtStart)
        if answer.calendars.contains(where: { $0.error == .rateLimited }) {
            holdAtLeast(Self.googleRateLimitHold)
        }
        return .answer(answer, calendars: ids)
    }

    // MARK: Push

    /// A background push from the Worker (`type` from its payload). For
    /// `calendar-changed` while connected: one forced events fetch, shared by
    /// every push that arrives before it starts (within `pushWindow` of the
    /// first); a push arriving while it is out gets one more fetch after it,
    /// since that fetch may have missed the change. A poll already running
    /// is waited for, not doubled. Answers by `pushDeadline` whatever happens.
    func handlePush(type: String?) async -> GooglePushOutcome {
        guard type == GooglePushHandling.calendarChanged, canPoll else { return .noData }
        pushPending = true
        let task: Task<GooglePushOutcome, Never>
        if let pushFetch {
            task = pushFetch
        } else {
            task = Task { [weak self] in await self?.drainPushes() ?? .noData }
            pushFetch = task
        }
        return await PushDeadline.race(task, deadline: pushDeadline)
    }

    private func drainPushes() async -> GooglePushOutcome {
        var outcome = GooglePushOutcome.noData
        while pushPending {
            try? await Task.sleep(for: pushWindow)
            pushPending = false
            while isRefreshing {
                await withCheckedContinuation { refreshWaiters.append($0) }
            }
            switch await fetch(force: true) {
            case .changed:
                outcome = .newData
            case .failed:
                if outcome != .newData { outcome = .failed }
            case .unchanged, .skipped:
                if outcome == .failed { outcome = .noData }
            }
        }
        pushFetch = nil
        return outcome
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
                hold(TimeInterval(seconds), serverLimit: true)
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
        // The channels are stopped with the last token had (it is probably
        // no longer good at Google, but the API forgets the channels anyway).
        // With none in memory (the sign-in was found ended at launch), no
        // unwatch can be sent; the channels end by themselves.
        let last = access?.lastToken
        let channelsLeft = watch.channelsMayBeLeft
        watch.forget()
        if let last {
            Task { [watch] in await watch.stop(using: last, channelsLeft: channelsLeft) }
        }
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

    private func hold(_ seconds: TimeInterval, serverLimit: Bool = false) {
        retryNotBefore = now().addingTimeInterval(seconds)
        holdIsServerLimit = serverLimit
    }

    private func setConnection(_ state: GoogleConnection) {
        connection = state
        store.setConnection(state)
    }

    /// Returns whether what Today shows changed.
    @discardableResult
    private func setSnapshot(_ value: GoogleEventsSnapshot?) -> Bool {
        // A poll that changes nothing but the time neither writes the
        // cache nor redraws Today.
        if let value, value.sameContent(as: snapshot) { return false }
        guard value != snapshot else { return false }
        snapshot = value
        store.cache(value)
        return true
    }
}

extension GoogleCalendarModel: GoogleWatchHost {
    var watchCalendars: [String]? {
        guard !isFrozen, connection == .connected, access != nil else { return nil }
        return chosen.map(\.calendarID)
    }

    func watchToken() async throws -> GoogleSecret {
        guard let access else { throw GoogleAccess.Failure.signInEnded }
        return try await access.token()
    }

    func watchTokenRejected() {
        access?.invalidate()
    }
}

extension GoogleCalendarModel: RemotePushReceiver {
    func launched() {
        watch.sync(.launch)
    }

    func registered(_ token: APNsDeviceToken) {
        watch.registered(token)
    }

    func registrationFailed() {
        watch.registrationFailed()
    }

    func received(type: String?) async -> GooglePushOutcome {
        await handlePush(type: type)
    }
}

extension GoogleCalendarModel {
    /// The app came to the front: the channels are replaced if they end
    /// within `GoogleWatchKeeper.renewalWindow` (or were never made).
    func appOpened() {
        watch.sync(.opened)
    }

    /// Each turn of Today's Google poll: whether the channels are still live
    /// is looked at again, so channels that end while the app stays open
    /// return `pollInterval` to 5 seconds at once. Sends nothing.
    func pollTurn() {
        watch.checkLive()
    }

    /// How often Today polls now: slowly while push channels cover every
    /// calendar that is on.
    var pollInterval: Duration {
        GooglePoll.interval(channelLive: watch.isLive)
    }

    /// The line under a calendar in Settings when it could not be watched.
    func watchMessage(for choice: GoogleCalendarChoice) -> String? {
        guard choice.isOn, connection == .connected, let code = watch.calendarProblems[choice.calendarID] else { return nil }
        return code == "webhook_refused"
            ? "Instant updates aren't available right now (a Seasign server setting). Today checks this calendar every few seconds instead."
            : "Instant updates for this calendar couldn't be set up. Today checks it every few seconds instead."
    }
}

/// Answers by a deadline whatever the task does; the task itself goes on.
enum PushDeadline {
    /// A push's outcome by `deadline`, `.failed` if the fetch has not ended.
    static func race(_ task: Task<GooglePushOutcome, Never>, deadline: Duration) async -> GooglePushOutcome {
        await race(task, deadline: deadline, fallback: .failed)
    }

    /// `task`'s value, or `fallback` once `deadline` passes (in real time).
    static func race<T: Sendable>(_ task: Task<T, Never>, deadline: Duration, fallback: T) async -> T {
        let once = Once<T>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            let timer = Task {
                try? await Task.sleep(for: deadline)
                once.resume(fallback)
            }
            Task {
                let value = await task.value
                timer.cancel()
                once.resume(value)
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func set(_ value: CheckedContinuation<T, Never>) {
            lock.withLock { continuation = value }
        }

        func resume(_ value: T) {
            let continuation = lock.withLock { () -> CheckedContinuation<T, Never>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }
    }
}

/// Thrown by the sign-in closure when the user closes the sheet; not a problem.
struct GoogleSignInCancelled: Error {}

/// When Today polls Google, and how it backs off.
enum GooglePoll {
    /// How often Today asks while it is on screen and the app is active,
    /// with no push channel to rely on.
    static let interval: Duration = .seconds(5)
    /// How often it asks while push channels cover every calendar that is
    /// on: the fallback for a push iOS delays or drops. The one place it is set.
    static let intervalWithPush: Duration = .seconds(60)

    static func interval(channelLive: Bool) -> Duration {
        channelLive ? intervalWithPush : interval
    }

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
    /// Personal and Family are the user's own (offered for new events),
    /// Holidays is read-only. With write access by default; `readOnly`
    /// (`-debugGoogleReadOnly YES`) shows a connection without it, as one
    /// made before write access was asked for.
    static func sample(now: Date = Date(), timeZone: TimeZone = .current, readOnly: Bool = false) throws -> GoogleCalendarModel {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = GoogleCalendarStore(context: context)
        store.setConnection(.connected)
        if !readOnly { store.setGrantedScopes(Set(GoogleOAuthConfig.scopes)) }
        let personal = UUID()
        let family = UUID()
        let holidays = UUID()
        store.replaceChoices(with: [
            .init(id: personal, entry: GoogleCalendarEntry(id: "sample-primary", name: "Personal", primary: true, accessRole: .owner), isOn: true),
            .init(id: family, entry: GoogleCalendarEntry(id: "sample-family", name: "Family", primary: false, accessRole: .owner), isOn: true),
            .init(id: holidays, entry: GoogleCalendarEntry(id: "sample-holidays", name: "Holidays", primary: false, accessRole: .reader), isOn: false),
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
        model.watch.showSampleProblem(calendar: "sample-family", code: "webhook_refused")
        return model
    }
}
#endif
