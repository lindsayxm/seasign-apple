import Foundation
import Security
import SwiftData
import Testing

@testable import Seasign

// Task 175: "Connect again" (to add events, or after the sign-in ended) can
// come back as a different Google account. The account is told apart by its
// primary calendar's id, read with the new token before anything is kept; a
// different one is a Disconnect of the old account (channels stopped, old
// refresh token revoked before the new one is saved, choices, cached events,
// the calendar for new events and the watch keeper reset) followed by a
// fresh Connect. The same account keeps everything and nothing is revoked,
// since Google's revoke ends the whole grant. Google's token endpoint and the
// API are mocked; nothing here reaches Google.

/// A token store that tells the test when a token is saved, so the test can
/// see what had been revoked by then.
final class RecordingGoogleTokenStore: GoogleTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = InMemoryGoogleTokenStore()
    private var saveHandler: (@Sendable (GoogleSecret) -> Void)?

    func onSave(_ handler: @escaping @Sendable (GoogleSecret) -> Void) {
        lock.withLock { saveHandler = handler }
    }

    var stored: GoogleSecret? { inner.stored }

    /// Reads and saves throw this until set to nil.
    func setFailure(_ failure: KeychainFailure?) {
        inner.setFailure(failure)
    }

    func read() throws -> GoogleSecret? { try inner.read() }

    func save(_ token: GoogleSecret) throws {
        let handler = lock.withLock { saveHandler }
        handler?(token)
        try inner.save(token)
    }

    func delete() throws { try inner.delete() }
}

/// What the endpoint had revoked at each save.
final class RevokedAtSave: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String]] = []

    func append(_ value: [String]) {
        lock.withLock { entries.append(value) }
    }

    var all: [[String]] {
        lock.withLock { entries }
    }
}

@Suite @MainActor struct GoogleConnectAgainTests {
    private let endpoint = FakeGoogleEndpoint()
    private let stub = GoogleAPIStub()
    private let clock = TestClock(instant("2026-11-19T18:00:00Z"))
    private let zone = TimeZone(identifier: "America/Chicago")!
    private let weekLater = "2026-11-26T18:00:00Z"

    private static let accessB = "fake-access-token-b/not+real="
    private static let refreshB = "fake-refresh-token-b/not+real"
    /// A's second sign-in's access token (the same account connecting again).
    private static let accessA2 = "fake-access-token-a2/not+real="

