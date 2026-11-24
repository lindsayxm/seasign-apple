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
        /// Connect again from a working connection: Google's calendar list
        /// named no primary calendar, so the account could not be told and
        /// nothing changed. Trying again gets the same list (task 178).
        case accountNotShown
        /// Connect again from a working connection inside our own 429's
        /// Retry-After: the sheet was not opened and nothing was sent (the
        /// list read it needs would meet the same 429) (task 214).
        case busy
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
            case .accountNotShown:
                "Google didn't show which account you signed in with, so nothing changed. To add events, disconnect and connect again."
            case .busy:
                "Seasign is busy right now, so nothing changed. Try again in a moment."
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
    /// Moves only when a Connect begins (not on Disconnect). A revoke decided
    /// before a Connect began is not sent once it has: Google's revoke ends
    /// the account's whole grant, so it would end the new Connect's too if it
    /// is the same account (task 178).
    @ObservationIgnored private var connectsBegun = 0
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
        // Connect again from a working connection reads the calendar list
        // before anything is kept; inside our own 429's Retry-After that read
        // would meet the same 429. So the sheet is not opened and nothing is
        // sent (task 214). Nothing has begun: no attempt, no revoke skipped.
        if connection == .connected, serverLimitHold() != nil {
            connectProblem = .busy
            return
        }
        connectAttempt += 1
        let attempt = connectAttempt
        connectsBegun += 1
        let begun = connectsBegun
        isConnecting = true
        connectProblem = nil
        // A Disconnect (or a newer Connect) has already cleared it otherwise.
        defer { if attempt == connectAttempt { isConnecting = false } }
        // A Disconnect tapped while this runs (the expired state shows one)
        // moves the generation; this sign-in then keeps nothing.
        var started = generation

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
        // Disconnected (or a newer Connect) while the sheet was up: the code
        // is not exchanged, so there is no grant to hand back. The sign-in
        // here ending meanwhile is not a Disconnect: this goes on as a
        // Connect after it ended, and the sheet's sign-in is kept (task 214).
        guard goesOn(after: &started, attempt: attempt) else { return }
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
        guard goesOn(after: &started, attempt: attempt) else {
            // Disconnected during the exchange: the new grant is handed back
            // to Google and nothing is kept.
            handBack(fresh.refresh ?? fresh.access, begun: begun)
            return
        }
        // Connect again from a working connection (to add write access): a
        // failure leaves that connection exactly as it was. Nothing is
        // revoked then: Google's revoke "removes all OAuth 2.0 scopes
        // previously granted", so revoking the new token would also end the
        // grant the connection runs on (the same account's).
        var wasConnected = connection == .connected
        guard fresh.grantsNeededScopes, let refreshToken = fresh.refresh else {
            // Nothing is kept; the partial grant is handed back to Google.
            if !wasConnected { handBack(fresh.refresh ?? fresh.access, begun: begun) }
            connectProblem = .missingScope
            return
        }

        // Connect again (from a working connection, or after the sign-in
        // ended) may come back as another Google account: the sheet is
        // ephemeral and Google's login_hint is only a hint. The account is
        // told apart by its primary calendar's id, read with the new token
        // before anything is kept (task 175); see `matchAccount` (task 178).
        var list: [GoogleCalendarEntry]?
        var listFailure: (any Error)?
        var primaryRenamedFrom: String?
        if connection != .notConnected {
            if let held = serverLimitHold() {
                // Our 429's Retry-After is on: asking now gets another 429.
                listFailure = held
            } else {
                do {
                    list = try await api.googleCalendars(token: fresh.access)
                } catch {
                    listFailure = error
                }
            }
            var match: AccountMatch
            repeat {
                guard goesOn(after: &started, attempt: attempt) else {
                    // Disconnected meanwhile: handed back, nothing kept.
                    handBack(refreshToken, begun: begun)
                    return
                }
                wasConnected = connection == .connected
                // Decided again if the sign-in here ended while the old one
                // was asked (as after it ended: no read, no wait).
                match = await matchAccount(newList: list)
            } while started != generation
            switch match {
            case .same(let renamedFrom):
                primaryRenamedFrom = renamedFrom
            case .cannotTell(let failure):
                // A working connection stays exactly as it was. Nothing is
                // revoked: either token's revoke would end the other's grant
                // if both are the same account's. Our 429 still holds. A
                // failure may pass; a list without a primary will not.
                if let failure = listFailure ?? failure {
                    holdForServerLimit(failure)
                    connectProblem = .unavailable
                } else {
                    connectProblem = .accountNotShown
                }
                return
            case .other(let revokeOld):
                // Disconnect the old account first (its channels stopped with
                // its own token, its refresh token revoked before the new one
                // is saved, its choices, events, calendar for new events and
                // watch state gone), then a fresh Connect. After the sign-in
                // ended, its channels were stopped then and its token is gone.
                var ended = forgetAccount()
                if !revokeOld { ended.refreshToken = nil }
                if wasConnected { await stopAndRevoke(ended) }
                guard ended.generation == generation else {
                    // Disconnected meanwhile: nothing of the new one is kept.
                    handBack(refreshToken, begun: begun)
                    return
                }
                started = generation
                wasConnected = false
            }
        }

        do {
            try tokens.save(refreshToken)
        } catch {
            if !wasConnected { handBack(refreshToken, begun: begun) }
            connectProblem = .notSaved
            return
        }
        generation += 1
        access.set(fresh)
        retryNotBefore = nil
        failures = 0
        statusProblem = nil
        // A new grant: exactly what this answer says (nil when it says
        // nothing, which reads as no write access), in the same save as the
        // connection state.
        connection = .connected
        grantedScopes = fresh.scopes
        store.setConnected(grantedScopes: fresh.scopes)
        if wasConnected, !fresh.grantsWriteScope { connectProblem = .addingNotAllowed }
        if let list {
            applyCalendarList(list, primaryRenamedFrom: primaryRenamedFrom)
        } else if let listFailure {
            // Read just now (after the sign-in ended) and failed: as when a
            // first Connect's list load fails, with its status and hold (our
            // 429's Retry-After); Settings reads it again.
            handle(listFailure)
        } else {
            await loadCalendars()
        }
        await refresh(force: true)
    }

    /// What a Connect again's new sign-in is, next to the account here.
    private enum AccountMatch {
        /// The same account: everything is kept. `renamedFrom` is the
        /// primary calendar's id as known here when it now has another one.
        case same(renamedFrom: String?)
        /// Another account, or, after the sign-in ended, one that cannot be
        /// told: the account here is forgotten first. `revokeOld`: its
        /// sign-in still works and is revoked.
        case other(revokeOld: Bool)
        /// Cannot be told while the connection here works: nothing is kept.
        /// The failure that kept it from being told; nil when a list named
        /// no primary calendar.
        case cannotTell((any Error)?)
    }

    /// Whether a Connect whose generation moved while it waited goes on.
    /// Only when the sign-in here ended meanwhile (a poll, a push or the day
    /// screen met `invalid_grant`) with no Disconnect or newer Connect since:
    /// it then goes on as a Connect after the sign-in ended, and its grant is
    /// kept (task 178). After a Disconnect it is handed back.
    private func goesOn(after started: inout Int, attempt: Int) -> Bool {
        if started == generation { return true }
        guard connection == .expired, attempt == connectAttempt else { return false }
        started = generation
        return true
    }

    /// Our own 429's Retry-After, while it holds, as the failure a read sent
    /// now would meet; nil when no such hold is on. (A back-off or Google's
    /// limit on one calendar does not stop a Connect again from asking.)
    private func serverLimitHold() -> (any Error)? {
        guard holdIsServerLimit, let retryNotBefore, now() < retryNotBefore else { return nil }
        let seconds = Int(retryNotBefore.timeIntervalSince(now()).rounded(.up))
        return SeasignAPI.GoogleFailure.rateLimited(retryAfter: max(1, seconds))
    }

    /// Tells whether the sign-in that read `newList` (nil: it could not be
    /// read) is the account here (task 178).
    ///
    /// - The same primary calendar id: the same account.
    /// - After the sign-in ended there is nothing left to protect (Google
    ///   has ended the grant and its token is gone here), so anything else
    ///   (another primary, none on the list, no list) starts afresh, and the
    ///   new sign-in is kept.
    /// - From a working connection, a list without a primary cannot tell.
    ///   Another primary id is another account, or the same one whose
    ///   primary id changed (an email rename): the old sign-in is asked,
    ///   with its own token, which primary it has now. The same one is the
    ///   same account; another is another account; if it cannot be asked,
    ///   it cannot tell; if Google has ended it, there is nothing to protect.
    private func matchAccount(newList list: [GoogleCalendarEntry]?) async -> AccountMatch {
        let newPrimary = list?.first(where: \.primary)?.id
        let known = calendars.first(where: \.isPrimary)?.calendarID
        if let newPrimary, newPrimary == known { return .same(renamedFrom: nil) }
        guard connection == .connected else { return .other(revokeOld: false) }
        guard let newPrimary else { return .cannotTell(nil) }
        if let held = serverLimitHold() { return .cannotTell(held) }
        let oldPrimary: String?
        do {
            oldPrimary = try await withToken { api, token in try await api.googleCalendars(token: token) }
                .first(where: \.primary)?.id
        } catch GoogleAccess.Failure.signInEnded {
            return .other(revokeOld: false)
        } catch {
            return .cannotTell(error)
        }
        guard let oldPrimary else { return .cannotTell(nil) }
        return oldPrimary == newPrimary ? .same(renamedFrom: known) : .other(revokeOld: true)
    }

    /// Hands a grant this Connect does not keep back to Google, unless a
    /// newer Connect has begun since: Google's revoke ends the account's
    /// whole grant, so it would end that one's too if it is the same account.
    /// The grant then stays at Google (unused; the user can remove it in
    /// their Google Account).
    private func handBack(_ token: GoogleSecret, begun: Int) {
        guard let client, begun == connectsBegun else { return }
        Task { await client.revoke(token) }
    }

    /// Our 429 on a read whose failure changes nothing else here: its
    /// Retry-After holds Today's requests too, as on the add path.
    private func holdForServerLimit(_ error: any Error) {
        if case SeasignAPI.GoogleFailure.rateLimited(let seconds) = error {
            holdAtLeast(TimeInterval(seconds), serverLimit: true)
        }
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
        applyCalendarList(list)
        return nil
    }

    /// Folds a calendar list just read into the choices. `primaryRenamedFrom`:
    /// the same account's primary calendar had this id here; its choice
    /// follows it to the new id (on or off, and its events).
    private func applyCalendarList(_ list: [GoogleCalendarEntry], primaryRenamedFrom renamed: String? = nil) {
        listLoadedAt = now()
        statusProblem = nil
        let newPrimary = list.first(where: \.primary)?.id
        let existing = calendars.map { choice in
            var calendarID = choice.calendarID
            if let renamed, let newPrimary, calendarID == renamed { calendarID = newPrimary }
            return (id: choice.id, calendarID: calendarID, isOn: choice.isOn)
        }
        store.replaceChoices(with: GoogleCalendarMerge.merge(existing: existing, fetched: list))
        calendars = store.choices()
        if let snapshot { setSnapshot(snapshot.keeping(Set(chosen.map(\.id)))) }
        watch.sync(.calendars)
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
    /// waits for the channels at most `unwatchWait`, and is not sent if a
    /// Connect has begun meanwhile (it could end that one's grant). When the
    /// device token has not arrived yet, the watch keeper alone keeps one
    /// access token in memory for the unwatch it owes (`GoogleWatchKeeper.stop`).
    func disconnect() async {
        guard !isFrozen else { return }
        connectAttempt += 1
        isConnecting = false
        let ended = forgetAccount()
        await stopAndRevoke(ended)
    }

    /// What `forgetAccount` keeps of the account it forgot, for stopping its
    /// channels and revoking its sign-in afterwards.
    private struct EndedAccount {
        var refreshToken: GoogleSecret?
        var validToken: GoogleSecret?
        var lastToken: GoogleSecret?
        var mayNeedUnwatch: Bool
        var channelsLeft: Bool
        var generation: Int
        /// `connectsBegun` then: the revoke is not sent once a Connect has begun.
        var connectsBegun: Int
    }

    /// Disconnect's first half: forgets the account here at once (the token
    /// in memory and in the Keychain, the calendars, the cached events, the
    /// scopes and the calendar for new events, the watch state) and shows
    /// the not-connected state. Moves the generation. The isConnecting state
    /// is the caller's.
    private func forgetAccount() -> EndedAccount {
        generation += 1
        let ended = EndedAccount(
            refreshToken: try? tokens.read(),
            validToken: access?.validToken,
            lastToken: access?.lastToken,
            mayNeedUnwatch: watch.mayNeedUnwatch,
            channelsLeft: watch.channelsMayBeLeft,
            generation: generation,
            connectsBegun: connectsBegun
        )
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
        return ended
    }

    /// Disconnect's second half, best effort and in this order: stops the
    /// forgotten account's push channels (after any watch already out),
    /// waiting at most `unwatchWait`, then asks Google to revoke its sign-in
    /// unless a Connect has begun since.
    private func stopAndRevoke(_ ended: EndedAccount) async {
        if ended.mayNeedUnwatch {
            let stopping = Task { [weak self, watch, client] in
                var unwatchToken = ended.validToken
                if unwatchToken == nil, let token = ended.refreshToken, let client {
                    // One fresh token for the unwatch alone; it is not kept.
                    unwatchToken = try? await client.refresh(token).access
                }
                // A Connect finished meanwhile: its keeper state is not
                // wiped, and its own watch replaces this device's channels.
                guard let self, self.generation == ended.generation else { return }
                // Without a device token yet, the keeper keeps this token for an
                // unwatch sent when the device token arrives (after the revoke
                // below: the API forgets the channels whatever Google says).
                await watch.stop(using: unwatchToken ?? ended.lastToken, channelsLeft: ended.channelsLeft)
            }
            // The revoke waits for this at most `unwatchWait`, so it is never
            // left undone for long (the app could be closed meanwhile). The
            // unwatch is not cancelled; if it is still out, it ends by itself,
            // and the API forgets the channels whatever Google says of the token.
            await PushDeadline.race(stopping, deadline: unwatchWait, fallback: ())
        }
        // Not once a Connect has begun since (task 178): the revoke, sent up
        // to `unwatchWait` late, would end that sign-in's grant too if it is
        // the same account. The old grant then stays at Google.
        if let token = ended.refreshToken, let client, ended.connectsBegun == connectsBegun {
            await client.revoke(token)
        }
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

    // MARK: Adding an event (task 171)

    /// What `createEvent` came to.
    enum CreateOutcome: Equatable {
        /// Google has the event; `created` false means it already had this
        /// id (an earlier try that did succeed).
        case added(created: Bool)
        case failed(CreateProblem)
    }

    /// Why an event was not added, in the terms the confirm popup words.
    enum CreateProblem: Equatable {
        /// Not connected, or the sign-in has ended: connect in Settings.
        case notConnected
        /// The sign-in has no write access (`insufficient_scope`).
        case needsWriteAccess
        /// Google will not add events to this calendar (`forbidden`).
        case calendarRefused
        /// Google has no such calendar (`not_found`).
        case calendarMissing
        /// Google refused the event as sent (`rejected`); not retried.
        case rejected
        /// The API refused the request (400); not retried.
        case invalid
        /// Too many requests; the API's own limit holds until `until`.
        case rateLimited(until: Date?)
        /// Nothing certain: Google or the server could not be reached, or
        /// timed out. The event may have been added; retry with the same id.
        case unavailable
        /// The sign-in could not be renewed or read just now; retry later.
        case signInTrouble
    }

    /// Adds `event` through `POST /v1/google/events/create`, renewing the
    /// token once on a 401 (`withToken`). Its failures are its own: they set
    /// no status and no back-off for Today's poll, except our 429's
    /// `Retry-After` (the same limit Today's requests share) and a sign-in
    /// that has ended. On success the chosen calendars are read again at
    /// once, so Today shows the event without waiting for its poll. The
    /// DEBUG sample (`-debugGoogle YES`) sends nothing and answers success.
    func createEvent(_ event: GoogleNewEvent) async -> CreateOutcome {
        if isFrozen { return .added(created: true) }
        guard connection == .connected, access != nil else { return .failed(.notConnected) }
        let started = generation
        do {
            let answer = try await withToken { api, token in
                do {
                    return try await api.googleCreateEvent(token: token, event: event)
                } catch SeasignAPI.GoogleCreateFailure.googleAuth {
                    // As `withToken` expects, so it renews and asks once more.
                    throw SeasignAPI.GoogleFailure.googleAuth
                }
            }
            if started == generation {
                Task { await self.refresh(force: true) }
            }
            return .added(created: answer.created)
        } catch let failure as SeasignAPI.GoogleCreateFailure {
            switch failure {
            case .googleAuth: return .failed(.signInTrouble)
            case .insufficientScope:
                if started == generation { dropWriteAccess() }
                return .failed(.needsWriteAccess)
            case .forbidden: return .failed(.calendarRefused)
            case .notFound: return .failed(.calendarMissing)
            case .invalidRequest: return .failed(.invalid)
            case .rejected: return .failed(.rejected)
            case .unavailable: return .failed(.unavailable)
            case .rateLimited(let seconds?):
                if started == generation { holdAtLeast(TimeInterval(seconds), serverLimit: true) }
                return .failed(.rateLimited(until: now().addingTimeInterval(TimeInterval(seconds))))
            case .rateLimited(nil):
                return .failed(.rateLimited(until: nil))
            }
        } catch let failure as GoogleAccess.Failure {
            switch failure {
            case .signInEnded:
                if started == generation { endSignIn(.expired) }
                return .failed(.notConnected)
            case .unavailable:
                return .failed(.unavailable)
            case .keychainUnreadable, .rejected:
                return .failed(.signInTrouble)
            }
        } catch is RepeatedAuthFailure {
            return .failed(.signInTrouble)
        } catch is SignInChanged {
            // A 401 for the sign-in before a switch: not sent again with the
            // new one's token. Nothing was added.
            return .failed(.signInTrouble)
        } catch {
            return .failed(.unavailable)
        }
    }

    /// Google said this sign-in cannot add events (`insufficient_scope`),
    /// whatever the stored scopes said: the write scope is dropped from them,
    /// where they are stored, so `canAddEvents` is false and Settings offers
    /// "Connect again to add events". The connection keeps reading.
    private func dropWriteAccess() {
        guard connection == .connected, let scopes = grantedScopes,
              scopes.contains(GoogleOAuthConfig.writeScope)
        else { return }
        let kept = scopes.subtracting([GoogleOAuthConfig.writeScope])
        grantedScopes = kept
        store.setGrantedScopes(kept)
    }

    /// Our 429 on the add path: hold Today's requests too, never shortening
    /// a longer hold that is already on.
    private func holdAtLeast(_ seconds: TimeInterval, serverLimit: Bool) {
        if let retryNotBefore, retryNotBefore >= now().addingTimeInterval(seconds) { return }
        hold(seconds, serverLimit: serverLimit)
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
    /// token and tries once more, unless the sign-in changed meanwhile
    /// (Disconnect, Connect again, the sign-in ended): the token in memory
    /// then is not the one Google refused, so it is left alone, and the
    /// request is not sent again with another account's token (task 178).
    private func withToken<T>(_ call: (SeasignAPI, GoogleSecret) async throws -> T) async throws -> T {
        guard let access else { throw SeasignAPI.GoogleFailure.unavailable }
        let started = generation
        let token = try await access.token()
        guard started == generation else { throw SignInChanged() }
        do {
            return try await call(api, token)
        } catch SeasignAPI.GoogleFailure.googleAuth {
            guard started == generation else { throw SignInChanged() }
            access.invalidate()
            let renewed = try await access.token()
            guard started == generation else { throw SignInChanged() }
            do {
                return try await call(api, renewed)
            } catch SeasignAPI.GoogleFailure.googleAuth {
                throw RepeatedAuthFailure()
            }
        }
    }

    private struct RepeatedAuthFailure: Error {}
    /// The sign-in changed while a request was out; its answer is dropped.
    private struct SignInChanged: Error {}

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
        // A note left by an earlier Connect no longer applies; Settings now
        // says the sign-in ended and offers Connect again (task 214).
        connectProblem = nil
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
    /// A value that comes first always wins: it is handed over before the
    /// timer is cancelled, and a cancelled timer hands over nothing (its
    /// sleep ending early by cancellation is not the deadline passing).
    static func race<T: Sendable>(_ task: Task<T, Never>, deadline: Duration, fallback: T) async -> T {
        let once = Once<T>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: deadline)
                } catch {
                    return
                }
                once.resume(fallback)
            }
            Task {
                let value = await task.value
                once.resume(value)
                timer.cancel()
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
    /// made before write access was asked for. `connectProblem`
    /// (`-debugGoogleConnectProblem <case>`) shows that Connect problem's
    /// note in Settings, on this sample only (task 214).
    static func sample(
        now: Date = Date(), timeZone: TimeZone = .current, readOnly: Bool = false, connectProblem: ConnectProblem? = nil
    ) throws -> GoogleCalendarModel {
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
        model.connectProblem = connectProblem
        return model
    }
}

extension GoogleCalendarModel.ConnectProblem {
    /// Debug-only: the case named by `-debugGoogleConnectProblem` (its
    /// name in code, e.g. `accountNotShown`); nil for any other value.
    /// `google(_)` is not offered.
    static func debugNamed(_ name: String?) -> Self? {
        switch name {
        case "notConfigured": .notConfigured
        case "couldNotOpen": .couldNotOpen
        case "denied": .denied
        case "badAnswer": .badAnswer
        case "missingScope": .missingScope
        case "addingNotAllowed": .addingNotAllowed
        case "unavailable": .unavailable
        case "accountNotShown": .accountNotShown
        case "busy": .busy
        case "notSaved": .notSaved
        default: nil
        }
    }
}
#endif
