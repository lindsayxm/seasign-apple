import Foundation
import HTTPTypes
import OpenAPIRuntime
import Security
import SwiftData
import Testing

@testable import Seasign

// Task 169: the sign-in also asks for write access (`calendar.events.owned`),
// the granted scopes are stored, and Settings chooses where new events go.
// Google's token endpoint and the API are mocked (`FakeGoogleEndpoint`,
// `GoogleAPIStub`); nothing here reaches Google.

// MARK: - Rules

@Suite struct GoogleWriteAccessRulesTests {
    @Test func theSignInAsksForTheTwoReadScopesAndTheOwnedEventsScope() {
        #expect(GoogleOAuthConfig.readScopes == [
            "https://www.googleapis.com/auth/calendar.events.readonly",
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        ])
        #expect(GoogleOAuthConfig.writeScope == "https://www.googleapis.com/auth/calendar.events.owned")
        #expect(GoogleOAuthConfig.scopes == GoogleOAuthConfig.readScopes + [GoogleOAuthConfig.writeScope])
    }

    @Test func connectingNeedsOnlyTheReadScopesAndWriteIsNeverAssumed() {
        func tokens(_ scopes: Set<String>?) -> GoogleTokens {
            GoogleTokens(access: GoogleSecret("a"), expiresAt: .now, refresh: nil, scopes: scopes)
        }
        let read = Set(GoogleOAuthConfig.readScopes)
        let all = Set(GoogleOAuthConfig.scopes)
        #expect(tokens(all).grantsNeededScopes && tokens(all).grantsWriteScope)
        #expect(tokens(read).grantsNeededScopes && !tokens(read).grantsWriteScope)
        // A grant missing a read scope does not connect, write or not.
        let partial: Set<String> = [GoogleOAuthConfig.readScopes[0], GoogleOAuthConfig.writeScope]
        #expect(!tokens(partial).grantsNeededScopes)
        // An answer without `scope`: the read scopes as asked (as before), never write.
        #expect(tokens(nil).grantsNeededScopes && !tokens(nil).grantsWriteScope)
        #expect(!GoogleOAuthConfig.allowsAddingEvents(nil))
        #expect(!GoogleOAuthConfig.allowsAddingEvents([]))
        #expect(GoogleOAuthConfig.allowsAddingEvents([GoogleOAuthConfig.writeScope]))
    }

    @Test func storedScopesReadBackAsTheyWereWritten() {
        let all = Set(GoogleOAuthConfig.scopes)
        #expect(GoogleOAuthConfig.split(GoogleOAuthConfig.joined(all)) == all)
        #expect(GoogleOAuthConfig.split(nil) == nil)
    }

    @Test func onlyCalendarsTheUserOwnsAreOfferedForNewEvents() {
        #expect(GoogleAccessRole.allCases.filter(\.takesNewEvents) == [.owner])
        func choice(_ id: String, _ role: GoogleAccessRole?, primary: Bool = false) -> GoogleCalendarChoice {
            GoogleCalendarChoice(calendarID: id, name: id, isPrimary: primary, isOn: true, order: 0, accessRole: role)
        }
        let calendars = [
            choice("me", .owner, primary: true), choice("mine", .owner), choice("shared", .writer),
            choice("shared-limited", .writerWithoutPrivateAccess), choice("holidays", .reader),
            choice("busy", .freeBusyReader), choice("unknown", nil),
        ]
        #expect(GoogleNewEventsCalendar.offered(calendars).map(\.calendarID) == ["me", "mine"])
    }

    @Test func theDefaultIsThePrimaryAndAChoiceThatIsGoneFallsBackToIt() {
        func choice(_ id: String, _ role: GoogleAccessRole?, primary: Bool = false) -> GoogleCalendarChoice {
            GoogleCalendarChoice(calendarID: id, name: id, isPrimary: primary, isOn: true, order: 0, accessRole: role)
        }
        let me = choice("me", .owner, primary: true)
        let mine = choice("mine", .owner)
        #expect(GoogleNewEventsCalendar.resolve([me, mine], storedID: nil)?.calendarID == "me")
        #expect(GoogleNewEventsCalendar.resolve([me, mine], storedID: "mine")?.calendarID == "mine")
        // The chosen calendar left the list, or is no longer the user's.
        #expect(GoogleNewEventsCalendar.resolve([me], storedID: "mine")?.calendarID == "me")
        #expect(GoogleNewEventsCalendar.resolve([me, choice("mine", .reader)], storedID: "mine")?.calendarID == "me")
        // A stored id that names a calendar not offered is not used.
        #expect(GoogleNewEventsCalendar.resolve([me, choice("shared", .writer)], storedID: "shared")?.calendarID == "me")
        // Roles not known yet (a connection from before task 169): nothing.
        #expect(GoogleNewEventsCalendar.resolve([choice("me", nil, primary: true)], storedID: nil) == nil)
        #expect(GoogleNewEventsCalendar.resolve([], storedID: "mine") == nil)
    }

    @Test func aRefreshAnswerWithoutScopeSaysNothingAboutScopes() async throws {
        let endpoint = FakeGoogleEndpoint()
        let client = GoogleTokenClient(config: FakeGoogle.config, http: endpoint.http)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(refresh: nil, scope: nil))
        #expect(try await client.refresh(GoogleSecret("r")).scopes == nil)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(refresh: nil, scope: FakeGoogle.readOnlyScopes))
        #expect(try await client.refresh(GoogleSecret("r")).scopes == Set(GoogleOAuthConfig.readScopes))
    }

    @Test func theCalendarListCarriesEachCalendarsAccessRole() async throws {
        let stub = GoogleAPIStub()
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [
            ("me", "Me", true, "owner"), ("shared", "Shared", false, "writer"),
            ("limited", "Limited", false, "writerWithoutPrivateAccess"), ("holidays", "Holidays", false, "reader"),
            ("busy", "Busy", false, "freeBusyReader"), ("old", "Old", false, nil),
        ]))
        let api = SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub)
        let list = try await api.googleCalendars(token: GoogleSecret(FakeGoogle.access))
        #expect(list.map(\.accessRole) == [.owner, .writer, .writerWithoutPrivateAccess, .reader, .freeBusyReader, nil])
    }
}

