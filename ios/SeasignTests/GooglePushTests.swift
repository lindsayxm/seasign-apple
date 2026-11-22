import Foundation
import SwiftData
import Testing
import UIKit

@testable import Seasign

/// A made-up device token: 32 bytes, 0x00 to 0x1f, so its hex is known.
enum FakeDevice {
    static let token = APNsDeviceToken(Data(0..<32))
    static let hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    static let other = APNsDeviceToken(Data((0..<32).map { UInt8(255 - $0) }))
}

// MARK: - Bounded waits

@MainActor
private final class Finished<T> {
    var value: T?
}

/// Runs `operation` and fails the test if it has not finished within
/// `limit`, so a keeper that never settles fails one test instead of hanging
/// the run. The operation runs in its own task: a wait that ignores
/// cancellation (`GoogleWatchKeeper.idle()`) cannot hold the test up.
@MainActor
func bounded<T>(
    _ limit: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: @escaping @MainActor () async -> T
) async throws -> T {
    let finished = Finished<T>()
    let work = Task { @MainActor in finished.value = await operation() }
    let deadline = ContinuousClock.now + limit
    while finished.value == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard let value = finished.value else {
        work.cancel()
        Issue.record("Did not finish within \(limit)", sourceLocation: sourceLocation)
        throw BoundedWaitTimedOut()
    }
    return value
}

struct BoundedWaitTimedOut: Error {}

/// Waits, bounded, until `model`'s keeper has no request out or queued.
@MainActor
func idle(_ model: GoogleCalendarModel, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await bounded(sourceLocation: sourceLocation) { await model.watch.idle() }
}