    private func model(_ context: ModelContext, store: any GoogleTokenStore, unwatchWait: Duration = .seconds(5)) -> GoogleCalendarModel {
        let clock = clock
        let zone = zone
        return GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub),
            context: context,
            config: FakeGoogle.config,
            tokens: store,
            http: endpoint.http,
            timeZone: { zone },
            now: { clock.now },
            environment: .sandbox,
            unwatchWait: unwatchWait
        )
    }

    private var signIn: @MainActor (URL, String) async throws -> URL {
        { url, scheme in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?state=\(state)&code=\(FakeGoogle.code)")!
        }
    }

    /// Account A: its primary, a calendar of its own, and Family, which the
    /// user also manages from account B (so it is on both lists, as owner).
    /// A's list is also what any of A's tokens reads later (task 178: the
    /// old sign-in is asked for its primary when the new one names another).
    private func answerAccountA(scope: String = FakeGoogle.allScopes, refresh: String = FakeGoogle.refresh, access: String = FakeGoogle.access) {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: access, refresh: refresh, scope: scope))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil, scope: scope))
        let list = GoogleAPIStub.calendars(roles: [
            ("me@example.test", "Me", true, "owner"),
            ("family-id", "Family", false, "owner"),
            ("a-only-id", "Work", false, "owner"),
        ])
        stub.answer(GoogleAPIStub.getCalendars, list)
        for token in Set([FakeGoogle.access, FakeGoogle.access2, access]) {
            stub.answer(GoogleAPIStub.getCalendars, token: token, list)
        }
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z"), (1, "Dinner", "2026-11-19T23:00:00Z", "2026-11-20T00:00:00Z")],
            statuses: [nil, nil]
        ))
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, nil], expiresAt: weekLater))
        stub.answer(GoogleAPIStub.postUnwatch, GoogleAPIStub.unwatched(2))
    }

    /// Account B: another primary, and Family.
    private func answerAccountB() {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessB, refresh: Self.refreshB, scope: FakeGoogle.allScopes))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [
            ("other@example.test", "Other", true, "owner"),
            ("family-id", "Family", false, "owner"),
        ]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Swim", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil]
        ))
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: weekLater))
    }

    /// Connected as A with Family on and chosen for new events, its device
    /// token in and its channels live.
    private func connectedAsA(
        _ context: ModelContext, store: any GoogleTokenStore, scope: String = FakeGoogle.allScopes, unwatchWait: Duration = .seconds(5)
    ) async throws -> GoogleCalendarModel {
        answerAccountA(scope: scope)
        let model = model(context, store: store, unwatchWait: unwatchWait)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try #require(model.connection == .connected)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        model.setNewEventsCalendar(family)
        await model.refresh(force: true)
        model.registered(FakeDevice.token)
        try await idle(model)
        try #require(model.watch.isLive)
        try #require(titles(model) == ["Coffee", "Dinner"])
        return model
    }

    private func titles(_ model: GoogleCalendarModel) -> [String] {
        model.upcoming(now: clock.now).map(\.title)
    }

    private func storedAccount(_ context: ModelContext) throws -> GoogleAccount? {
        try context.fetch(FetchDescriptor<GoogleAccount>()).first
    }

    private func requests(_ operationID: String, from index: Int) -> [GoogleAPIStub.Seen] {
        stub.seen.dropFirst(index).filter { $0.operationID == operationID }
    }

    @Test func aDifferentAccountIsADisconnectOfTheOldOneThenAFreshConnect() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let oldFamily = try #require(model.calendars.first { $0.calendarID == "family-id" }).id
        let before = stub.seen.count
        let revokedAtSave = RevokedAtSave()
        let endpoint = endpoint
        store.onSave { _ in revokedAtSave.append(endpoint.revoked) }

        answerAccountB()
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try await idle(model)

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == Self.refreshB)
        // The old refresh token was revoked, and before the new one was saved.
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(revokedAtSave.all == [[FakeGoogle.refresh]])
        // The old account's channels were stopped with its own token.
        let unwatches = requests(GoogleAPIStub.postUnwatch, from: before)
        #expect(unwatches.count == 1)
        #expect(unwatches.first?.token == FakeGoogle.access)
        // A fresh start: B's list only, its primary on, Family off again
        // (it was on for A) under a new id, and no calendar chosen for new events.
        #expect(model.calendars.map(\.calendarID) == ["other@example.test", "family-id"])
        #expect(model.chosen.map(\.calendarID) == ["other@example.test"])
        #expect(model.calendars.first { $0.calendarID == "family-id" }?.id != oldFamily)
        #expect(model.newEventsCalendarID == nil)
        #expect(try storedAccount(context)?.newEventsCalendarID == nil)
        #expect(model.newEventsCalendar?.calendarID == "other@example.test")
        #expect(model.grantedScopes == Set(GoogleOAuthConfig.scopes))
        // None of A's events is left, on Today or in the cache.
        #expect(titles(model) == ["Swim"])
        let cached = try #require(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).first)
        let snapshot = try JSONDecoder().decode(GoogleEventsSnapshot.self, from: cached.payload)
        #expect(snapshot.events.map(\.title) == ["Swim"])
        // A's token was used twice: to ask A's sign-in for its primary
        // (task 178), and to stop A's channels.
        #expect(requests(GoogleAPIStub.getCalendars, from: before).map(\.token) == [Self.accessB, FakeGoogle.access])
        #expect(stub.seen.dropFirst(before).filter { $0.token == FakeGoogle.access }.map(\.operationID)
            == [GoogleAPIStub.getCalendars, GoogleAPIStub.postUnwatch])
        // Everything else sent was for B, with B's token and B's calendars;
        // the new channels cover B's primary only.
        let sentForB = stub.seen.dropFirst(before).filter { $0.token != FakeGoogle.access }
        #expect(!sentForB.isEmpty)
        #expect(sentForB.allSatisfy { $0.token == Self.accessB })
        #expect(requests(GoogleAPIStub.postEvents, from: before).allSatisfy { $0.calendars == ["other@example.test"] })
        let watches = requests(GoogleAPIStub.postWatch, from: before)
        #expect(watches.last?.calendars == ["other@example.test"])
        #expect(model.watch.isLive)
        #expect(endpoint.sent(grant: "refresh_token").isEmpty)
    }

    @Test func theSameAccountConnectingAgainKeepsEverythingAndRevokesNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store, scope: FakeGoogle.readOnlyScopes)
        #expect(!model.canAddEvents)
        let ids = model.calendars.map(\.id)
        let on = model.calendars.map(\.isOn)
        let before = stub.seen.count

        answerAccountA(scope: FakeGoogle.allScopes, refresh: "fake-refresh-two", access: Self.accessA2)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try await idle(model)

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(model.canAddEvents)
        #expect(store.stored?.secret == "fake-refresh-two")
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.calendars.map(\.isOn) == on)
        #expect(model.newEventsCalendarID == "family-id")
        #expect(try storedAccount(context)?.newEventsCalendarID == "family-id")
        #expect(titles(model) == ["Coffee", "Dinner"])
        // Nothing revoked (it would end the new grant too) and the channels stay.
        #expect(endpoint.revoked.isEmpty)
        #expect(requests(GoogleAPIStub.postUnwatch, from: before).isEmpty)
        #expect(model.watch.isLive)
        // The list was read once, with the new token (task 178: a token
        // string of its own, so the old one would show).
        let lists = requests(GoogleAPIStub.getCalendars, from: before)
        #expect(lists.count == 1)
        #expect(lists.first?.token == Self.accessA2)
        // From then on the new token is the one used.
        await model.refresh(force: true)
        #expect(stub.seen.last { $0.operationID == GoogleAPIStub.postEvents }?.token == Self.accessA2)
    }

    @Test func anEndedSignInThatComesBackAsAnotherAccountStartsAfresh() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        try await idle(model)
        try #require(model.connection == .expired)
        // The choices stay for the same account's return.
        #expect(model.calendars.map(\.calendarID) == ["me@example.test", "family-id", "a-only-id"])
        #expect(model.newEventsCalendarID == "family-id")

        answerAccountB()
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try await idle(model)

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == Self.refreshB)
        #expect(model.calendars.map(\.calendarID) == ["other@example.test", "family-id"])
        #expect(model.chosen.map(\.calendarID) == ["other@example.test"])
        #expect(model.newEventsCalendarID == nil)
        #expect(try storedAccount(context)?.newEventsCalendarID == nil)
        #expect(titles(model) == ["Swim"])
        // The old refresh token was gone already: nothing to revoke.
        #expect(endpoint.revoked.isEmpty)
    }

    @Test func anEndedSignInThatComesBackAsTheSameAccountKeepsTheChoices() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        try await idle(model)
        try #require(model.connection == .expired)

        answerAccountA(refresh: "fake-refresh-two")
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }

        #expect(model.connection == .connected)
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.chosen.map(\.calendarID) == ["me@example.test", "family-id"])
        #expect(model.newEventsCalendarID == "family-id")
        #expect(endpoint.revoked.isEmpty)
    }

    /// The sign-in has ended (invalid_grant): A's grant is gone at Google
    /// and its refresh token is deleted, so nothing can be hurt here.
    private func expiredAsA(_ context: ModelContext, store: any GoogleTokenStore) async throws -> GoogleCalendarModel {
        let model = try await connectedAsA(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        try await idle(model)
        try #require(model.connection == .expired)
        return model
    }

    /// Task 178 (was task 175's "stays ended and hands the grant back"):
    /// after the sign-in ended, a Connect again whose list cannot be read
    /// starts afresh here and keeps the new sign-in. The old grant is gone,
    /// so there is nothing to protect, and handing the new grant back left
    /// the user unable to connect while the list could not be read. The list
    /// is read again later, as after a first Connect whose list load failed.
    @Test func anEndedSignInWhoseNewListCannotBeReadStartsAfreshAndKeepsTheNewSignIn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await expiredAsA(context, store: store)

        answerAccountB()
        stub.setOffline(true)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        stub.setOffline(false)

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(!model.isConnecting)
        #expect(store.stored?.secret == Self.refreshB)
        // A's choices and calendar for new events are gone: the account
        // could not be told.
        #expect(model.calendars.isEmpty)
        #expect(model.newEventsCalendarID == nil)
        #expect(try storedAccount(context)?.newEventsCalendarID == nil)
        #expect(model.statusProblem == .unavailable)
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)

        // The list is read again later, with the new token.
        #expect(await model.loadCalendars() == nil)
        #expect(model.calendars.map(\.calendarID) == ["other@example.test", "family-id"])
        #expect(stub.seen.last { $0.operationID == GoogleAPIStub.getCalendars }?.token == Self.accessB)
    }

    /// Task 178: our 429 on that list read is kept as a hold (its
    /// Retry-After), not ignored: the list is not asked for again before it.
    @Test func anEndedSignInWhoseNewListIsRateLimitedKeepsTheNewSignInAndTheHold() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await expiredAsA(context, store: store)

        answerAccountB()
        stub.answer(
            GoogleAPIStub.getCalendars,
            GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"),
            GoogleAPIStub.calendars(roles: [("other@example.test", "Other", true, "owner")])
        )
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == Self.refreshB)
        #expect(model.calendars.isEmpty)
        #expect(model.statusProblem == .rateLimited)
        #expect(model.retryNotBefore == clock.now.addingTimeInterval(30))
        let lists = stub.count(GoogleAPIStub.getCalendars)
        #expect(await model.loadCalendars() == 30)
        #expect(model.listHeld)
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists)

        clock.advance(30)
        #expect(await model.loadCalendars() == nil)
        #expect(model.calendars.map(\.calendarID) == ["other@example.test"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Disconnect tapped while the new sign-in's list is being read: nothing
    /// of the new sign-in is kept and it is handed back; the old one is
    /// revoked by the Disconnect itself.
    @Test func aDisconnectWhileTheNewListIsReadKeepsNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)

        answerAccountB()
        stub.hold(GoogleAPIStub.getCalendars)
        let signIn = signIn
        let connecting = Task { await model.connect(signIn: signIn) }
        await stub.waitUntilParked(GoogleAPIStub.getCalendars, count: 1)
        try await bounded { await model.disconnect() }
        stub.release(GoogleAPIStub.getCalendars)
        try await bounded { await connecting.value }

        #expect(model.connection == .notConnected)
        #expect(model.connectProblem == nil)
        #expect(!model.isConnecting)
        #expect(store.stored == nil)
        #expect(model.calendars.isEmpty)
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).isEmpty)
        #expect(Set(await endpoint.waitForRevoked(count: 2)) == [FakeGoogle.refresh, Self.refreshB])
    }

    // MARK: Task 178

    /// A's state as it was, after a Connect again that could not tell the
    /// account: nothing of the new sign-in kept, nothing revoked, A's
    /// channels not stopped.
    private func expectAUnchanged(
        _ model: GoogleCalendarModel, _ context: ModelContext, _ store: RecordingGoogleTokenStore,
        ids: [UUID], before: Int, problem: GoogleCalendarModel.ConnectProblem = .unavailable,
        pollToken: String = FakeGoogle.access, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(model.connection == .connected, sourceLocation: sourceLocation)
        #expect(model.connectProblem == problem, sourceLocation: sourceLocation)
        #expect(!model.isConnecting, sourceLocation: sourceLocation)
        #expect(store.stored?.secret == FakeGoogle.refresh, sourceLocation: sourceLocation)
        #expect(model.calendars.map(\.id) == ids, sourceLocation: sourceLocation)
        #expect(model.chosen.map(\.calendarID) == ["me@example.test", "family-id"], sourceLocation: sourceLocation)
        #expect(model.newEventsCalendarID == "family-id", sourceLocation: sourceLocation)
        #expect(try storedAccount(context)?.newEventsCalendarID == "family-id", sourceLocation: sourceLocation)
        #expect(titles(model) == ["Coffee", "Dinner"], sourceLocation: sourceLocation)
        #expect(model.watch.isLive, sourceLocation: sourceLocation)
        #expect(requests(GoogleAPIStub.postUnwatch, from: before).isEmpty, sourceLocation: sourceLocation)
        // Revoking either token would end the other grant if both were A's.
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty, sourceLocation: sourceLocation)
        // Polling goes on with A's token.
        await model.refresh(force: true)
        #expect(stub.seen.last { $0.operationID == GoogleAPIStub.postEvents }?.token == pollToken, sourceLocation: sourceLocation)
    }

    /// Item 1: a new list without a primary entry cannot tell the account.
    /// Before task 178 it was taken for another account: A was revoked,
    /// which would also end the new grant if it was A's. Trying again gets
    /// the same list, so the message says to disconnect and connect again
    /// (the user's decision, 2026-11-24).
    @Test func aNewListWithNoPrimaryCannotTellTheAccountSoAWorkingConnectionStaysAsItWas() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)
        let before = stub.seen.count

        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessB, refresh: Self.refreshB, scope: FakeGoogle.allScopes))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [("family-id", "Family", false, "owner")]))
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }

        #expect(requests(GoogleAPIStub.getCalendars, from: before).map(\.token) == [Self.accessB])
        try await expectAUnchanged(model, context, store, ids: ids, before: before, problem: .accountNotShown)
    }

    /// Item 1, after the sign-in ended: a list without a primary cannot
    /// tell the account either, and nothing can be hurt, so the new
    /// sign-in is kept and starts afresh.
    @Test func aNewListWithNoPrimaryAfterTheSignInEndedStartsAfreshAndKeepsTheNewSignIn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await expiredAsA(context, store: store)
        let oldFamily = try #require(model.calendars.first { $0.calendarID == "family-id" }).id

        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessB, refresh: Self.refreshB, scope: FakeGoogle.allScopes))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [("family-id", "Family", false, "owner")]))
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == Self.refreshB)
        #expect(model.calendars.map(\.calendarID) == ["family-id"])
        #expect(model.calendars.first?.id != oldFamily)
        #expect(model.chosen.isEmpty)
        #expect(model.newEventsCalendarID == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Item 1: the same account's primary id changed (an email rename). The
    /// old sign-in, asked with its own token, names the same new primary, so
    /// it is the same account: everything is kept, the primary's choice
    /// follows the new id, and nothing is revoked.
    @Test func aRenamedPrimaryIsTheSameAccountWhenTheOldSignInNamesItToo() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)
        let before = stub.seen.count

        let renamed = GoogleAPIStub.calendars(roles: [
            ("me.new@example.test", "Me", true, "owner"),
            ("family-id", "Family", false, "owner"),
            ("a-only-id", "Work", false, "owner"),
        ])
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessA2, refresh: "fake-refresh-two", scope: FakeGoogle.allScopes))
        stub.answer(GoogleAPIStub.getCalendars, renamed)
        stub.answer(GoogleAPIStub.getCalendars, token: FakeGoogle.access, renamed)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try await idle(model)

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == "fake-refresh-two")
        // Asked: the new sign-in, then the old one with its own token.
        #expect(requests(GoogleAPIStub.getCalendars, from: before).map(\.token) == [Self.accessA2, FakeGoogle.access])
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.calendars.map(\.calendarID) == ["me.new@example.test", "family-id", "a-only-id"])
        #expect(model.chosen.map(\.calendarID) == ["me.new@example.test", "family-id"])
        #expect(model.newEventsCalendarID == "family-id")
        #expect(titles(model) == ["Coffee", "Dinner"])
        #expect(requests(GoogleAPIStub.postUnwatch, from: before).isEmpty)
        #expect(requests(GoogleAPIStub.postWatch, from: before).last?.calendars == ["me.new@example.test", "family-id"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Item 1: another primary, and the old sign-in cannot be asked (our
    /// 429): the account cannot be told, so the working connection stays as
    /// it was, nothing is revoked, and the 429's Retry-After is kept.
    @Test func aChangedPrimaryTheOldSignInCannotConfirmLeavesTheWorkingConnectionAsItWas() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)
        let before = stub.seen.count

        answerAccountB()
        stub.answer(GoogleAPIStub.getCalendars, token: FakeGoogle.access, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }

        #expect(requests(GoogleAPIStub.getCalendars, from: before).map(\.token) == [Self.accessB, FakeGoogle.access])
        #expect(model.retryNotBefore == clock.now.addingTimeInterval(30))
        clock.advance(30)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z"), (1, "Dinner", "2026-11-19T23:00:00Z", "2026-11-20T00:00:00Z")],
            statuses: [nil, nil]
        ))
        try await expectAUnchanged(model, context, store, ids: ids, before: before)
    }

    /// Item 1: another primary, and the old sign-in has ended at Google
    /// (invalid_grant when its token is renewed to ask): nothing is left to
    /// protect, so this is a fresh Connect, and the dead token is not revoked.
    @Test func aChangedPrimaryWhoseOldSignInHasEndedStartsAfreshRevokingNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))

        answerAccountB()
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try await idle(model)

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == Self.refreshB)
        #expect(model.calendars.map(\.calendarID) == ["other@example.test", "family-id"])
        #expect(model.chosen.map(\.calendarID) == ["other@example.test"])
        #expect(model.newEventsCalendarID == nil)
        #expect(titles(model) == ["Swim"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Item 3: A's events request is out when the account switches to B,
    /// and comes back 401. It is not renewed and sent again: that would drop
    /// B's access token, renew it with B's refresh token, and send A's
    /// calendar ids with B's token.
    @Test func aStale401ForTheOldAccountIsNotRetriedWithTheNewToken() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        stub.hold(GoogleAPIStub.postEvents)
        let polling = Task { await model.refresh(force: true) }
        await stub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)

        answerAccountB()
        stub.answer(
            GoogleAPIStub.postEvents,
            GoogleAPIStub.error(.unauthorized, "google_auth"),
            GoogleAPIStub.events([(0, "Swim", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil])
        )
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try #require(store.stored?.secret == Self.refreshB)
        let before = stub.seen.count

        stub.release(GoogleAPIStub.postEvents)
        try await bounded { await polling.value }
        try await idle(model)

        #expect(endpoint.sent(grant: "refresh_token").isEmpty)
        #expect(requests(GoogleAPIStub.postEvents, from: before).isEmpty)
        #expect(model.statusProblem == nil)
        // B's token is still the one in use.
        await model.refresh(force: true)
        let last = try #require(stub.seen.last { $0.operationID == GoogleAPIStub.postEvents })
        #expect(last.token == Self.accessB)
        #expect(last.calendars == ["other@example.test"])
        #expect(titles(model) == ["Swim"])
    }

    /// Item 3, the add path: a 401 for an event sent for A that lands after
    /// the switch is not sent again with B's token; it is reported as
    /// sign-in trouble (nothing was added).
    @Test func aStale401ForAnEventSentForTheOldAccountIsNotRetriedWithTheNewToken() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.error(.unauthorized, "google_auth"), GoogleAPIStub.created(id: "x"))
        stub.hold(GoogleAPIStub.postCreate)
        let event = GoogleNewEvent(
            calendarID: "family-id", id: GoogleNewEvent.makeID(), title: "Tea",
            timezone: "America/Chicago", timing: .allDay(date: "2026-11-20")
        )
        let adding = Task { await model.createEvent(event) }
        await stub.waitUntilParked(GoogleAPIStub.postCreate, count: 1)

        answerAccountB()
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        let before = stub.seen.count

        stub.release(GoogleAPIStub.postCreate)
        let outcome = try await bounded { await adding.value }

        #expect(outcome == .failed(.signInTrouble))
        #expect(endpoint.sent(grant: "refresh_token").isEmpty)
        #expect(requests(GoogleAPIStub.postCreate, from: before).isEmpty)
        #expect(model.canAddEvents)
    }

    /// Item 3, the watch keeper: A's watch is out when the account switches
    /// (the switch's unwatch outlasts `unwatchWait` behind it) and comes back
    /// 401. It is not renewed and sent again with B's token.
    @Test func aStale401ForTheOldAccountsWatchIsNotRetriedWithTheNewToken() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store, unwatchWait: .milliseconds(200))
        stub.hold(GoogleAPIStub.postWatch)
        model.setOn(try #require(model.calendars.first { $0.calendarID == "a-only-id" }), true)
        await stub.waitUntilParked(GoogleAPIStub.postWatch, count: 1)

        answerAccountB()
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.unauthorized, "google_auth"), GoogleAPIStub.watch([nil], expiresAt: weekLater))
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try #require(store.stored?.secret == Self.refreshB)
        let before = stub.seen.count

        stub.release(GoogleAPIStub.postWatch)
        try await idle(model)

        #expect(endpoint.sent(grant: "refresh_token").isEmpty)
        let watches = requests(GoogleAPIStub.postWatch, from: before)
        #expect(!watches.isEmpty)
        #expect(watches.allSatisfy { $0.token == Self.accessB && $0.calendars == ["other@example.test"] })
        #expect(model.watch.isLive)
    }

    /// Item 4: Disconnect while a Connect exchanges its code, then a second
    /// Connect into the same account at once. The first Connect's hand-back
    /// revoke is not sent once the second has begun: Google's revoke ends
    /// the account's whole grant, the second one's included.
    @Test func aHandBackAfterDisconnectIsNotSentOnceANewerConnectHasBegun() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        answerAccountA()
        endpoint.answer(
            "authorization_code",
            FakeGoogleEndpoint.tokens(access: FakeGoogle.access, refresh: "fake-refresh-one", scope: FakeGoogle.allScopes),
            FakeGoogleEndpoint.tokens(access: Self.accessA2, refresh: "fake-refresh-two", scope: FakeGoogle.allScopes)
        )
        let model = model(context, store: store)
        let signIn = signIn
        let endpoint = endpoint
        endpoint.hold(grant: "authorization_code")
        let first = Task { await model.connect(signIn: signIn) }
        await endpoint.waitForSent(grant: "authorization_code", count: 1)
        try await bounded { await model.disconnect() }
        #expect(!model.isConnecting)

        let second = Task {
            await model.connect(signIn: { url, scheme in
                // The first Connect's exchange ends while this sheet is up.
                endpoint.release()
                await first.value
                return try await signIn(url, scheme)
            })
        }
        try await bounded { await second.value }

        #expect(model.connection == .connected)
        #expect(store.stored?.secret == "fake-refresh-two")
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Item 4, Disconnect's own revoke: it waits for the unwatch, and a
    /// Connect into the same account made meanwhile is not ended by it.
    @Test func aDisconnectsRevokeIsNotSentOnceANewerConnectHasBegun() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        stub.hold(GoogleAPIStub.postUnwatch)
        let disconnecting = Task { await model.disconnect() }
        await stub.waitUntilParked(GoogleAPIStub.postUnwatch, count: 1)
        #expect(model.connection == .notConnected)

        answerAccountA(refresh: "fake-refresh-two", access: Self.accessA2)
        let stub = stub
        let signIn = signIn
        let connecting = Task {
            await model.connect(signIn: { url, scheme in
                // Disconnect's unwatch, then its revoke, end while this sheet is up.
                stub.release(GoogleAPIStub.postUnwatch)
                await disconnecting.value
                return try await signIn(url, scheme)
            })
        }
        try await bounded { await connecting.value }

        #expect(model.connection == .connected)
        #expect(store.stored?.secret == "fake-refresh-two")
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Item 5: Disconnect tapped while a switch is stopping A's channels.
    /// A is revoked once (by the switch), B is handed back, nothing is kept.
    @Test func aDisconnectWhileTheSwitchStopsTheOldChannelsKeepsNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)

        answerAccountB()
        stub.hold(GoogleAPIStub.postUnwatch)
        let signIn = signIn
        let connecting = Task { await model.connect(signIn: signIn) }
        await stub.waitUntilParked(GoogleAPIStub.postUnwatch, count: 1)
        try await bounded { await model.disconnect() }
        stub.release(GoogleAPIStub.postUnwatch)
        try await bounded { await connecting.value }
        try await idle(model)

        #expect(model.connection == .notConnected)
        #expect(model.connectProblem == nil)
        #expect(!model.isConnecting)
        #expect(store.stored == nil)
        #expect(model.calendars.isEmpty)
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).isEmpty)
        #expect(!model.watch.isLive)
        let revoked = await endpoint.waitForRevoked(count: 2)
        #expect(revoked.count == 2)
        #expect(Set(revoked) == [FakeGoogle.refresh, Self.refreshB])
    }

    /// Item 5: the switch's unwatch outlasts `unwatchWait`. A is revoked
    /// and B saved while it is still out (A before B), and B's watch goes
    /// out after it, with B's token.
    @Test func aSwitchWhoseUnwatchOutlastsTheWaitRevokesAThenKeepsB() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store, unwatchWait: .milliseconds(200))
        let atSave = RevokedAtSave()
        let endpoint = endpoint
        store.onSave { _ in atSave.append(endpoint.revoked) }

        answerAccountB()
        stub.hold(GoogleAPIStub.postUnwatch)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }

        #expect(model.connection == .connected)
        #expect(store.stored?.secret == Self.refreshB)
        #expect(atSave.all == [[FakeGoogle.refresh]])
        // A's unwatch is still out (held) with B connected.
        await stub.waitUntilParked(GoogleAPIStub.postUnwatch, count: 1)
        #expect(stub.count(GoogleAPIStub.postUnwatch) == 1)
        #expect(!model.watch.isLive)
        let before = stub.seen.count

        stub.release(GoogleAPIStub.postUnwatch)
        try await idle(model)

        let unwatches = stub.seen.filter { $0.operationID == GoogleAPIStub.postUnwatch }
        #expect(unwatches.last?.token == FakeGoogle.access)
        let watches = requests(GoogleAPIStub.postWatch, from: before)
        #expect(watches.count == 1)
        #expect(watches.first?.token == Self.accessB)
        #expect(watches.first?.calendars == ["other@example.test"])
        #expect(model.watch.isLive)
        #expect(titles(model) == ["Swim"])
    }

    // MARK: Task 178, after review

    /// Finding 1, the guard after the exchange: a poll meets invalid_grant
    /// while the Connect again's code is exchanged. That is not a
    /// Disconnect: the Connect goes on as after the sign-in ended, and the
    /// grant the user just made is kept (before, it was handed back).
    @Test func aSignInThatEndsDuringTheExchangeKeepsTheNewSignIn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)

        answerAccountA(refresh: "fake-refresh-two", access: Self.accessA2)
        // The new token outlives the clock moved below (its life counts from when it was asked for).
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessA2, refresh: "fake-refresh-two", expiresIn: 7200))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        endpoint.hold(grant: "authorization_code")
        let signIn = signIn
        let connecting = Task { await model.connect(signIn: signIn) }
        await endpoint.waitForSent(grant: "authorization_code", count: 1)
        clock.advance(3600)
        await model.refresh()
        try #require(model.connection == .expired)
        endpoint.release()
        try await bounded { await connecting.value }

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(!model.isConnecting)
        #expect(store.stored?.secret == "fake-refresh-two")
        // The same account: its choices and calendar for new events stay.
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.chosen.map(\.calendarID) == ["me@example.test", "family-id"])
        #expect(model.newEventsCalendarID == "family-id")
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Finding 1, the guard after the new list is read: the sign-in ends
    /// while the list is out. The Connect goes on as after it ended.
    @Test func aSignInThatEndsWhileTheNewListIsReadKeepsTheNewSignIn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)

        answerAccountA(refresh: "fake-refresh-two", access: Self.accessA2)
        // The new token outlives the clock moved below (its life counts from when it was asked for).
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessA2, refresh: "fake-refresh-two", expiresIn: 7200))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        stub.hold(GoogleAPIStub.getCalendars)
        let signIn = signIn
        let connecting = Task { await model.connect(signIn: signIn) }
        await stub.waitUntilParked(GoogleAPIStub.getCalendars, count: 1)
        clock.advance(3600)
        await model.refresh()
        try #require(model.connection == .expired)
        stub.release(GoogleAPIStub.getCalendars)
        try await bounded { await connecting.value }

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == "fake-refresh-two")
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.newEventsCalendarID == "family-id")
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Finding 1, while the old sign-in is asked for its primary: it ends
    /// (invalid_grant) meanwhile. The answer is decided again as after it
    /// ended (another primary: a fresh start), whichever came first, and
    /// the new grant is kept.
    @Test func aSignInThatEndsWhileTheOldSignInIsAskedGoesOnAsAfterItEnded() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)

        answerAccountB()
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessB, refresh: Self.refreshB, expiresIn: 7200))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        stub.hold(GoogleAPIStub.getCalendars)
        let signIn = signIn
        let connecting = Task { await model.connect(signIn: signIn) }
        await stub.waitUntilParked(GoogleAPIStub.getCalendars, count: 1)
        stub.releaseOldest(GoogleAPIStub.getCalendars)
        await stub.waitUntilParked(GoogleAPIStub.getCalendars, count: 1)
        #expect(stub.seen.last { $0.operationID == GoogleAPIStub.getCalendars }?.token == FakeGoogle.access)
        clock.advance(3600)
        await model.refresh()
        try #require(model.connection == .expired)
        stub.release(GoogleAPIStub.getCalendars)
        try await bounded { await connecting.value }
        try await idle(model)

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == Self.refreshB)
        #expect(model.calendars.map(\.calendarID) == ["other@example.test", "family-id"])
        #expect(model.chosen.map(\.calendarID) == ["other@example.test"])
        #expect(model.newEventsCalendarID == nil)
        #expect(titles(model) == ["Swim"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Finding 3: a Connect again inside our own 429's Retry-After does not
    /// read the list again (it would meet the same 429): it ends as that
    /// 429 does, the hold unchanged, nothing kept or revoked. Since task 214
    /// a hold already on when Connect is tapped stops it before the sheet
    /// (`aConnectAgainInsideOurOwn429HoldDoesNotOpenTheSheet`), so here the
    /// hold begins while the sheet is up: a poll meets our 429 then.
    @Test func aConnectAgainInsideOurOwn429HoldDoesNotAskAgain() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)

        answerAccountB()
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try #require(model.connectProblem == .unavailable)
        let firstHold = try #require(model.retryNotBefore)
        #expect(firstHold == clock.now.addingTimeInterval(30))

        clock.advance(30)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        let before = stub.seen.count
        try await bounded {
            await model.connect { url, scheme in
                await model.refresh(force: true)
                return try await signIn(url, scheme)
            }
        }
        let hold = try #require(model.retryNotBefore)
        try #require(hold == clock.now.addingTimeInterval(30))
        try #require(model.statusProblem == .rateLimited)

        #expect(requests(GoogleAPIStub.getCalendars, from: before).isEmpty)
        #expect(model.retryNotBefore == hold)
        clock.advance(30)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z"), (1, "Dinner", "2026-11-19T23:00:00Z", "2026-11-20T00:00:00Z")],
            statuses: [nil, nil]
        ))
        try await expectAUnchanged(model, context, store, ids: ids, before: before)
    }

    enum OldSignInFailure: String, CaseIterable, Sendable {
        case offline, forbidden, keychain, repeated401
    }

    /// Finding 4: every failure of the old sign-in's list read cannot tell
    /// the account: the working connection is kept, nothing is revoked, and
    /// the message is the passing one. (A sign-in change during that read is
    /// a Disconnect, handed back, or the sign-in ending, which goes on as
    /// after it ended: see the tests above.)
    @Test(arguments: OldSignInFailure.allCases)
    func everyFailureToAskTheOldSignInCannotTell(_ failure: OldSignInFailure) async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)
        let before = stub.seen.count
        var pollToken = FakeGoogle.access

        answerAccountB()
        let signIn = signIn
        switch failure {
        case .offline:
            stub.hold(GoogleAPIStub.getCalendars)
            let connecting = Task { await model.connect(signIn: signIn) }
            await stub.waitUntilParked(GoogleAPIStub.getCalendars, count: 1)
            stub.releaseOldest(GoogleAPIStub.getCalendars)
            await stub.waitUntilParked(GoogleAPIStub.getCalendars, count: 1)
            stub.setOffline(true)
            stub.release(GoogleAPIStub.getCalendars)
            try await bounded { await connecting.value }
            stub.setOffline(false)
        case .forbidden:
            stub.answer(GoogleAPIStub.getCalendars, token: FakeGoogle.access, GoogleAPIStub.error(.forbidden, "google_forbidden"))
            try await bounded { await model.connect(signIn: signIn) }
        case .keychain:
            // A's token needs renewing (under the margin), and the Keychain is locked.
            clock.advance(3500)
            store.setFailure(KeychainFailure(status: errSecInteractionNotAllowed))
            try await bounded { await model.connect(signIn: signIn) }
            store.setFailure(nil)
            pollToken = FakeGoogle.access2
        case .repeated401:
            stub.answer(GoogleAPIStub.getCalendars, token: FakeGoogle.access, GoogleAPIStub.error(.unauthorized, "google_auth"))
            stub.answer(GoogleAPIStub.getCalendars, token: FakeGoogle.access2, GoogleAPIStub.error(.unauthorized, "google_auth"))
            try await bounded { await model.connect(signIn: signIn) }
            pollToken = FakeGoogle.access2
        }

        #expect(requests(GoogleAPIStub.getCalendars, from: before).first?.token == Self.accessB)
        if failure != .keychain {
            #expect(requests(GoogleAPIStub.getCalendars, from: before).dropFirst().allSatisfy { $0.token != Self.accessB })
        }
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z"), (1, "Dinner", "2026-11-19T23:00:00Z", "2026-11-20T00:00:00Z")],
            statuses: [nil, nil]
        ))
        try await expectAUnchanged(model, context, store, ids: ids, before: before, pollToken: pollToken)
    }

    /// A list with no primary calendar: Family and Work only.
    private func answerNoPrimary(_ tokens: [String]) {
        let list = GoogleAPIStub.calendars(roles: [
            ("family-id", "Family", false, "owner"),
            ("a-only-id", "Work", false, "owner"),
        ])
        stub.answer(GoogleAPIStub.getCalendars, list)
        for token in tokens { stub.answer(GoogleAPIStub.getCalendars, token: token, list) }
    }

    /// No primary known on the phone because the list was never read (the
    /// first Connect's load failed): the old sign-in is asked, names the
    /// same primary as the new one, and everything is kept.
    @Test func noPrimaryKnownBecauseTheListWasNeverReadAsksTheOldSignIn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        answerAccountA()
        let model = model(context, store: store)
        let signIn = signIn
        stub.setOffline(true)
        try await bounded { await model.connect(signIn: signIn) }
        stub.setOffline(false)
        try #require(model.connection == .connected)
        try #require(model.calendars.isEmpty)
        let before = stub.seen.count

        answerAccountA(refresh: "fake-refresh-two", access: Self.accessA2)
        try await bounded { await model.connect(signIn: signIn) }

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == "fake-refresh-two")
        #expect(requests(GoogleAPIStub.getCalendars, from: before).map(\.token) == [Self.accessA2, FakeGoogle.access])
        #expect(model.calendars.map(\.calendarID) == ["me@example.test", "family-id", "a-only-id"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// No primary known because the account's list names none: from a
    /// working connection the account cannot be told, whether the new list
    /// names none either or only the old sign-in's does. Nothing changes,
    /// nothing is revoked, and the message says to disconnect and connect
    /// again (retrying gets the same list).
    @Test func noPrimaryKnownBecauseTheListNamesNoneCannotTellFromAWorkingConnection() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        answerAccountA()
        answerNoPrimary([FakeGoogle.access, FakeGoogle.access2])
        let model = model(context, store: store)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try #require(model.connection == .connected)
        let ids = model.calendars.map(\.id)
        try #require(model.calendars.map(\.calendarID) == ["family-id", "a-only-id"])

        func expectUnchanged(_ comment: Comment) {
            #expect(model.connection == .connected, comment)
            #expect(model.connectProblem == .accountNotShown, comment)
            #expect(store.stored?.secret == FakeGoogle.refresh, comment)
            #expect(model.calendars.map(\.id) == ids, comment)
        }

        // The new list names no primary either.
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessB, refresh: Self.refreshB, scope: FakeGoogle.allScopes))
        var before = stub.seen.count
        try await bounded { await model.connect(signIn: signIn) }
        expectUnchanged("no primary on either list")
        #expect(requests(GoogleAPIStub.getCalendars, from: before).map(\.token) == [Self.accessB])

        // The new list names one; the old sign-in's still does not.
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [("other@example.test", "Other", true, "owner")]))
        before = stub.seen.count
        try await bounded { await model.connect(signIn: signIn) }
        expectUnchanged("no primary on the old sign-in's list")
        #expect(requests(GoogleAPIStub.getCalendars, from: before).map(\.token) == [Self.accessB, FakeGoogle.access])

        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// No primary known, after the sign-in ended: nothing can be hurt, so
    /// the new sign-in is kept and starts afresh (the choices are new).
    @Test func noPrimaryKnownAfterTheSignInEndedStartsAfresh() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        answerAccountA()
        answerNoPrimary([FakeGoogle.access, FakeGoogle.access2])
        let model = model(context, store: store)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        let ids = model.calendars.map(\.id)
        try #require(ids.count == 2)
        // A calendar on, so the poll renews the token and meets invalid_grant.
        model.setOn(try #require(model.calendars.first), true)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh(force: true)
        try await idle(model)
        try #require(model.connection == .expired)

        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessA2, refresh: "fake-refresh-two", scope: FakeGoogle.allScopes))
        try await bounded { await model.connect(signIn: signIn) }

        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == "fake-refresh-two")
        #expect(model.calendars.map(\.calendarID) == ["family-id", "a-only-id"])
        #expect(Set(model.calendars.map(\.id)).isDisjoint(with: ids))
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// The user's decision (2026-11-24): a lasting cause says to disconnect
    /// and connect again; a passing one says to try again.
    @Test func aConnectAgainThatCannotTellTheAccountSaysToDisconnectAndConnectAgain() {
        typealias Problem = GoogleCalendarModel.ConnectProblem
        #expect(Problem.accountNotShown.message
            == "Google didn't show which account you signed in with, so nothing changed. To add events, disconnect and connect again.")
        #expect(Problem.unavailable.message == "We couldn't reach Google. Check your connection and try again.")
    }

    // MARK: Task 214

    /// Item 1: Connect again from a working connection inside our own 429's
    /// Retry-After does not open Google's sheet and sends nothing (the list
    /// read it needs would meet the same 429; before, the user went through
    /// the whole sheet to be told Google couldn't be reached). Settings says
    /// Seasign is busy. Once the hold has passed, the sheet opens as usual.
    @Test func aConnectAgainInsideOurOwn429HoldDoesNotOpenTheSheet() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)
        // A poll meets our 429.
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        await model.refresh(force: true)
        let hold = try #require(model.retryNotBefore)
        try #require(hold == clock.now.addingTimeInterval(30))
        try #require(model.statusProblem == .rateLimited)

        answerAccountA(refresh: "fake-refresh-two", access: Self.accessA2)
        clock.advance(10)
        let before = stub.seen.count
        let codes = endpoint.sent(grant: "authorization_code").count
        let sheets = SheetsOpened()
        let signIn = signIn
        try await bounded {
            await model.connect { url, scheme in
                sheets.count += 1
                return try await signIn(url, scheme)
            }
        }

        #expect(sheets.count == 0)
        #expect(model.connectProblem == .busy)
        #expect(!model.isConnecting)
        #expect(endpoint.sent(grant: "authorization_code").count == codes)
        #expect(stub.seen.count == before)
        #expect(model.retryNotBefore == hold)
        #expect(model.connection == .connected)
        #expect(store.stored?.secret == FakeGoogle.refresh)
        #expect(model.calendars.map(\.id) == ids)
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)

        // The hold has passed: the sheet opens, and the same account is kept.
        clock.advance(20)
        try await bounded {
            await model.connect { url, scheme in
                sheets.count += 1
                return try await signIn(url, scheme)
            }
        }
        #expect(sheets.count == 1)
        #expect(model.connectProblem == nil)
        #expect(store.stored?.secret == "fake-refresh-two")
        #expect(model.calendars.map(\.id) == ids)
    }

    /// Item 2: a Connect problem's note does not outlive the sign-in. When
    /// the sign-in ends, Settings shows the ended state and "Connect again";
    /// a note left from before (here "disconnect and connect again") no
    /// longer applies.
    @Test func aConnectProblemIsClearedWhenTheSignInEnds() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)

        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: Self.accessB, refresh: Self.refreshB, scope: FakeGoogle.allScopes))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [("family-id", "Family", false, "owner")]))
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        try #require(model.connectProblem == .accountNotShown)
        try #require(model.connection == .connected)

        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        try await idle(model)
        try #require(model.connection == .expired)

        #expect(model.connectProblem == nil)
    }

    /// Item 3: the sign-in here ends (a poll meets invalid_grant) while
    /// Google's sheet is up. That is not a Disconnect: the sheet's sign-in
    /// is exchanged and kept, as a Connect after the sign-in ended, and the
    /// same account keeps its choices. Before, it was dropped unexchanged and
    /// the user was left with the ended sign-in.
    @Test func aSignInThatEndsWhileTheSheetIsUpKeepsTheSheetsSignIn() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)

        answerAccountA(refresh: "fake-refresh-two", access: Self.accessA2)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        let sheets = SheetsOpened()
        let clock = clock
        let signIn = signIn
        try await bounded {
            await model.connect { url, scheme in
                clock.advance(3600)
                await model.refresh()
                sheets.connectionWhileUp = model.connection
                return try await signIn(url, scheme)
            }
        }

        #expect(sheets.connectionWhileUp == .expired)
        #expect(model.connection == .connected)
        #expect(model.connectProblem == nil)
        #expect(!model.isConnecting)
        #expect(store.stored?.secret == "fake-refresh-two")
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.chosen.map(\.calendarID) == ["me@example.test", "family-id"])
        #expect(model.newEventsCalendarID == "family-id")
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked.isEmpty)
    }

    /// Item 3's limit: a Disconnect while the sheet is up still keeps
    /// nothing. The sheet's code is not even exchanged, so there is no new
    /// grant to hand back; the Disconnect revokes the old sign-in itself.
    @Test func aDisconnectWhileTheSheetIsUpKeepsNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)

        answerAccountA(refresh: "fake-refresh-two", access: Self.accessA2)
        let codes = endpoint.sent(grant: "authorization_code").count
        let signIn = signIn
        try await bounded {
            await model.connect { url, scheme in
                await model.disconnect()
                return try await signIn(url, scheme)
            }
        }

        #expect(model.connection == .notConnected)
        #expect(model.connectProblem == nil)
        #expect(!model.isConnecting)
        #expect(store.stored == nil)
        #expect(model.calendars.isEmpty)
        #expect(endpoint.sent(grant: "authorization_code").count == codes)
        #expect(await endpoint.waitForRevoked(count: 1) == [FakeGoogle.refresh])
        try await Task.sleep(for: .milliseconds(100))
        #expect(endpoint.revoked == [FakeGoogle.refresh])
    }

    @Test func theBusyNoteSaysSeasignIsBusyAndToTryAgainInAMoment() {
        #expect(GoogleCalendarModel.ConnectProblem.busy.message
            == "Seasign is busy right now, so nothing changed. Try again in a moment.")
    }

    /// Item 4: the DEBUG launch argument `-debugGoogleConnectProblem <case>`
    /// sets that problem on the frozen sample only.
    @Test func theDebugSampleShowsTheConnectProblemItIsGiven() throws {
        typealias Problem = GoogleCalendarModel.ConnectProblem
        #expect(try GoogleCalendarModel.sample().connectProblem == nil)
        let sample = try GoogleCalendarModel.sample(readOnly: true, connectProblem: .debugNamed("accountNotShown"))
        #expect(sample.connectProblem == .accountNotShown)
        #expect(Problem.debugNamed("busy") == .busy)
        #expect(Problem.debugNamed("unavailable") == .unavailable)
        #expect(Problem.debugNamed(nil) == nil)
        #expect(Problem.debugNamed("YES") == nil)
    }
}

/// What a test's sign-in sheet saw.
@MainActor final class SheetsOpened {
    var count = 0
    var connectionWhileUp: GoogleConnection?
}