// MARK: - The model

@Suite @MainActor struct GoogleWriteAccessModelTests {
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

    private func redirect(_ build: @escaping (String) -> String) -> @MainActor (URL, String) async throws -> URL {
        { url, scheme in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?\(build(state))")!
        }
    }

    private var goodRedirect: @MainActor (URL, String) async throws -> URL {
        redirect { "state=\($0)&code=\(FakeGoogle.code)" }
    }

    /// The account's list: two calendars the user owns, one shared for
    /// writing, one read-only.
    private func answerAccount(scope: String? = FakeGoogle.allScopes, refresh: String = FakeGoogle.refresh) {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(refresh: refresh, scope: scope))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [
            ("me@example.test", "Me", true, "owner"),
            ("family-id", "Family", false, "owner"),
            ("team-id", "Team", false, "writer"),
            ("holidays-id", "Holidays", false, "reader"),
        ]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil]
        ))
    }

    private func connected(_ context: ModelContext, store: InMemoryGoogleTokenStore, scope: String? = FakeGoogle.allScopes) async -> GoogleCalendarModel {
        answerAccount(scope: scope)
        let model = model(context, store: store)
        await model.connect(signIn: goodRedirect)
        return model
    }

    private func storedScopes(_ context: ModelContext) throws -> String? {
        try context.fetch(FetchDescriptor<GoogleAccount>()).first?.grantedScopes
    }

    private func titles(_ model: GoogleCalendarModel) -> [String] {
        model.upcoming(now: clock.now).map(\.title)
    }

    @Test func aFullGrantCanAddEventsToThePrimaryCalendar() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        #expect(model.connection == .connected)
        #expect(model.canAddEvents)
        #expect(model.grantedScopes == Set(GoogleOAuthConfig.scopes))
        #expect(try storedScopes(context) == GoogleOAuthConfig.joined(Set(GoogleOAuthConfig.scopes)))
        #expect(model.newEventsCalendars.map(\.calendarID) == ["me@example.test", "family-id"])
        #expect(model.newEventsCalendar?.calendarID == "me@example.test")
        // The roles are stored with the choices.
        #expect(model.calendars.map(\.accessRole) == [.owner, .owner, .writer, .reader])
    }

    @Test func writeAccessUntickedStillConnectsAndReadsAsBefore() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store, scope: FakeGoogle.readOnlyScopes)
        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == FakeGoogle.refresh)
        #expect(titles(model) == ["Coffee"])
        #expect(model.canPoll)
        #expect(!model.canAddEvents)
        #expect(model.grantedScopes == Set(GoogleOAuthConfig.readScopes))
        try await Task.sleep(for: .milliseconds(50))
        #expect(endpoint.revoked.isEmpty)
    }

    @Test func aGrantMissingAReadScopeIsRefusedEvenWithWriteAccess() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(
            context, store: store,
            scope: [GoogleOAuthConfig.readScopes[0], GoogleOAuthConfig.writeScope].joined(separator: " ")
        )
        #expect(model.connectProblem == .missingScope)
        #expect(model.connection == .notConnected)
        #expect(!model.canAddEvents)
        #expect(store.stored == nil)
        #expect(await endpoint.waitForRevoked(count: 1) == [FakeGoogle.refresh])
    }

    @Test func anExchangeThatDoesNotNameTheScopesConnectsWithoutWriteAccess() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore(), scope: nil)
        #expect(model.connection == .connected)
        #expect(model.grantedScopes == nil)
        #expect(!model.canAddEvents)
    }

    @Test func connectingAgainFromAReadOnlyConnectionAddsWriteAccessAndKeepsChoices() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store, scope: FakeGoogle.readOnlyScopes)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        let me = try #require(model.calendars.first { $0.calendarID == "me@example.test" })
        model.setOn(me, false)
        model.setOn(family, true)
        let ids = model.calendars.map(\.id)
        let on = model.calendars.map(\.isOn)
        #expect(!model.canAddEvents)

        answerAccount(scope: FakeGoogle.allScopes, refresh: "fake-refresh-two")
        await model.connect(signIn: goodRedirect)
        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(model.canAddEvents)
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.calendars.map(\.isOn) == on)
        #expect(model.chosen.map(\.calendarID) == ["family-id"])
        #expect(store.stored?.secret == "fake-refresh-two")
        // The earlier grant is not revoked (it could end the new one).
        try await Task.sleep(for: .milliseconds(50))
        #expect(endpoint.revoked.isEmpty)
        // Polling carries on with the chosen calendars.
        await model.refresh(force: true)
        #expect(stub.seen.last { $0.operationID == GoogleAPIStub.postEvents }?.calendars == ["family-id"])
    }

    @Test func aFailedConnectAgainLeavesTheReadOnlyConnectionAsItWas() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store, scope: FakeGoogle.readOnlyScopes)
        model.setNewEventsCalendar(try #require(model.calendars.first { $0.calendarID == "family-id" }))
        let ids = model.calendars.map(\.id)
        let on = model.calendars.map(\.isOn)
        let readOnly = GoogleOAuthConfig.joined(Set(GoogleOAuthConfig.readScopes))
        #expect(try storedScopes(context) == readOnly)

        func expectUnchanged(_ comment: Comment) {
            #expect(model.connection == .connected, comment)
            #expect(store.stored?.secret == FakeGoogle.refresh, comment)
            #expect(model.calendars.map(\.id) == ids, comment)
            #expect(model.calendars.map(\.isOn) == on, comment)
            #expect(titles(model) == ["Coffee"], comment)
            #expect(model.canPoll, comment)
            #expect(!model.canAddEvents, comment)
            #expect(model.grantedScopes == Set(GoogleOAuthConfig.readScopes), comment)
            #expect((try? storedScopes(context)) == readOnly, comment)
            #expect(model.newEventsCalendarID == "family-id", comment)
            #expect((try? context.fetch(FetchDescriptor<GoogleAccount>()).first?.newEventsCalendarID) == "family-id", comment)
        }

        await model.connect(signIn: { _, _ in throw GoogleSignInCancelled() })
        #expect(model.connectProblem == nil)
        expectUnchanged("cancelled")

        await model.connect(signIn: redirect { "state=\($0)&error=access_denied" })
        #expect(model.connectProblem == .addingNotAllowed)
        expectUnchanged("declined")

        await model.connect(signIn: redirect { _ in "state=forged&code=c" })
        #expect(model.connectProblem == .badAnswer)
        expectUnchanged("another state")

        endpoint.answer("authorization_code", FakeGoogleEndpoint.error("invalid_client", status: 401))
        await model.connect(signIn: goodRedirect)
        #expect(model.connectProblem == .google("invalid_client"))
        expectUnchanged("exchange refused")

        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(
            refresh: "fake-refresh-two", scope: [GoogleOAuthConfig.readScopes[1], GoogleOAuthConfig.writeScope].joined(separator: " ")
        ))
        await model.connect(signIn: goodRedirect)
        #expect(model.connectProblem == .missingScope)
        expectUnchanged("a read scope unticked")

        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(refresh: "fake-refresh-two"))
        store.setFailure(KeychainFailure(status: errSecInteractionNotAllowed))
        await model.connect(signIn: goodRedirect)
        store.setFailure(nil)
        #expect(model.connectProblem == .notSaved)
        expectUnchanged("keychain failed")

        // Task 175: the new sign-in's calendar list (which tells the account)
        // could not be read: nothing is kept, so nothing can mix.
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(refresh: "fake-refresh-two"))
        stub.setOffline(true)
        await model.connect(signIn: goodRedirect)
        stub.setOffline(false)
        #expect(model.connectProblem == .unavailable)
        expectUnchanged("the list unreachable")

        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        await model.connect(signIn: goodRedirect)
        #expect(model.connectProblem == .unavailable)
        expectUnchanged("the list rate limited")
        // Task 178: our 429's Retry-After is kept as a hold, not ignored.
        #expect(model.retryNotBefore == clock.now.addingTimeInterval(30))
        // Task 214: inside that hold, Connect again opens no sheet.
        await model.connect(signIn: goodRedirect)
        #expect(model.connectProblem == .busy)
        expectUnchanged("inside our 429's hold")
        clock.advance(30)

        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.error(.forbidden, "google_forbidden"))
        await model.connect(signIn: goodRedirect)
        #expect(model.connectProblem == .unavailable)
        expectUnchanged("the list refused")

        // Nothing is revoked: Google's revoke would end the working grant too.
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Task 175: connection state and scopes are one save. An expired
    /// connection that had write access, connected again with an exchange
    /// that does not name the scopes, is read-only; and no save on the way
    /// stored "connected" with the old grant's write access (a crash between
    /// two saves would have left it so).
    @Test func anExpiredWriteConnectionReconnectedWithoutScopesIsReadOnlyAtEverySave() async throws {
        let container = try SeasignSchema.inMemoryContainer()
        let context = ModelContext(container)
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        #expect(model.canAddEvents)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        #expect(model.connection == .expired)
        // The ended connection's row keeps the old grant's scopes.
        #expect(try storedScopes(context) == GoogleOAuthConfig.joined(Set(GoogleOAuthConfig.scopes)))

        let saves = SavedAccountStates()
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { _ in
            MainActor.assumeIsolated {
                let row = try? ModelContext(container).fetch(FetchDescriptor<GoogleAccount>()).first
                saves.append(state: row?.stateRaw, scopes: row?.grantedScopes)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        answerAccount(scope: nil)
        await model.connect(signIn: goodRedirect)
        NotificationCenter.default.removeObserver(observer)

        #expect(model.connection == .connected)
        #expect(model.grantedScopes == nil)
        #expect(!model.canAddEvents)
        #expect(try storedScopes(context) == nil)
        #expect(!self.model(context, store: store).canAddEvents)
        let connectedSaves = saves.all.filter { $0.state == GoogleConnection.connected.rawValue }
        #expect(!connectedSaves.isEmpty)
        #expect(connectedSaves.allSatisfy { $0.scopes == nil }, "\(connectedSaves.map { $0.scopes ?? "nil" })")
    }

    /// Task 175: a poll's renewal finds the sign-in ended (`invalid_grant`)
    /// while the Connect again sheet is up. Since task 214 that is not taken
    /// for a Disconnect: the sign-in made in the sheet is exchanged and kept,
    /// as a Connect after the sign-in ended (before, it was dropped
    /// unexchanged and the connection stayed expired). The same account
    /// keeps its choices and its calendar for new events; nothing is revoked.
    @Test func aSignInThatEndsWhileTheConnectAgainSheetIsUpKeepsTheSheetsSignIn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        model.setNewEventsCalendar(try #require(model.calendars.first { $0.calendarID == "family-id" }))
        let ids = model.calendars.map(\.id)
        let clock = clock
        let endpoint = endpoint
        let sheet = goodRedirect
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(refresh: "fake-refresh-two"))

        await model.connect(signIn: { url, scheme in
            clock.advance(3600)
            endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
            await model.refresh()
            #expect(model.connection == .expired)
            return try await sheet(url, scheme)
        })

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(!model.isConnecting)
        #expect(store.stored?.secret == "fake-refresh-two")
        #expect(endpoint.sent(grant: "authorization_code").count == 2)
        #expect(model.canAddEvents)
        #expect(model.canPoll)
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.newEventsCalendarID == "family-id")
        #expect(endpoint.revoked.isEmpty)
    }

    @Test func connectingAgainWithWriteUntickedAgainSaysSoAndStillReads() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store, scope: FakeGoogle.readOnlyScopes)
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(refresh: "fake-refresh-two", scope: FakeGoogle.readOnlyScopes))
        await model.connect(signIn: goodRedirect)
        #expect(model.connection == .connected)
        #expect(model.connectProblem == .addingNotAllowed)
        #expect(!model.canAddEvents)
        #expect(titles(model) == ["Coffee"])
        #expect(store.stored?.secret == "fake-refresh-two")
    }

    @Test func storedScopesAndTheChosenCalendarSurviveARelaunch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setNewEventsCalendar(family)
        let sent = stub.seen.count

        let relaunched = self.model(context, store: store)
        #expect(relaunched.connection == .connected)
        #expect(relaunched.canAddEvents)
        #expect(relaunched.grantedScopes == Set(GoogleOAuthConfig.scopes))
        #expect(relaunched.newEventsCalendar?.calendarID == "family-id")
        #expect(stub.seen.count == sent)

        // A read-only connection stays read-only after a relaunch.
        let other = ModelContext(try SeasignSchema.inMemoryContainer())
        let otherStore = InMemoryGoogleTokenStore()
        _ = await connected(other, store: otherStore, scope: FakeGoogle.readOnlyScopes)
        #expect(!self.model(other, store: otherStore).canAddEvents)
    }

    @Test func aRenewalThatNamesTheScopesReplacesThemAndOneThatDoesNotLeavesThem() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        #expect(model.canAddEvents)

        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil, scope: nil))
        await model.refresh(force: true)
        #expect(endpoint.sent(grant: "refresh_token").count == 1)
        #expect(model.canAddEvents)
        #expect(try storedScopes(context) == GoogleOAuthConfig.joined(Set(GoogleOAuthConfig.scopes)))

        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil, scope: FakeGoogle.readOnlyScopes))
        await model.refresh(force: true)
        #expect(endpoint.sent(grant: "refresh_token").count == 2)
        #expect(!model.canAddEvents)
        #expect(try storedScopes(context) == GoogleOAuthConfig.joined(Set(GoogleOAuthConfig.readScopes)))
        // Reading goes on as before (the sample event has ended by now).
        #expect(model.connection == .connected)
        #expect(model.statusProblem == nil)
        #expect(model.canPoll)
        #expect(stub.seen.last { $0.operationID == GoogleAPIStub.postEvents }?.token == FakeGoogle.access2)
    }

    @Test func theCalendarForNewEventsFallsBackToThePrimaryWhenItIsGone() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        let team = try #require(model.calendars.first { $0.calendarID == "team-id" })
        let me = try #require(model.calendars.first { $0.calendarID == "me@example.test" })

        model.setNewEventsCalendar(team)  // shared for writing only: not offered, ignored
        #expect(model.newEventsCalendar?.calendarID == "me@example.test")
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).first?.newEventsCalendarID == nil)

        model.setNewEventsCalendar(family)
        #expect(model.newEventsCalendar?.calendarID == "family-id")
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).first?.newEventsCalendarID == "family-id")

        // Family leaves the list: the primary, and the choice is kept for its return.
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [("me@example.test", "Me", true, "owner")]))
        await model.loadCalendars()
        #expect(model.newEventsCalendar?.calendarID == "me@example.test")
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [
            ("me@example.test", "Me", true, "owner"), ("family-id", "Family", false, "owner"),
        ]))
        await model.loadCalendars()
        #expect(model.newEventsCalendar?.calendarID == "family-id")

        // Family is no longer the user's (shared to them read-only): the primary.
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [
            ("me@example.test", "Me", true, "owner"), ("family-id", "Family", false, "reader"),
        ]))
        await model.loadCalendars()
        #expect(model.newEventsCalendars.map(\.calendarID) == ["me@example.test"])
        #expect(model.newEventsCalendar?.calendarID == "me@example.test")

        // Choosing the primary stores nothing: it is the default.
        let primary = try #require(model.calendars.first { $0.isPrimary })
        #expect(primary.id == me.id)
        model.setNewEventsCalendar(primary)
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).first?.newEventsCalendarID == nil)
    }

    @Test func disconnectForgetsScopesAndTheCalendarForNewEvents() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, store: InMemoryGoogleTokenStore())
        model.setNewEventsCalendar(try #require(model.calendars.first { $0.calendarID == "family-id" }))
        await model.disconnect()
        #expect(!model.canAddEvents)
        #expect(model.grantedScopes == nil)
        #expect(model.newEventsCalendarID == nil)
        #expect(model.newEventsCalendar == nil)
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).isEmpty)
    }

    @Test func anEndedSignInCannotAddEventsAndANewGrantSetsTheScopesAfresh() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        #expect(model.connection == .expired)
        #expect(!model.canAddEvents)

        // Connect again with write unticked: the old grant's write access is not carried over.
        answerAccount(scope: FakeGoogle.readOnlyScopes)
        await model.connect(signIn: goodRedirect)
        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(!model.canAddEvents)
        #expect(model.grantedScopes == Set(GoogleOAuthConfig.readScopes))
    }

    /// The state of a phone connected before task 169 (the user's simulator):
    /// an account row with no scopes and choices with no role.
    @Test func aConnectionFromBeforeWriteAccessKeepsReadingAndCannotAddEvents() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let me = UUID()
        context.insert(GoogleAccount(stateRaw: GoogleConnection.connected.rawValue))
        context.insert(GoogleCalendarChoice(id: me, calendarID: "me@example.test", name: "Me", isPrimary: true, isOn: true, order: 0))
        try context.save()
        let store = InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh))

        let model = model(context, store: store)
        #expect(model.connection == .connected)
        #expect(model.canPoll)
        #expect(!model.canAddEvents)
        #expect(model.grantedScopes == nil)
        #expect(model.newEventsCalendar == nil)

        // Reading works as before: a renewal (its answer without `scope`
        // here) and an events request.
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(refresh: nil, scope: nil))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil]
        ))
        await model.refresh(force: true)
        #expect(titles(model) == ["Coffee"])
        #expect(model.statusProblem == nil)
        #expect(model.grantedScopes == nil)
        #expect(store.stored?.secret == FakeGoogle.refresh)

        // The list read in Settings fills in the roles; still no write access.
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [("me@example.test", "Me", true, "owner")]))
        await model.loadCalendars()
        #expect(model.calendars.map(\.id) == [me])
        #expect(model.chosen.map(\.id) == [me])
        #expect(model.calendars.first?.accessRole == .owner)
        #expect(!model.canAddEvents)
    }
}

/// What the account row held at each save (task 175).
@MainActor
final class SavedAccountStates {
    private(set) var all: [(state: String?, scopes: String?)] = []

    func append(state: String?, scopes: String?) {
        all.append((state, scopes))
    }
}