/// Hands a push to `model`, bounded.
@MainActor
func push(_ model: GoogleCalendarModel, _ type: String?, sourceLocation: SourceLocation = #_sourceLocation) async throws -> GooglePushOutcome {
    try await bounded(sourceLocation: sourceLocation) { await model.handlePush(type: type) }
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

    @Test func onlyAnHTTPSServerCanDeliverPushes() throws {
        let stub = GoogleAPIStub()
        func api(_ server: String) throws -> SeasignAPI {
            SeasignAPI(serverURL: try #require(URL(string: server)), transport: stub, keyNeedsHTTPS: false)
        }
        #expect(try !api("http://localhost:8787").pushAvailable)
        #expect(try !api("http://example.test").pushAvailable)
        #expect(try api("https://example.test").pushAvailable)
        #expect(try api("HTTPS://example.test").pushAvailable)
        // Debug builds talk to `wrangler dev` over http, so they never watch.
        #expect(!SeasignAPI(transport: stub).pushAvailable)
    }

    @Test func disconnectWaitsAtMostTenSecondsForTheChannels() {
        #expect(GoogleCalendarModel.unwatchWait == .seconds(10))
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
    @Test func aLaunchAndATokenBeforeTheReceiverArePassedOnWhenItIsAttached() async throws {
        let relay = RemotePushRelay()
        relay.launched()
        relay.registered(FakeDevice.token)
        #expect(try await bounded { await relay.received(type: "calendar-changed") } == .noData)
        let receiver = FakeReceiver()
        relay.attach(receiver)
        #expect(receiver.launches == 1)
        #expect(receiver.tokens == [FakeDevice.token])
        relay.registered(FakeDevice.other)
        relay.registrationFailed()
        #expect(receiver.tokens == [FakeDevice.token, FakeDevice.other])
        #expect(receiver.failures == 1)
        #expect(try await bounded { await relay.received(type: "calendar-changed") } == .newData)
        #expect(receiver.pushes == ["calendar-changed"])
    }
}

@Suite @MainActor struct SeasignAppDelegateTests {
    /// With its own relay, so the app the tests run in is not involved.
    @Test func aPushIsPassedOnAndTheCompletionHandlerCalledOnce() async throws {
        let delegate = SeasignAppDelegate()
        let relay = RemotePushRelay()
        let receiver = FakeReceiver()
        relay.attach(receiver)
        delegate.relay = relay
        var results: [UIBackgroundFetchResult] = []
        delegate.application(.shared, didReceiveRemoteNotification: ["type": "calendar-changed"]) { results.append($0) }
        for _ in 0..<500 where results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(results == [.newData])
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
        registrations: Counter? = nil,
        server: String = "https://example.test",
        unwatchWait: Duration = GoogleCalendarModel.unwatchWait
    ) -> GoogleCalendarModel {
        let clock = clock
        let zone = zone
        let model = GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: server)!, transport: stub, keyNeedsHTTPS: false),
            context: context,
            config: FakeGoogle.config,
            tokens: store,
            http: endpoint.http,
            timeZone: { zone },
            now: { clock.now },
            environment: environment,
            sleep: { seconds in clock.advance(seconds) },
            pushWindow: .milliseconds(50),
            pushDeadline: pushDeadline,
            unwatchWait: unwatchWait
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
        registrations: Counter? = nil,
        server: String = "https://example.test",
        unwatchWait: Duration = GoogleCalendarModel.unwatchWait
    ) async throws -> GoogleCalendarModel {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("me@example.test", "Me", true), ("family-id", "Family", false)]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil]
        ))
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: weekLater))
        stub.answer(GoogleAPIStub.postUnwatch, GoogleAPIStub.unwatched(1))
        let model = model(
            context, store: store, environment: environment, pushDeadline: pushDeadline,
            registrations: registrations, server: server, unwatchWait: unwatchWait
        )
        let signIn = redirect()
        try await bounded { await model.connect(signIn: signIn) }
        return model
    }

    /// A connected model that has its device token and one live channel for "Me".
    private func watching(_ context: ModelContext, store: InMemoryGoogleTokenStore = InMemoryGoogleTokenStore()) async throws -> GoogleCalendarModel {
        let model = try await connected(context, store: store)
        model.registered(FakeDevice.token)
        try await idle(model)
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
        let model = try await connected(context, registrations: registrations)
        #expect(registrations.value == 1)
        #expect(watches.isEmpty)  // no device token yet

        model.registered(FakeDevice.token)
        try await idle(model)
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
        let model = try await connected(context, environment: .production)
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.first?.environment == "production")
    }

    @Test func atLaunchItAsksForATokenOnlyWhenGoogleIsConnected() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let notConnected = Counter()
        model(context, store: store, registrations: notConnected).launched()
        #expect(notConnected.value == 0)

        _ = try await connected(context, store: store)
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
        try await idle(model)
        #expect(watches.count == 2)
        #expect(watches.last?.calendars == ["me@example.test", "family-id"])
        #expect(model.watch.isLive)

        clock.advance(10)
        _ = try await bounded { await model.loadCalendars() }
        try await idle(model)
        #expect(watches.count == 2)
    }

    @Test func turningTheLastCalendarOffStopsTheChannels() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        let me = try #require(model.calendars.first)
        model.setOn(me, false)
        try await idle(model)
        #expect(unwatches.count == 1)
        #expect(unwatches.first?.deviceToken == FakeDevice.hex)
        #expect(unwatches.first?.token == FakeGoogle.access)
        #expect(!model.watch.isLive)
        #expect(model.pollInterval == GooglePoll.interval)
        // Turning it on again watches again.
        model.setOn(me, true)
        try await idle(model)
        #expect(watches.count == 2)
    }

    @Test func aNewDeviceTokenWatchesAgainAndTheSameOneDoesNot() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.count == 1)
        model.registered(FakeDevice.other)
        try await idle(model)
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
        try await idle(relaunched)
        #expect(watches.count == 1)
        #expect(relaunched.watch.isLive)
        #expect(relaunched.pollInterval == GooglePoll.intervalWithPush)

        // Opened again with just over two days left: still nothing.
        clock.advance(4 * 24 * 3600 - 60)
        relaunched.appOpened()
        try await idle(relaunched)
        #expect(watches.count == 1)

        // Under two days left: the channels are replaced.
        clock.advance(120)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-12-01T18:00:00Z"))
        relaunched.appOpened()
        try await idle(relaunched)
        #expect(watches.count == 2)
        #expect(relaunched.watch.expiresAt == instant("2026-12-01T18:00:00Z"))
    }

    @Test func aRelaunchWithChannelsNearlyEndedWatchesWhenTheTokenArrives() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)
        clock.advance(6 * 24 * 3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        // The new channels run seven days from now.
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-12-02T18:00:00Z"))
        let relaunched = model(context, store: store)
        relaunched.launched()
        relaunched.registered(FakeDevice.token)
        try await idle(relaunched)
        #expect(watches.count == 2)
        #expect(relaunched.watch.isLive)
        #expect(relaunched.watch.expiresAt == instant("2026-12-02T18:00:00Z"))
    }

    // MARK: Nothing is sent over and over

    @Test func aCompleteWatchThatEndsWithinTwoDaysIsNotSentAgainUntilItEnds() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        // Google gave one day (or this device's clock runs days ahead).
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-11-20T18:00:00Z"))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.count == 1)
        #expect(model.watch.isLive)
        #expect(model.pollInterval == GooglePoll.intervalWithPush)

        // Not on opening the app, nor on the same device token again, while it runs.
        model.appOpened()
        try await idle(model)
        model.registered(FakeDevice.token)
        try await idle(model)
        clock.advance(23 * 3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 1)

        // A different set still goes ahead.
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, nil], expiresAt: "2026-11-27T17:00:00Z"))
        model.setOn(family, true)
        try await idle(model)
        try #require(watches.count == 2)
        #expect(watches[1].calendars == ["me@example.test", "family-id"])
        #expect(model.watch.isLive)
    }

    @Test func aShortWatchIsSentAgainOnOpeningOnceItHasEnded() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-11-20T18:00:00Z"))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.count == 1)
        clock.advance(24 * 3600 + 1)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-11-27T18:00:00Z"))
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 2)
        #expect(model.watch.isLive)
    }

    @Test func aWatchAnsweredAlreadyEndedIsTriedAgainOnlyAfterTheHold() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        // This device's clock runs more than a week ahead.
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-11-19T17:00:00Z"))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.count == 1)
        #expect(!model.watch.isLive)
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 1)
        clock.advance(GoogleWatchKeeper.failureHold + 1)
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 2)
    }

    @Test func anUnwatchWithNoGoogleTokenToHaveIsHeldNotRepeated() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        // The token in memory has expired and Google cannot be reached.
        clock.advance(3600)
        endpoint.setOffline(true)
        let before = endpoint.sent(grant: "refresh_token").count
        let me = try #require(model.calendars.first)
        model.setOn(me, false)
        try await idle(model)
        #expect(unwatches.isEmpty)
        // One renewal for the unwatch (an events fetch may add one), not one per turn of a loop.
        let afterOff = endpoint.sent(grant: "refresh_token").count
        #expect(afterOff - before <= 2)

        // Opening the app within the hold does not try again.
        model.appOpened()
        try await idle(model)
        #expect(endpoint.sent(grant: "refresh_token").count == afterOff)
        #expect(unwatches.isEmpty)

        // After it, with Google back, the unwatch goes out.
        clock.advance(GoogleWatchKeeper.failureHold + 1)
        endpoint.setOffline(false)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        model.appOpened()
        try await idle(model)
        #expect(unwatches.count == 1)
        #expect(unwatches.first?.token == FakeGoogle.access2)
        #expect(unwatches.first?.deviceToken == FakeDevice.hex)
    }

    @Test func turningACalendarBackOnAfterAnUnsentUnwatchKeepsTheChannelsLeft() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        clock.advance(3600)
        endpoint.setOffline(true)
        let me = try #require(model.calendars.first)
        model.setOn(me, false)
        try await idle(model)
        #expect(unwatches.isEmpty)
        endpoint.setOffline(false)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        model.setOn(me, true)
        try await idle(model)
        // The record still covers "Me" and has days left, so nothing needs sending;
        // the channels the failed unwatch left are the ones wanted again.
        #expect(watches.count == 1)
        #expect(model.watch.isLive)
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
        let model = try await connected(context)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "120"))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(model.watch.problem == .rateLimited)
        #expect(model.statusProblem == nil)
        #expect(model.retryNotBefore == nil)
        #expect(!model.watch.isLive)
        #expect(model.pollInterval == GooglePoll.interval)
        // The poll still asks.
        let events = stub.count(GoogleAPIStub.postEvents)
        clock.advance(5)
        try await bounded { await model.refresh() }
        #expect(stub.count(GoogleAPIStub.postEvents) == events + 1)

        // Within the delay nothing asks again, not even a calendar change.
        model.appOpened()
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        try await idle(model)
        #expect(watches.count == 1)

        // After it, opening the app watches again.
        clock.advance(120)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, nil], expiresAt: weekLater))
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 2)
        #expect(model.watch.problem == nil)
        #expect(model.watch.isLive)
    }

    @Test func aCalendarGoogleWillNotWatchShowsUnderItAndKeepsTheFastPoll() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, "not_found"], expiresAt: weekLater))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(model.watch.calendarProblems == ["family-id": "not_found"])
        #expect(model.watchMessage(for: family) != nil)
        let me = try #require(model.calendars.first { $0.calendarID == "me@example.test" })
        #expect(model.watchMessage(for: me) == nil)
        #expect(!model.watch.isLive)
        #expect(model.pollInterval == GooglePoll.interval)
        #expect(model.statusProblem == nil)
        // Opening the app soon after does not ask again at once.
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 1)
    }

    @Test func noServerOrAServerWithoutPushIsSilentAndRetriedLater() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.serviceUnavailable, "push_unavailable"))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.count == 1)
        #expect(model.watch.problem == nil)
        #expect(model.statusProblem == nil)
        #expect(model.retryNotBefore == nil)
        #expect(model.pollInterval == GooglePoll.interval)
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 1)
        clock.advance(GoogleWatchKeeper.failureHold + 1)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil], expiresAt: "2026-11-26T19:00:00Z"))
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 2)
        #expect(model.watch.isLive)
    }

    @Test func aRejectedTokenIsRenewedOnceForTheWatch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        stub.answer(
            GoogleAPIStub.postWatch,
            GoogleAPIStub.error(.unauthorized, "google_auth"),
            GoogleAPIStub.watch([nil], expiresAt: weekLater)
        )
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.count == 2)
        #expect(watches.last?.token == FakeGoogle.access2)
        #expect(model.watch.isLive)
    }

    // MARK: One at a time

    @Test func changesDuringAWatchWaitForItAndOnlyTheLatestIsSent() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([
            ("me@example.test", "Me", true), ("family-id", "Family", false), ("work-id", "Work", false),
        ]))
        clock.advance(10)
        _ = try await bounded { await model.loadCalendars() }
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
        try await idle(model)
        #expect(watches.count == 2)
        #expect(watches.first?.calendars == ["me@example.test"])
        #expect(watches.last?.calendars == ["me@example.test", "family-id", "work-id"])
        #expect(stub.peak(GoogleAPIStub.pushKey) == 1)
        #expect(model.watch.isLive)
    }

    @Test func goingBackToTheSetBeingSentQueuesNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        stub.hold(GoogleAPIStub.postWatch)
        model.registered(FakeDevice.token)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        model.setOn(family, false)
        stub.release(GoogleAPIStub.postWatch)
        try await idle(model)
        #expect(watches.count == 1)
        #expect(model.watch.isLive)
    }

    @Test func turningTheOnlyCalendarOffAndOnDuringAWatchEndsWithItWatched() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        let me = try #require(model.calendars.first)
        stub.hold(GoogleAPIStub.postWatch)
        model.registered(FakeDevice.token)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        model.setOn(me, false)
        #expect(!model.watch.isLive)
        stub.release(GoogleAPIStub.postWatch)
        // The watch answered after the calendar went off: its channels are stopped.
        try await idle(model)
        #expect(unwatches.count == 1)
        #expect(try context.fetch(FetchDescriptor<GoogleWatchRecord>()).isEmpty)
        #expect(!model.watch.isLive)
        // On again: watched again, not taken as already live.
        model.setOn(me, true)
        try await idle(model)
        #expect(watches.count == 2)
        #expect(model.watch.isLive)
        #expect(stub.peak(GoogleAPIStub.pushKey) == 1)
    }

    @Test func turningACalendarOnAndOffDuringItsWatchGoesBackToTheEarlierSet() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        // The held request reads its answer when released, so both are queued now, in order.
        stub.answer(
            GoogleAPIStub.postWatch,
            GoogleAPIStub.watch([nil, nil], expiresAt: weekLater),
            GoogleAPIStub.watch([nil], expiresAt: weekLater)
        )
        stub.hold(GoogleAPIStub.postWatch)
        model.setOn(family, true)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        model.setOn(family, false)
        stub.release(GoogleAPIStub.postWatch)
        try await idle(model)
        // The API kept the last request's channels, so "Me" alone is watched again.
        try #require(watches.count == 3)
        #expect(watches[1].calendars == ["me@example.test", "family-id"])
        #expect(watches[2].calendars == ["me@example.test"])
        #expect(model.watch.isLive)
        #expect(stub.peak(GoogleAPIStub.pushKey) == 1)
    }

    @Test func aFailedWatchDoesNotHoldBackASetChosenWhileItWasOut() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        // The watch for both comes back with Family refused (incomplete, so held),
        // and Family was turned off meanwhile: "Me" alone is still sent.
        stub.answer(
            GoogleAPIStub.postWatch,
            GoogleAPIStub.watch([nil, "not_found"], expiresAt: weekLater),
            GoogleAPIStub.watch([nil], expiresAt: weekLater)
        )
        stub.hold(GoogleAPIStub.postWatch)
        model.setOn(family, true)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        model.setOn(family, false)
        stub.release(GoogleAPIStub.postWatch)
        try await idle(model)
        try #require(watches.count == 3)
        #expect(watches[2].calendars == ["me@example.test"])
        #expect(model.watch.isLive)
        // The refused set itself is not retried on opening the app within the hold.
        model.setOn(family, true)
        try await idle(model)
        #expect(watches.count == 4)
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 4)
    }

    @Test func aChangeQueuedBehindAWatchThatHitOurLimitWaitsForTheDelay() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "60"))
        stub.hold(GoogleAPIStub.postWatch)
        model.registered(FakeDevice.token)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        model.setOn(family, true)
        stub.release(GoogleAPIStub.postWatch)
        try await idle(model)
        #expect(watches.count == 1)
        #expect(model.watch.problem == .rateLimited)
    }

    @Test func disconnectDuringAWatchUnwatchesAfterItThenRevokes() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = try await connected(context, store: store)
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
        try await bounded { await disconnecting.value }
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
        try await bounded { await model.disconnect() }
        #expect(unwatches.count == 1)
        #expect(unwatches.first?.token == FakeGoogle.access2)
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(try context.fetch(FetchDescriptor<GoogleWatchRecord>()).isEmpty)
    }

    @Test func disconnectWithoutADeviceTokenOrChannelsSendsNoUnwatch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        try await bounded { await model.disconnect() }
        #expect(unwatches.isEmpty)
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        // No watch was ever made, so the token arriving later sends nothing either.
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(unwatches.isEmpty)
        #expect(watches.isEmpty)
    }

    @Test func disconnectBeforeTheDeviceTokenUnwatchesWhenTheTokenArrives() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)
        // Next launch: the channels from last time are on record, and Disconnect
        // comes before the system has given the device token.
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let relaunched = model(context, store: store)
        relaunched.launched()
        try await bounded { await relaunched.disconnect() }
        #expect(unwatches.isEmpty)
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(try context.fetch(FetchDescriptor<GoogleWatchRecord>()).isEmpty)

        relaunched.registered(FakeDevice.token)
        try await idle(relaunched)
        try #require(unwatches.count == 1)
        #expect(unwatches[0].deviceToken == FakeDevice.hex)
        #expect(unwatches[0].token == FakeGoogle.access2)
        #expect(watches.count == 1)
        // Once only.
        relaunched.registered(FakeDevice.other)
        try await idle(relaunched)
        #expect(unwatches.count == 1)
    }

    @Test func connectingAgainBeforeTheDeviceTokenDropsTheOwedUnwatch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let relaunched = model(context, store: store)
        relaunched.launched()
        try await bounded { await relaunched.disconnect() }
        let signIn = redirect()
        try await bounded { await relaunched.connect(signIn: signIn) }
        #expect(relaunched.connection == .connected)
        relaunched.registered(FakeDevice.token)
        try await idle(relaunched)
        // The new watch replaces the device's channels; no unwatch goes out.
        #expect(unwatches.isEmpty)
        #expect(watches.count == 2)
        #expect(relaunched.watch.isLive)
    }

    @Test func connectingAgainWithNoCalendarOnStillUnwatchesWhenTheTokenArrives() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let relaunched = model(context, store: store)
        relaunched.launched()
        try await bounded { await relaunched.disconnect() }
        let signIn = redirect()
        try await bounded { await relaunched.connect(signIn: signIn) }
        let me = try #require(relaunched.calendars.first)
        relaunched.setOn(me, false)
        relaunched.registered(FakeDevice.token)
        try await idle(relaunched)
        // Nothing to watch, so the old channels are stopped with the new sign-in's token.
        try #require(unwatches.count == 1)
        #expect(unwatches[0].token == FakeGoogle.access)
        #expect(unwatches[0].deviceToken == FakeDevice.hex)
        #expect(watches.count == 1)
    }

    @Test func disconnectingTwiceBeforeTheDeviceTokenStillUnwatchesWhenItArrives() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let relaunched = model(context, store: store)
        relaunched.launched()
        try await bounded { await relaunched.disconnect() }
        let signIn = redirect()
        try await bounded { await relaunched.connect(signIn: signIn) }
        try await bounded { await relaunched.disconnect() }
        #expect(unwatches.isEmpty)
        relaunched.registered(FakeDevice.token)
        try await idle(relaunched)
        try #require(unwatches.count == 1)
        #expect(unwatches[0].deviceToken == FakeDevice.hex)
        #expect(watches.count == 1)
    }

    @Test func anEndedSignInBeforeTheDeviceTokenUnwatchesWhenItArrives() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        _ = try await watching(context, store: store)
        // Next launch: a token is had for the events, then the sign-in ends,
        // all before the system gives the device token.
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        let relaunched = model(context, store: store)
        relaunched.launched()
        try await bounded { await relaunched.refresh(force: true) }
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        try await bounded { await relaunched.refresh(force: true) }
        #expect(relaunched.connection == .expired)
        #expect(unwatches.isEmpty)
        relaunched.registered(FakeDevice.token)
        try await waitUntil { unwatches.count == 1 }
        try await idle(relaunched)
        #expect(unwatches.count == 1)
        #expect(unwatches.first?.token == FakeGoogle.access2)
        #expect(unwatches.first?.deviceToken == FakeDevice.hex)
    }

    @Test func anEndedSignInUnwatchesWithTheLastTokenHad() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        try await bounded { await model.refresh() }
        #expect(model.connection == .expired)
        #expect(!model.watch.isLive)
        try await waitUntil { unwatches.count == 1 }
        try await idle(model)
        #expect(unwatches.first?.token == FakeGoogle.access)
        #expect(unwatches.first?.deviceToken == FakeDevice.hex)
        // Nothing more is sent for a connection that has ended.
        model.appOpened()
        try await idle(model)
        #expect(watches.count == 1)
    }

    // MARK: Pushes

    @Test func aPushFetchesOnceAndSaysWhetherAnythingChanged() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Lunch", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil]
        ))
        // Forced: the last answer is under a second old.
        #expect(try await push(model, "calendar-changed") == .newData)
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 1)
        #expect(titles(model) == ["Lunch"])
        #expect(try await push(model, "calendar-changed") == .noData)
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        stub.setOffline(true)
        #expect(try await push(model, "calendar-changed") == .failed)
        #expect(titles(model) == ["Lunch"])
    }

    @Test func otherPushesAndPushesWhileNotConnectedFetchNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        #expect(try await push(model, nil) == .noData)
        #expect(try await push(model, "something-else") == .noData)
        try await bounded { await model.disconnect() }
        #expect(try await push(model, "calendar-changed") == .noData)
        #expect(stub.count(GoogleAPIStub.postEvents) == before)
    }

    @Test func pushesArrivingTogetherShareOneFetch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Lunch", "2026-11-19T20:00:00Z", "2026-11-19T21:00:00Z")], statuses: [nil]
        ))
        let outcomes = try await bounded {
            async let first = model.handlePush(type: "calendar-changed")
            async let second = model.handlePush(type: "calendar-changed")
            async let third = model.handlePush(type: "calendar-changed")
            return await [first, second, third]
        }
        #expect(outcomes == [.newData, .newData, .newData])
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 1)
    }

    @Test func aPushDuringTheFetchGetsOneMoreFetchAfterIt() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.hold(GoogleAPIStub.postEvents)
        let first = Task { await model.handlePush(type: "calendar-changed") }
        try await waitUntil { stub.outstanding(GoogleAPIStub.postEvents) == 1 }
        let second = Task { await model.handlePush(type: "calendar-changed") }
        let third = Task { await model.handlePush(type: "calendar-changed") }
        try await Task.sleep(for: .milliseconds(30))
        stub.release(GoogleAPIStub.postEvents)
        _ = try await bounded { await (first.value, second.value, third.value) }
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        #expect(stub.peak(GoogleAPIStub.postEvents) == 1)
    }

    @Test func aPushWaitsForARunningPollThenFetches() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        let before = stub.count(GoogleAPIStub.postEvents)
        stub.hold(GoogleAPIStub.postEvents)
        clock.advance(5)
        let poll = Task { await model.refresh() }
        try await waitUntil { stub.outstanding(GoogleAPIStub.postEvents) == 1 }
        let pushing = Task { await model.handlePush(type: "calendar-changed") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 1)
        stub.release(GoogleAPIStub.postEvents)
        try await bounded { await poll.value }
        _ = try await bounded { await pushing.value }
        #expect(stub.count(GoogleAPIStub.postEvents) == before + 2)
        #expect(stub.peak(GoogleAPIStub.postEvents) == 1)
    }

    @Test func aPushAnswersByItsDeadlineEvenIfTheFetchHangs() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context, pushDeadline: .milliseconds(300))
        stub.hold(GoogleAPIStub.postEvents)
        let started = ContinuousClock.now
        #expect(try await push(model, "calendar-changed") == .failed)
        #expect(ContinuousClock.now - started < .seconds(3))
        stub.release(GoogleAPIStub.postEvents)
    }

    @Test func theDeadlineIsInsideTheSystemsThirtySeconds() {
        #expect(GooglePushHandling.deadline < .seconds(30))
    }

    // MARK: Poll rate

    @Test func thePollIsFastWithoutAChannelAndSlowWithOne() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        #expect(model.pollInterval == .seconds(5))
        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(model.pollInterval == .seconds(60))
        // Channels that have ended no longer count once the app looks again.
        clock.advance(8 * 24 * 3600)
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.error(.serviceUnavailable, "push_unavailable"))
        model.appOpened()
        try await idle(model)
        #expect(model.pollInterval == .seconds(5))
    }

    @Test func eachPollTurnLooksAgainSoAnEndedChannelSpeedsThePollUp() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        model.pollTurn()
        #expect(model.pollInterval == .seconds(60))
        // The app stays open past the channels' end, with no open to look again.
        clock.advance(8 * 24 * 3600)
        #expect(model.pollInterval == .seconds(60))
        model.pollTurn()
        #expect(model.pollInterval == .seconds(5))
        #expect(!model.watch.isLive)
        // Looking sends nothing.
        try await idle(model)
        #expect(watches.count == 1)
        #expect(unwatches.isEmpty)
    }

    // MARK: Only a deployed (https) API

    /// The same steps against `wrangler dev` (http) and a deployed API (https).
    @Test(arguments: [false, true])
    func pushIsSetUpOnlyWithAnHTTPSServer(https: Bool) async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let registrations = Counter()
        let model = try await connected(
            context, registrations: registrations,
            server: https ? "https://example.test" : "http://localhost:8787"
        )
        #expect(model.connection == .connected)
        model.launched()
        model.appOpened()
        #expect(registrations.value == (https ? 1 : 0))

        model.registered(FakeDevice.token)
        try await idle(model)
        #expect(watches.count == (https ? 1 : 0))
        #expect(model.watch.isLive == https)
        #expect(model.pollInterval == (https ? .seconds(60) : .seconds(5)))

        let family = try #require(model.calendars.first { $0.calendarID == "family-id" })
        stub.answer(GoogleAPIStub.postWatch, GoogleAPIStub.watch([nil, "webhook_refused"], expiresAt: weekLater))
        model.setOn(family, true)
        try await idle(model)
        model.pollTurn()
        #expect(watches.count == (https ? 2 : 0))
        #expect(model.pollInterval == .seconds(5))  // Family has no channel either way
        #expect(model.watch.problem == nil)
        #expect((model.watchMessage(for: family) != nil) == https)

        try await bounded { await model.disconnect() }
        try await idle(model)
        #expect(unwatches.count == (https ? 1 : 0))
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(stub.peak(GoogleAPIStub.pushKey) <= 1)
    }

    @Test func overHTTPChannelsOnRecordFromAnEarlierRunAreNeitherLiveNorUnwatched() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let fingerprint = GoogleWatchKeeper.fingerprint(calendars: ["me@example.test"], device: FakeDevice.token, environment: .sandbox)
        context.insert(GoogleWatchRecord(fingerprint: fingerprint, expiresAt: instant(weekLater), complete: true))
        try context.save()
        let model = try await connected(context, server: "http://localhost:8787")
        model.registered(FakeDevice.token)
        model.appOpened()
        model.pollTurn()
        try await idle(model)
        #expect(!model.watch.isLive)
        #expect(model.pollInterval == .seconds(5))
        #expect(!model.watch.mayNeedUnwatch)
        #expect(!model.watch.channelsMayBeLeft)
        // An hour on, the token in memory has expired: Disconnect asks Google
        // for no fresh one, since no unwatch would be sent.
        clock.advance(3600)
        let refreshesBefore = endpoint.sent(grant: "refresh_token").count
        try await bounded { await model.disconnect() }
        #expect(endpoint.sent(grant: "refresh_token").count == refreshesBefore)
        #expect(unwatches.isEmpty)
        #expect(watches.isEmpty)
        #expect(endpoint.revoked == [FakeGoogle.refresh])
    }

    @Test func overHTTPAnEndedSignInSendsNoUnwatch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context, server: "http://localhost:8787")
        model.registered(FakeDevice.token)
        try await idle(model)
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        try await bounded { await model.refresh() }
        #expect(model.connection == .expired)
        try await Task.sleep(for: .milliseconds(50))
        try await idle(model)
        #expect(unwatches.isEmpty)
        #expect(watches.isEmpty)
    }

    // MARK: Disconnect does not wait long

    @Test func disconnectRevokesAfterTheCapWhileTheUnwatchIsStillOut() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = InMemoryGoogleTokenStore()
        let model = try await connected(context, store: store, unwatchWait: .milliseconds(200))
        model.registered(FakeDevice.token)
        try await idle(model)
        try #require(model.watch.isLive)
        stub.hold(GoogleAPIStub.postUnwatch)
        let started = ContinuousClock.now
        try await bounded { await model.disconnect() }
        #expect(ContinuousClock.now - started < .seconds(5))
        // Revoked while the unwatch is still out; the unwatch is not cancelled.
        #expect(endpoint.revoked == [FakeGoogle.refresh])
        #expect(stub.outstanding(GoogleAPIStub.postUnwatch) == 1)
        #expect(store.stored == nil)
        stub.release(GoogleAPIStub.postUnwatch)
        try await idle(model)
        try #require(unwatches.count == 1)
        #expect(unwatches[0].token == FakeGoogle.access)
        #expect(stub.peak(GoogleAPIStub.pushKey) == 1)
        #expect(try context.fetch(FetchDescriptor<GoogleWatchRecord>()).isEmpty)
    }

    // MARK: Connecting again while the old connection is being stopped

    @Test func connectingAgainWithNoCalendarOnDuringAWatchKeepsTheQueuedUnwatch() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context, unwatchWait: .milliseconds(200))
        stub.hold(GoogleAPIStub.postWatch)
        model.registered(FakeDevice.token)
        try await waitUntil { stub.outstanding(GoogleAPIStub.postWatch) == 1 }
        // Disconnect queues the unwatch behind the watch, then revokes after the cap.
        try await bounded { await model.disconnect() }
        #expect(unwatches.isEmpty)
        let signIn = redirect()
        try await bounded { await model.connect(signIn: signIn) }
        #expect(model.connection == .connected)
        let me = try #require(model.calendars.first { $0.calendarID == "me@example.test" })
        model.setOn(me, false)
        stub.release(GoogleAPIStub.postWatch)
        try await idle(model)
        // The watch out at Disconnect made channels; the unwatch still stops them.
        try #require(unwatches.count == 1)
        #expect(unwatches[0].token == FakeGoogle.access)
        #expect(unwatches[0].deviceToken == FakeDevice.hex)
        #expect(watches.count == 1)
        #expect(stub.peak(GoogleAPIStub.pushKey) == 1)
    }

    @Test func aConnectFinishedWhileDisconnectRenewsItsTokenKeepsItsChannels() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await watching(context)
        // The token in memory has expired, so Disconnect asks for a fresh one
        // for the unwatch, and that answer is slow.
        clock.advance(3600)
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        endpoint.hold(grant: "refresh_token")
        let disconnecting = Task { await model.disconnect() }
        try await waitUntil { endpoint.sent(grant: "refresh_token").count == 1 }
        let signIn = redirect()
        try await bounded { await model.connect(signIn: signIn) }
        try await idle(model)
        #expect(watches.count == 2)
        #expect(model.watch.isLive)
        endpoint.release()
        try await bounded { await disconnecting.value }
        try await idle(model)
        // The new connection's channels and keeper state are left alone.
        #expect(unwatches.isEmpty)
        #expect(watches.count == 2)
        #expect(model.watch.isLive)
        #expect(model.pollInterval == .seconds(60))
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
        try await bounded { await model.disconnect() }
        #expect(!model.isConnecting)
        #expect(model.connection == .notConnected)

        // A new Connect started meanwhile is not cleared by the old one ending.
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        let second = Task { await model.connect(signIn: redirect()) }
        try await waitUntil { endpoint.sent(grant: "authorization_code").count == 2 }
        #expect(model.isConnecting)
        endpoint.release()
        try await bounded { await connecting.value }
        _ = try await bounded { await second.value }
        #expect(!model.isConnecting)
    }

    @Test func settingsRestartsItsListLoadWhenAConnectEnds() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = model(context, store: InMemoryGoogleTokenStore())
        #expect(!model.listLoadKey)
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("me@example.test", "Me", true)]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        endpoint.hold(grant: "authorization_code")
        let connecting = Task { await model.connect(signIn: redirect()) }
        try await waitUntil { endpoint.sent(grant: "authorization_code").count == 1 }
        #expect(!model.listLoadKey)
        endpoint.release()
        try await bounded { await connecting.value }
        #expect(model.listLoadKey)
        // The list Connect has just read is not read again at once.
        let lists = stub.count(GoogleAPIStub.getCalendars)
        try await bounded { await model.loadCalendarsWhileShown() }
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists)
    }

    @Test func aFailedFirstListLoadIsTriedAgainWhileSettingsIsOpen() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        stub.answer(GoogleAPIStub.getCalendars,
                    GoogleAPIStub.error(.badGateway, "google_unavailable"),
                    GoogleAPIStub.calendars([("me@example.test", "Me", true)]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        let model = model(context, store: InMemoryGoogleTokenStore())
        let signIn = redirect()
        try await bounded { await model.connect(signIn: signIn) }
        #expect(model.connection == .connected)
        #expect(model.calendars.isEmpty)
        #expect(model.retryNotBefore != nil)  // a back-off
        #expect(model.listHeld)  // Settings says the list will load, not that it is loading
        #expect(model.listLoadKey)  // and restarts its load now that Connect has ended

        // Settings opens during the back-off: the missing list is read anyway.
        try await bounded { await model.loadCalendarsWhileShown() }
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
        let signIn = redirect()
        try await bounded { await model.connect(signIn: signIn) }
        #expect(model.calendars.isEmpty)
        #expect(model.statusProblem == .rateLimited)

        // Our 429 is honoured even with no list: one ask is held and noted.
        let lists = stub.count(GoogleAPIStub.getCalendars)
        let wait = try await bounded { await model.loadCalendars() }
        #expect(wait != nil)
        #expect(model.listHeld)
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists)

        // While Settings stays open, the list is read once the delay has passed
        // (the test's sleep moves the clock).
        try await bounded { await model.loadCalendarsWhileShown() }
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists + 1)
        #expect(model.calendars.map(\.calendarID) == ["me@example.test"])
        #expect(!model.listHeld)
    }

    @Test func aHeldReloadOfAListAlreadyShownIsNoted() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let model = try await connected(context)
        clock.advance(5)
        stub.setOffline(true)
        try await bounded { await model.refresh() }
        #expect(model.retryNotBefore != nil)
        stub.setOffline(false)
        let lists = stub.count(GoogleAPIStub.getCalendars)
        #expect(try await bounded { await model.loadCalendars() } != nil)
        #expect(model.listHeld)
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists)
        try await bounded { await model.loadCalendarsWhileShown() }
        #expect(stub.count(GoogleAPIStub.getCalendars) == lists + 1)
        #expect(!model.listHeld)
    }
}
