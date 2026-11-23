import Foundation
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

    private func model(_ context: ModelContext, store: any GoogleTokenStore) -> GoogleCalendarModel {
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
            unwatchWait: .seconds(5)
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
    private func answerAccountA(scope: String = FakeGoogle.allScopes, refresh: String = FakeGoogle.refresh) {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(access: FakeGoogle.access, refresh: refresh, scope: scope))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil, scope: scope))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [
            ("me@example.test", "Me", true, "owner"),
            ("family-id", "Family", false, "owner"),
            ("a-only-id", "Work", false, "owner"),
        ]))
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
    private func connectedAsA(_ context: ModelContext, store: any GoogleTokenStore, scope: String = FakeGoogle.allScopes) async throws -> GoogleCalendarModel {
        answerAccountA(scope: scope)
        let model = model(context, store: store)
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
        // Everything sent for B used B's token and B's calendars; the new
        // channels cover B's primary only.
        let sentForB = stub.seen.dropFirst(before).filter { $0.operationID != GoogleAPIStub.postUnwatch }
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

        answerAccountA(scope: FakeGoogle.allScopes, refresh: "fake-refresh-two")
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
        // The list was read once, with the new token.
        let lists = requests(GoogleAPIStub.getCalendars, from: before)
        #expect(lists.count == 1)
        #expect(lists.first?.token == FakeGoogle.access)
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

    /// After the sign-in ended, a Connect again whose list cannot be read
    /// keeps nothing: the account cannot be told, so it stays expired and the
    /// new grant is handed back (the old one is dead already). Before task
    /// 175 this connected and read the list later.
    @Test func anEndedSignInWhoseNewListCannotBeReadStaysEndedAndHandsTheGrantBack() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = RecordingGoogleTokenStore()
        let model = try await connectedAsA(context, store: store)
        let ids = model.calendars.map(\.id)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        try await idle(model)
        try #require(model.connection == .expired)

        answerAccountB()
        stub.setOffline(true)
        let signIn = signIn
        try await bounded { await model.connect(signIn: signIn) }
        stub.setOffline(false)

        #expect(model.connection == .expired)
        #expect(model.connectProblem == .unavailable)
        #expect(!model.isConnecting)
        #expect(store.stored == nil)
        #expect(model.calendars.map(\.id) == ids)
        #expect(model.newEventsCalendarID == "family-id")
        #expect(await endpoint.waitForRevoked(count: 1) == [Self.refreshB])
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
}
