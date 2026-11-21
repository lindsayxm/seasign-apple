import Foundation
import SwiftData
import Testing

@testable import Seasign

/// A made-up device token: 32 bytes, 0x00 to 0x1f, so its hex is known.
enum FakeDevice {
    static let token = APNsDeviceToken(Data(0..<32))
    static let hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    static let other = APNsDeviceToken(Data((0..<32).map { UInt8(255 - $0) }))
}

// MARK: - Pieces

@Suite struct GooglePushPiecesTests {
    @Test func theDeviceTokenIsLowercaseHexAndNeverPrints() {
        #expect(FakeDevice.token.hex == FakeDevice.hex)
        #expect(APNsDeviceToken(Data([0xAB, 0xCD])).hex == "abcd")
        #expect("\(FakeDevice.token)" == "<redacted>")
        #expect(String(reflecting: FakeDevice.token) == "<redacted>")
        var dumped = ""
        dump(FakeDevice.token, to: &dumped)
        #expect(!dumped.contains(FakeDevice.hex))
    }

    @Test func debugBuildsUseTheSandbox() {
        // The tests run a Debug build; Release builds say production.
        #expect(APNsEnvironment.current == .sandbox)
    }

    @Test func theFingerprintIgnoresOrderAndHoldsNoTokenOrCalendar() {
        let a = GoogleWatchKeeper.fingerprint(calendars: ["me@example.test", "family-id"], device: FakeDevice.token, environment: .sandbox)
        let b = GoogleWatchKeeper.fingerprint(calendars: ["family-id", "me@example.test"], device: FakeDevice.token, environment: .sandbox)
        #expect(a == b)
        #expect(a != GoogleWatchKeeper.fingerprint(calendars: ["me@example.test"], device: FakeDevice.token, environment: .sandbox))
        #expect(a != GoogleWatchKeeper.fingerprint(calendars: ["me@example.test", "family-id"], device: FakeDevice.other, environment: .sandbox))
        #expect(a != GoogleWatchKeeper.fingerprint(calendars: ["me@example.test", "family-id"], device: FakeDevice.token, environment: .production))
        #expect(!a.contains(FakeDevice.hex) && !a.contains("example"))
    }

    @Test func thePollSlowsToOnceAMinuteOnlyWithALiveChannel() {
        #expect(GooglePoll.interval(channelLive: false) == .seconds(5))
        #expect(GooglePoll.interval(channelLive: true) == .seconds(60))
        #expect(GooglePoll.intervalWithPush == .seconds(60))
    }

    @Test func theAppAsksForBackgroundPushesButNoPermission() throws {
        let modes = try #require(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        #expect(modes == ["remote-notification"])
    }

    @Test func outcomesMapToFetchResults() {
        #expect(GooglePushOutcome.newData.fetchResult == .newData)
        #expect(GooglePushOutcome.noData.fetchResult == .noData)
        #expect(GooglePushOutcome.failed.fetchResult == .failed)
    }
}

// MARK: - The relay

@MainActor
final class FakeReceiver: RemotePushReceiver {
    var launches = 0
    var tokens: [APNsDeviceToken] = []
    var failures = 0
    var pushes: [String?] = []

    func launched() { launches += 1 }
    func registered(_ token: APNsDeviceToken) { tokens.append(token) }
    func registrationFailed() { failures += 1 }
    func received(type: String?) async -> GooglePushOutcome {
        pushes.append(type)
        return .newData
    }
}

@Suite @MainActor struct RemotePushRelayTests {
    @Test func aLaunchAndATokenBeforeTheReceiverArePassedOnWhenItIsAttached() async {
        let relay = RemotePushRelay()
        relay.launched()
        relay.registered(FakeDevice.token)
        #expect(await relay.received(type: "calendar-changed") == .noData)
        let receiver = FakeReceiver()
        relay.attach(receiver)
        #expect(receiver.launches == 1)
        #expect(receiver.tokens == [FakeDevice.token])
        relay.registered(FakeDevice.other)
        relay.registrationFailed()
        #expect(receiver.tokens == [FakeDevice.token, FakeDevice.other])
        #expect(receiver.failures == 1)
        #expect(await relay.received(type: "calendar-changed") == .newData)
        #expect(receiver.pushes == ["calendar-changed"])
    }
}

// MARK: - Watch, unwatch and pushes through the model

@Suite @MainActor struct GooglePushModelTests {
    private let endpoint = FakeGoogleEndpoint()
    private let stub = GoogleAPIStub()
    private let clock = TestClock(instant("2026-11-19T18:00:00Z"))
    private let zone = TimeZone(identifier: "America/Chicago")!
    /// Seven days after the clock's start: a fresh channel.
    private let weekLater = "2026-11-26T18:00:00Z"

    private final class Counter {
        var value = 0
    }

    private func model(
        _ context: ModelContext,
        store: InMemoryGoogleTokenStore,
        environment: APNsEnvironment = .sandbox,
        pushDeadline: Duration = .seconds(5),
        registrations: Counter? = nil
    ) -> GoogleCalendarModel {
        let clock = clock
        let zone = zone
        let model = GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub),
            context: context,
            config: FakeGoogle.config,
            tokens: store,
            http: endpoint.http,
            timeZone: { zone },
            now: { clock.now },
            environment: environment,
            sleep: { seconds in clock.advance(seconds) },
            pushWindow: .milliseconds(50),
            pushDeadline: pushDeadline
        )
        if let registrations {
            model.watch.register = { registrations.value += 1 }
        }
        return model
    }

    private func redirect() -> @MainActor (URL, String) async throws -> URL {
        { url, scheme in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?state=\(state)&code=\(FakeGoogle.code)")!
        }
    }

    private func connected(
        _ context: ModelContext,
        store: InMemoryGoogleTokenStore = InMemoryGoogleTokenStore(),
        environment: APNsEnvironment = .sandbox,
        pushDeadline: Duration = .seconds(5),
        registrations: Counter? = nil
    ) async -> GoogleCalendarModel {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("me@example.test", "Me", true), ("family-id", "Family", false)]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil]
        ))
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: weekLater))
        stub.answer(GoogleAPIStub.postUnwatch, GoogleAPIStub.unwatched(1))
        let model = model(context, store: store, environment: environment, pushDeadline: pushDeadline, registrations: registrations)
        await model.connect(signIn: redirect())
        return model
    }

    /// A connected model that has its device token and one live channel for "Me".
    private func watching(_ context: ModelContext, store: InMemoryGoogleTokenStore = InMemoryGoogleTokenStore()) async throws -> GoogleCalendarModel {
        let model = await connected(context, store: store)
        model.registered(FakeDevice.token)
        await model.watch.idle()
        try #require(stub.count(GoogleAPIStub.postWatch) == 1)
        try #require(model.watch.isLive)
        return model
    }

    private var watches: [GoogleAPIStub.Seen] {
        stub.seen.filter { $0.operationID == GoogleAPIStub.postWatch }
    }

    private var unwatches: [GoogleAPIStub.Seen] {
        stub.seen.filter { $0.operationID == GoogleAPIStub.postUnwatch }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func titles(_ model: GoogleCalendarModel) -> [String] {
        model.upcoming(now: clock.now).map(\.title)
    }

    // MARK: Registration

    @Test func connectingAsksForADeviceTokenAndTheTokenSendsTheChosenCalendars() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let registrations = Counter()
        let model = await connected(context, registrations: registrations)
        #expect(registrations.value == 1)
        #expect(watches.isEmpty)  // no device token yet

        model.registered(FakeDevice.token)
        await model.watch.idle()
        let sent = try #require(watches.first)
        #expect(watches.count == 1)
        #expect(sent.calendars == ["me@example.test"])
        #expect(sent.deviceToken == FakeDevice.hex)
        #expect(sent.environment == "sandbox")
        #expect(sent.token == FakeGoogle.access)
        #expect(model.watch.isLive)
        #expect(model.watch.expiresAt == instant(weekLater))
        #expect(model.watch.problem == nil)
    }

    @Test func releaseBuildsSayProduction() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, environment: .production)
        model.registered(FakeDevice.token)
        await model.watch.idle()
        #expect(watches.first?.environment == "production")
    }

    @Test func atLaunchItAsksForATokenOnlyWhenGoogleIsConnected() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let notConnected = Counter()
        model(context, store: store, registrations: notConnected).launched()
        #expect(notConnected.value == 0)

        _ = await connected(context, store: store)
        let relaunch = Counter()
        let relaunched = model(context, store: store, registrations: relaunch)
        relaunched.launched()
        relaunched.appOpened()
        #expect(relaunch.value == 1)
        // A failed registration is asked again when the app next opens.
        relaunched.registrationFailed()
        relaunched.appOpened()
        #expect(relaunch.value == 2)
    }

    @Test func turningCalendarsOnOrOffWatchesTheNewSetAndAReloadOfTheSameListDoesNot() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, nil], expiresAt: weekLater))
        model.setOn(family, true)
        await model.watch.idle()
        #expect(watches.count == 2)
        #expect(watches.last?.calendars == ["me@example.test", "family-id"])
        #expect(model.watch.isLive)

        clock.advance(10)
        await model.loadCalendars()
        await model.watch.idle()
        #expect(watches.count == 2)
    }

    @Test func turningTheLastCalendarOffStopsTheChannels() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        let me = try #require(model.calendars.first)
        model.setOn(me, false)
        await model.watch.idle()
        #expect(unwatches.count == 1)
        #expect(unwatches.first?.deviceToken == FakeDevice.hex)
        #expect(unwatches.first?.token == FakeGoogle.access)
        #expect(!model.watch.isLive)
        #expect(model.pollInterval == GooglePoll.interval)
        // Turning it on again watches again.
        model.setOn(me, true)
        await model.watch.idle()
        #expect(watches.count == 2)
    }

    @Test func aNewDeviceTokenWatchesAgainAndTheSameOneDoesNot() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        model.registered(FakeDevice.token)
        await model.watch.idle()
        #expect(watches.count == 1)
        model.registered(FakeDevice.other)
        await model.watch.idle()
        #expect(watches.count == 2)
        #expect(watches.last?.deviceToken == FakeDevice.other.hex)
    }

    @Test func aRelaunchKeepsFreshChannelsAndReplacesThoseWithUnderTwoDaysLeft() async throws {
        let container = try SeasignSchema.inMemoryContainer()
        let context = ModelContext(container)
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)

        // Next launch, a day later: same token, five days left. Nothing is sent.
        clock.advance(24 * 3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let relaunched = model(context, store: store)
        relaunched.launched()
        relaunched.registered(FakeDevice.token)
        await relaunched.watch.idle()
        #expect(watches.count == 1)
        #expect(relaunched.watch.isLive)
        #expect(relaunched.pollInterval == GooglePoll.intervalWithPush)

        // Opened again with just over two days left: still nothing.
        clock.advance(4 * 24 * 3600 - 60)
        relaunched.appOpened()
        await relaunched.watch.idle()
        #expect(watches.count == 1)

        // Under two days left: the channels are replaced.
        clock.advance(120)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-12-01T18:00:00Z"))
        relaunched.appOpened()
        await relaunched.watch.idle()
        #expect(watches.count == 2)
        #expect(relaunched.watch.expiresAt == instant("2026-12-01T18:00:00Z"))
    }

    @Test func aRelaunchWithChannelsNearlyEndedWatchesWhenTheTokenArrives() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)
        clock.advance(6 * 24 * 3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let relaunched = model(context, store: store)
        relaunched.launched()
        relaunched.registered(FakeDevice.token)
        await relaunched.watch.idle()
        #expect(watches.count == 2)
    }

    @Test func theWatchRecordHoldsNeitherTheDeviceTokenNorACalendarID() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        _ = try await watching(context)
        let rows = try context.fetch(FetchDescriptor<GoogleWatchRecord>())
        #expect(rows.count == 1)
        for row in rows {
            #expect(!row.fingerprint.contains(FakeDevice.hex))
            #expect(!row.fingerprint.contains("example"))
        }
    }

    // MARK: Failures

    @Test func ourRateLimitShowsInSettingsAndNeverHoldsThePoll() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "120"))
        model.registered(FakeDevice.token)
        await model.watch.idle()
        #expect(model.watch.problem == .rateLimited)
        #expect(model.statusProblem == nil)
        #expect(model.retryNotBefore == nil)
        #expect(!model.watch.isLive)
        #expect(model.pollInterval == GooglePoll.interval)
        // The poll still asks.
        let events = stub.count(GoogleAPIStub.postEvents)
        clock.advance(5)
        await model.refresh()
        #expect(stub.count(GoogleAPIStub.postEvents) == events + 1)

        // Within the delay nothing asks again, not even a calendar change.
        model.appOpened()
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        await model.watch.idle()
        #expect(watches.count == 1)

        // After it, opening the app watches again.
        clock.advance(120)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, nil], expiresAt: weekLater))
        model.appOpened()
        await model.watch.idle()
        #expect(watches.count == 2)
        #expect(model.watch.problem == nil)
        #expect(model.watch.isLive)
    }

    @Test func aCalendarGoogleWillNotWatchShowsUnderItAndKeepsTheFastPoll() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, "not_found"], expiresAt: weekLater))
        model.registered(FakeDevice.token)
        await model.watch.idle()
        #expect(model.watch.calendarProblems == ["family-id": "not_found"])
        #expect(model.watchMessage(for: family) != nil)
        let me = try #require(model.calendars.first { $0.calendarID == "me@example.test" })
        #expect(model.watchMessage(for: me) == nil)
        #expect(!model.watch.isLive)
        #expect(model.pollInterval == GooglePoll.interval)
        #expect(model.statusProblem == nil)
        // Opening the app soon after does not ask again at once.
        model.appOpened()
        await model.watch.idle()
        #expect(watches.count == 1)
    }

    @Test func noServerOrAServerWithoutPushIsSilentAndRetriedLater() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.serviceUnavailable, "push_unavailable"))
        model.registered(FakeDevice.token)
        await model.watch.idle()
        #expect(watches.count == 1)
        #expect(model.watch.problem == nil)
        #expect(model.statusProblem == nil)
        #expect(model.retryNotBefore == nil)
        #expect(model.pollInterval == GooglePoll.interval)
        model.appOpened()
        await model.watch.idle()
        #expect(watches.count == 1)
        clock.advance(GoogleWatchKeeper.failureHold + 1)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-11-26T19:00:00Z"))
        model.appOpened()
        await model.watch.idle()
        #expect(watches.count == 2)
        #expect(model.watch.isLive)
    }

    @Test func aRejectedTokenIsRenewedOnceForTheWatch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        stub.answer(
            GoogleAPIStub.postWatch,
            GoogleAPIStub.error(.unauthorized, "google_auth"),
            GoogleAPIStub.watch([nil], expiresAt: weekLater)
        )
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        model.registered(FakeDevice.token)
        await model.watch.idle()
        #expect(watches.count == 2)
        #expect(watches.last?.token == FakeGoogle.access2)
        #expect(model.watch.isLive)
    }

    // MARK: One at a time

    @Test func changesDuringAWatchWaitForItAndOnlyTheLatestIsSent() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([
            ("me@example.test", "Me", true), ("family-id", "Family", false), ("work-id", "Work", false),
        ]))
        clock.advance(10)
        await model.loadCalendars()
        stub.hold(GoogleAPIStub.postWatch)
        model.registered(FakeDevice.token)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        let work = try #require(model.calendars.first { $0.calendarID == "work-id" })
        model.setOn(family, true)
        model.setOn(work, true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(watches.count == 1)  // nothing is sent beside the one out
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, nil, nil], expiresAt: weekLater))
        stub.release(GoogleAPIStub.postWatch)
        await model.watch.idle()
        #expect(watches.count == 2)
        #expect(watches.first?.calendars == ["me@example.test"])
        #expect(watches.last?.calendars == ["me@example.test", "family-id", "work-id"])
        #expect(stub.peak(GoogleAPIStub.pushKey) == 1)
        #expect(model.watch.isLive)
    }

    @Test func goingBackToTheSetBeingSentQueuesNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        stub.hold(GoogleAPIStub.postWatch)
        model.registered(FakeDevice.token)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        model.setOn(family, false)
        stub.release(GoogleAPIStub.postWatch)
        await model.watch.idle()
        #expect(watches.count == 1)
        #expect(model.watch.isLive)
    }

    @Test func disconnectDuringAWatchUnwatchesAfterItThenRevokes() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = await connected(context, store: store)
        stub.hold(GoogleAPIStub.postWatch)
        stub.hold(GoogleAPIStub.postUnwatch)
        model.registered(FakeDevice.token)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }

        let disconnecting = Task { await model.disconnect() }
        try await waitUntil { model.connection == .notConnected }
        // The screen changed at once; nothing was sent beside the watch.
        #expect(unwatches.isEmpty)
        #expect(store.stored == nil)
        stub.release(GoogleAPIStub.postWatch)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postUnwatch) == 1 }
        // Revoking waits for the unwatch, which needs a token Google still takes.
        #expect(endpoint.revoked.isEmpty)
        #expect(unwatches.first?.token == FakeGoogle.access)
        #expect(unwatches.first?.deviceToken == FakeDevice.hex)
        stub.release(GoogleAPIStub.postUnwatch)
        await disconnecting.value
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(stub.peak(GoogleAPIStub.pushKey) == 1)
        // The watch that answered after Disconnect left nothing behind.
        #expect(!model.watch.isLive)
        #expect(model.watch.calendarProblems.isEmpty)
        #expect(try context.fetch(FetchDescriptor<GoogleWatchRecord>()).isEmpty)
    }

    // MARK: Disconnect and expiry

    @Test func disconnectUnwatchesWithAFreshTokenWhenTheOneInMemoryHasExpired() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        await model.disconnect()
        #expect(unwatches.count == 1)
        #expect(unwatches.first?.token == FakeGoogle.access2)
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(try context.fetch(FetchDescriptor<GoogleWatchRecord>()).isEmpty)
    }

    @Test func disconnectWithoutADeviceTokenSendsNoUnwatch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        await model.disconnect()
        #expect(unwatches.isEmpty)
        #expect(endpoint.revoked == [FakeGoogle.refresh])
    }

    @Test func anEndedSignInUnwatchesWithTheLastTokenHad() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        await model.refresh()
        #expect(model.connection == .expired)
        #expect(!model.watch.isLive)
        try await waitUntil { unwatches.count == 1 }
        await model.watch.idle()
        #expect(unwatches.first?.token == FakeGoogle.access)
        #expect(unwatches.first?.deviceToken == FakeDevice.hex)
        // Nothing more is sent for a connection that has ended.
        model.appOpened()
        await model.watch.idle()
        #expect(watches.count == 1)
    }

    // MARK: Pushes

    @Test func aPushFetchesOnceAndSaysWhetherAnythingChanged() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Lunch", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil]
        ))
        // Forced: the last answer is under a second old.
        #expect(await model.handlePush(type: "calendar-changed") == .newData)
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 1)
        #expect(titles(model) == ["Lunch"])
        #expect(await model.handlePush(type: "calendar-changed") == .noData)
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        stub.setOffline(true)
        #expect(await model.handlePush(type: "calendar-changed") == .failed)
        #expect(titles(model) == ["Lunch"])
    }

    @Test func otherPushesAndPushesWhileNotConnectedFetchNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        #expect(await model.handlePush(type: nil) == .noData)
        #expect(await model.handlePush(type: "something-else") == .noData)
        await model.disconnect()
        #expect(await model.handlePush(type: "calendar-changed") == .noData)
        #expect(stub.count(GoogleAPIStub.postEvents) == before)
    }

    @Test func pushesArrivingTogetherShareOneFetch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Lunch", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil]
        ))
        async let first = model.handlePush(type: "calendar-changed")
        async let second = model.handlePush(type: "calendar-changed")
        async let third = model.handlePush(type: "calendar-changed")
        let outcomes = await [first, second, third]
        #expect(outcomes == [.newData, .newData, .newData])
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 1)
    }

    @Test func aPushDuringTheFetchGetsOneMoreFetchAfterIt() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.hold(GoogleAPIStub.postEvents)
        let first = Task { await model.handlePush(type: "calendar-changed") }
        try await waitUntil { stub.outstanding(GoogleAPIStub.postEvents) == 1 }
        let second = Task { await model.handlePush(type: "calendar-changed") }
        let third = Task { await model.handlePush(type: "calendar-changed") }
        try await Task.sleep(for: .milliseconds(30))
        stub.release(GoogleAPIStub.postEvents)
        _ = await (first.value, second.value, third.value)
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        #expect(stub.peak(GoogleAPIStub.postEvents) == 1)
    }

    @Test func aPushWaitsForARunningPollThenFetches() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.hold(GoogleAPIStub.postEvents)
        clock.advance(5)
        let poll = Task { await model.refresh() }
        try await waitUntil { stub.outstanding(GoogleAPIStub.postEvents) == 1 }
        let push = Task { await model.handlePush(type: "calendar-changed") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 1)
        stub.release(GoogleAPIStub.postEvents)
        await poll.value
        _ = await push.value
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        #expect(stub.peak(GoogleAPIStub.postEvents) == 1)
    }

    @Test func aPushAnswersByItsDeadlineEvenIfTheFetchHangs() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context, pushDeadline: .milliseconds(300))
        stub.hold(GoogleAPIStub.postEvents)
        let started = ContinuousClock.now
        #expect(await model.handlePush(type: "calendar-changed") == .failed)
        #expect(ContinuousClock.now - started < .seconds(3))
        stub.release(GoogleAPIStub.postEvents)
    }

    @Test func theDeadlineIsInsideTheSystemsThirtySeconds() {
        #expect(GooglePushHandling.deadline < .seconds(30))
    }

    // MARK: Poll rate

    @Test func thePollIsFastWithoutAChannelAndSlowWithOne() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        #expect(model.pollInterval == .seconds(5))
        model.registered(FakeDevice.token)
        await model.watch.idle()
        #expect(model.pollInterval == .seconds(60))
        // Channels that have ended no longer count once the app looks again.
        clock.advance(8 * 24 * 3600)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.serviceUnavailable, "push_unavailable"))
        model.appOpened()
        await model.watch.idle()
        #expect(model.pollInterval == .seconds(5))
    }

    // MARK: Lead fixes from the #154 review

    @Test func disconnectDuringTheCodeExchangeShowsNotConnectedAtOnce() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = model(context, store: InMemoryGoogleTokenStore())
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        endpoint.hold(grant: "authorization_code")
        let connecting = Task { await model.connect(signIn: redirect()) }
        try await waitUntil { endpoint.sent(grant: "authorization_code").count == 1 }
        #expect(model.isConnecting)
        await model.disconnect()
        #expect(!model.isConnecting)
        #expect(model.connection == .notConnected)

        // A new Connect started meanwhile is not cleared by the old one ending.
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        let second = Task { await model.connect(signIn: redirect()) }
        try await waitUntil { endpoint.sent(grant: "authorization_code").count == 2 }
        #expect(model.isConnecting)
        endpoint.release()
        await connecting.value
        await second.value
        #expect(!model.isConnecting)
    }

    @Test func aFailedFirstListLoadIsTriedAgainWhileSettingsIsOpen() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        stub.answer(GoogleAPIStub.getCalendars,
                    GoogleAPIStub.error(.badGateway, "google_unavailable"),
                    GoogleAPIStub.calendars([("me@example.test", "Me", true)]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        let model = model(context, store: InMemoryGoogleTokenStore())
        await model.connect(signIn: redirect())
        #expect(model.connection == .connected)
        #expect(model.calendars.isEmpty)
        #expect(model.retryNotBefore != nil)  // a back-off

        // Settings opens during the back-off: the missing list is read anyway.
        await model.loadCalendarsWhileShown()
        #expect(model.calendars.map(\.calendarID) == ["me@example.test"])
        #expect(!model.listHeld)
    }

    @Test func settingsReadsTheListWhenOurRateLimitEndsAndSaysWhyItWaits() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        stub.answer(GoogleAPIStub.getCalendars,
                    GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"),
                    GoogleAPIStub.calendars([("me@example.test", "Me", true)]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        let model = model(context, store: InMemoryGoogleTokenStore())
        await model.connect(signIn: redirect())
        #expect(model.calendars.isEmpty)
        #expect(model.statusProblem == .rateLimited)

        // Our 429 is honoured even with no list: one ask is held and noted.
        let lists = stub.count(GoogleAPIStub.getCalendars)
        let wait = await model.loadCalendars()
        #expect(wait != nil)
        #expect(model.listHeld)
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists)

        // While Settings stays open, the list is read once the delay has passed
        // (the test's sleep moves the clock).
        await model.loadCalendarsWhileShown()
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists + 1)
        #expect(model.calendars.map(\.calendarID) == ["me@example.test"])
        #expect(!model.listHeld)
    }

    @Test func aHeldReloadOfAListAlreadyShownIsNoted() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = await connected(context)
        clock.advance(5)
        stub.setOffline(true)
        await model.refresh()
        #expect(model.retryNotBefore != nil)
        stub.setOffline(false)
        let lists = stub.count(GoogleAPIStub.getCalendars)
        #expect(await model.loadCalendars() != nil)
        #expect(model.listHeld)
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists)
        await model.loadCalendarsWhileShown()
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists + 1)
        #expect(!model.listHeld)
    }
}
