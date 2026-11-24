import Foundation
import HTTPTypes
import SwiftData
import Testing

@testable import Seasign

/// Writes that can be made to fail, standing in for a full disk.
@MainActor
private final class FailingWrites {
    struct Failure: Error {}
    var fail = false

    func commit(_ context: ModelContext) throws {
        if fail { throw Failure() }
        try context.save()
    }
}

/// A clock and time zone the tests can move.
private final class AIClock: @unchecked Sendable {
    private let lock = NSLock()
    /// 18:05 on Sunday 15 November 2026 in New York.
    private var value = instant("2026-11-15T23:05:00Z")
    private var zoneValue = TimeZone(identifier: "America/New_York")!
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var zone: TimeZone {
        get { lock.withLock { zoneValue } }
        set { lock.withLock { zoneValue = newValue } }
    }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@Suite @MainActor struct AISearchModelTests {
    private let clock = AIClock()
    private let stub = DiscoverStub()
    private let feedStub = FeedStub()

    private struct Setup {
        var context: ModelContext
        var feed: FeedModel
        var ai: AISearchModel
        var keys: InMemoryKeyStore
    }

    /// A model with AI search configured and on unless told otherwise.
    private func setup(
        context: ModelContext? = nil,
        key: String? = fakeKey,
        interests: String = "tide pools, new telescopes",
        on: Bool = true,
        cap: Int = 3
    ) throws -> Setup {
        let context = try context ?? inMemoryContext()
        let clock = clock
        let feed = FeedModel(api: stubbedFeedAPI(feedStub), context: context, now: { clock.now })
        let keys = InMemoryKeyStore(key.flatMap(APIKey.init(typed:)))
        let ai = AISearchModel(
            api: stubbedDiscoverAPI(stub),
            context: context,
            keyStore: keys,
            feed: feed,
            now: { clock.now },
            zone: { clock.zone }
        )
        ai.setInterests(interests)
        ai.setDailyCap(cap)
        if on { #expect(ai.setMode(.aiSearch)) }
        return Setup(context: context, feed: feed, ai: ai, keys: keys)
    }

    // MARK: My list

    /// Acceptance criterion: with the toggle on Use My List no
    /// `/v1/discover` call is made, by any path.
    @Test func useMyListNeverCallsDiscover() async throws {
        let s = try setup(on: false)
        #expect(s.ai.mode == .myList)
        await s.ai.refreshIfDue()
        await s.ai.searchNow()
        clock.advance(2 * 86_400)
        await s.ai.refreshIfDue()
        await s.ai.searchNow()
        #expect(!s.ai.canSearchNow)
        #expect(stub.count == 0)

        // Switched on, then back off: nothing more is sent after that.
        #expect(s.ai.setMode(.aiSearch))
        await s.ai.searchNow()
        #expect(stub.count == 1)
        s.ai.setMode(.myList)
        clock.advance(2 * 86_400)
        await s.ai.refreshIfDue()
        await s.ai.searchNow()
        #expect(stub.count == 1)
    }

    @Test func theToggleNeedsAKeyAndAnInterest() throws {
        let noKey = try setup(key: nil, on: false)
        #expect(!noKey.ai.setMode(.aiSearch))
        #expect(noKey.ai.mode == .myList)
        #expect(noKey.ai.precondition == .needsKey)

        let noInterests = try setup(interests: " , ", on: false)
        #expect(!noInterests.ai.setMode(.aiSearch))
        #expect(noInterests.ai.precondition == .needsInterests)

        try noKey.ai.saveKey(fakeKey)
        #expect(noKey.ai.setMode(.aiSearch))
        #expect(noKey.ai.isActive)
    }

    @Test func settingsPersistInTheUserStoreWithoutTheKey() throws {
        let context = try inMemoryContext()
        let first = try setup(context: context, cap: 5)
        first.ai.setProvider(.perplexity)
        let row = try #require(try context.fetch(FetchDescriptor<Settings>()).first)
        #expect(row.aiModeRaw == "ai_search")
        #expect(row.aiProviderRaw == "perplexity")
        #expect(row.aiInterestsText == "tide pools, new telescopes")
        #expect(row.aiDailyCap == 5)

        // Relaunch with the same store and Keychain.
        let clock = clock
        let again = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: context, keyStore: first.keys,
            feed: first.feed, now: { clock.now }, zone: { clock.zone }
        )
        #expect(again.mode == .aiSearch)
        #expect(again.provider == .perplexity)
        #expect(again.dailyCap == 5)
        #expect(again.hasKey)
        #expect(again.isActive)
    }

    // MARK: Counting and the cap

    /// Acceptance criterion: searches stop once the daily cap is reached.
    @Test func searchesStopAtTheCap() async throws {
        let s = try setup(cap: 2)
        await s.ai.searchNow()
        await s.ai.searchNow()
        #expect(s.ai.usedToday == 2)
        #expect(s.ai.usageLine == "2 of 2 searches used today")
        #expect(s.ai.capReached)
        #expect(!s.ai.canSearchNow)
        await s.ai.searchNow()
        clock.advance(10 * 3600)
        await s.ai.refreshIfDue()
        #expect(stub.count == 2)
    }

    /// A failed or timed-out search may still be billed, so it counts.
    @Test(arguments: [
        (HTTPResponse.Status(code: 402), "quota_exceeded"),
        (.init(code: 429), "rate_limited"),
        (.init(code: 500), "internal_error"),
        (.init(code: 502), "provider_error"),
        (.init(code: 504), "timeout"),
    ])
    func failedSearchesCount(status: HTTPResponse.Status, code: String) async throws {
        let s = try setup()
        stub.answer(status, discoverErrorJSON(code))
        await s.ai.searchNow()
        #expect(s.ai.usedToday == 1)
        #expect(s.ai.problem != nil)
    }

    @Test func aNetworkFailureCounts() async throws {
        let s = try setup()
        stub.fail(with: URLError(.timedOut))
        await s.ai.searchNow()
        #expect(s.ai.usedToday == 1)
        #expect(s.ai.problem == .unavailable)
    }

    /// 400 and 401 prove no provider call was billed: the search is given back.
    @Test(arguments: [
        (HTTPResponse.Status(code: 400), "invalid_request", AISearchProblem.invalidRequest),
        (.init(code: 401), "invalid_key", .invalidKey),
    ])
    func refusedRequestsAreGivenBack(status: HTTPResponse.Status, code: String, problem: AISearchProblem) async throws {
        let s = try setup()
        stub.answer(status, discoverErrorJSON(code))
        await s.ai.searchNow()
        #expect(stub.count == 1)
        #expect(s.ai.usedToday == 0)
        #expect(s.ai.problem == problem)
    }

    /// Acceptance criterion: Seasign's own rate limit (429 with
    /// `Retry-After`) refused the search before any provider call, so it is
    /// given back and gets its own message, which does not blame the provider.
    @Test func ourRateLimitIsGivenBackWithItsOwnMessage() async throws {
        let s = try setup()
        stub.answer(.init(code: 429), discoverErrorJSON("rate_limited"), retryAfter: "60")
        await s.ai.searchNow()
        #expect(stub.count == 1)
        #expect(s.ai.usedToday == 0)
        #expect(s.ai.problem == .limitedByServer)
        #expect(s.ai.problem?.message == "Too many searches from this network. Try again in a minute.")
        // Not the key's fault: automatic searches are not stopped.
        #expect(!s.ai.keyRefused)
        let row = try #require(try s.context.fetch(FetchDescriptor<Settings>()).first)
        #expect(row.aiKeyRefused == nil)
        #expect(row.aiLastProblemRaw == "server_rate_limited")
        // Search now stays allowed.
        #expect(s.ai.canSearchNow)
    }

    /// Acceptance criterion: the provider's 429 (no `Retry-After`, or one
    /// that is not a number) may have been billed, so it still counts.
    @Test(arguments: [nil, "soon"] as [String?])
    func theProvidersRateLimitStillCounts(retryAfter: String?) async throws {
        let s = try setup()
        stub.answer(.init(code: 429), discoverErrorJSON("rate_limited"), retryAfter: retryAfter)
        await s.ai.searchNow()
        #expect(s.ai.usedToday == 1)
        #expect(s.ai.problem == .rateLimited)
        #expect(s.ai.problem?.message == "Your provider is limiting searches right now. Try again later.")
        #expect(!s.ai.keyRefused)
        #expect(s.ai.retryNotBefore == nil)
    }

    /// Automatic searches wait for the delay Seasign's limit asked for (and
    /// the spacing, which runs from when the refused search was sent).
    @Test func ourRateLimitHoldsOffAutomaticSearches() async throws {
        let s = try setup(cap: 20)
        stub.answer(.init(code: 429), discoverErrorJSON("rate_limited"), retryAfter: "120")
        let sentAt = clock.now
        await s.ai.searchNow()
        #expect(s.ai.retryNotBefore == sentAt.addingTimeInterval(120))
        stub.answer(.ok, discoverJSONThreeItems)
        // Take the spacing out of the way, so only the delay can hold.
        let row = try #require(try s.context.fetch(FetchDescriptor<Settings>()).first)
        row.aiLastSentAt = sentAt.addingTimeInterval(-86_400)
        try s.context.save()
        clock.advance(90)
        await s.ai.refreshIfDue()
        #expect(stub.count == 1)
        clock.advance(31)
        await s.ai.refreshIfDue()
        #expect(stub.count == 2)
        #expect(s.ai.problem == nil)
        #expect(s.ai.usedToday == 1)
    }

    /// "Search now" is not held by the delay; it just asks again.
    @Test func searchNowIsNotHeldByOurRateLimit() async throws {
        let s = try setup()
        stub.answer(.init(code: 429), discoverErrorJSON("rate_limited"), retryAfter: "60")
        await s.ai.searchNow()
        stub.answer(.ok, discoverJSONThreeItems)
        clock.advance(10)
        await s.ai.searchNow()
        #expect(stub.count == 2)
        #expect(s.ai.problem == nil)
        #expect(s.ai.usedToday == 1)
    }

    /// A delay from the server is kept within 1 to 3600 seconds.
    @Test func anOutlandishDelayIsClamped() async throws {
        let s = try setup()
        stub.answer(.init(code: 429), discoverErrorJSON("rate_limited"), retryAfter: "999999")
        let sentAt = clock.now
        await s.ai.searchNow()
        #expect(s.ai.retryNotBefore == sentAt.addingTimeInterval(3600))
        #expect(s.ai.usedToday == 0)
    }

    /// The count is written before the request leaves.
    @Test func theSearchIsCountedWhenSent() async throws {
        let s = try setup()
        stub.hold(true)
        let search = Task { await s.ai.searchNow() }
        while stub.waitingCount == 0 { await Task.yield() }
        #expect(s.ai.usedToday == 1)
        #expect(try s.context.fetch(FetchDescriptor<SearchCount>()).map(\.count) == [1])
        stub.release()
        await search.value
        #expect(s.ai.usedToday == 1)
    }

    /// Two refreshes that race never pass the cap: the second is dropped
    /// while the first is in flight.
    @Test func racingSearchesAreSerialised() async throws {
        let s = try setup(cap: 1)
        stub.hold(true)
        let first = Task { await s.ai.searchNow() }
        let second = Task { await s.ai.refreshIfDue() }
        let third = Task { await s.ai.searchNow() }
        while stub.waitingCount == 0 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        stub.release()
        await first.value
        await second.value
        await third.value
        #expect(stub.count == 1)
        #expect(s.ai.usedToday == 1)
    }

    @Test func automaticSearchesAreSpacedThroughTheDay() async throws {
        let s = try setup(cap: 3)
        await s.ai.refreshIfDue()
        #expect(stub.count == 1)
        clock.advance(7 * 3600)
        await s.ai.refreshIfDue()
        #expect(stub.count == 1)
        // "Search now" ignores the spacing.
        await s.ai.searchNow()
        #expect(stub.count == 2)
        // The spacing runs from the last search sent.
        clock.advance(7 * 3600)
        await s.ai.refreshIfDue()
        #expect(stub.count == 2)
        clock.advance(3600)
        await s.ai.refreshIfDue()
        #expect(stub.count == 3)
    }

    @Test func theSpacingSurvivesARelaunch() async throws {
        let s = try setup()
        await s.ai.refreshIfDue()
        let clock = clock
        let again = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: s.keys,
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        clock.advance(3600)
        await again.refreshIfDue()
        #expect(stub.count == 1)
        #expect(again.usedToday == 1)
    }

    /// The count is per local calendar day: a new day starts at midnight in
    /// the zip's (or phone's) zone, and a 400/401 is given back to the day it
    /// was charged to.
    @Test func theCountStartsAgainAtLocalMidnight() async throws {
        clock.now = instant("2026-11-16T04:00:00Z") // 23:00 on the 15th in New York
        let s = try setup(cap: 2)
        await s.ai.searchNow()
        await s.ai.searchNow()
        #expect(s.ai.capReached)
        clock.now = instant("2026-11-16T04:59:00Z") // 23:59
        await s.ai.searchNow()
        #expect(stub.count == 2)
        clock.now = instant("2026-11-16T05:01:00Z") // 00:01 on the 16th
        #expect(s.ai.usedToday == 0)
        await s.ai.searchNow()
        #expect(stub.count == 3)
        #expect(s.ai.counts == ["2026-11-15": 2, "2026-11-16": 1])
    }

    @Test func aRefundAfterMidnightGoesToTheDayCharged() async throws {
        clock.now = instant("2026-11-16T04:59:00Z") // 23:59 on the 15th in New York
        let s = try setup()
        stub.answer(.init(code: 400), discoverErrorJSON("invalid_request"))
        stub.hold(true)
        let search = Task { await s.ai.searchNow() }
        while stub.waitingCount == 0 { await Task.yield() }
        clock.now = instant("2026-11-16T05:01:00Z")
        stub.release()
        await search.value
        #expect(s.ai.counts["2026-11-15"] == 0)
        #expect(s.ai.counts["2026-11-16"] == nil)
    }

    /// The day follows the time zone in use: a zip in another zone (or a
    /// move) changes which day "today" is, and the spacing, measured in
    /// absolute time, still holds for automatic searches.
    @Test func theDayFollowsTheTimeZone() async throws {
        clock.now = instant("2026-11-16T04:00:00Z") // 23:00 on the 15th in New York, 13:00 on the 16th in Tokyo
        let s = try setup(cap: 1)
        await s.ai.searchNow()
        #expect(s.ai.capReached)
        clock.zone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(s.ai.today == "2026-11-16")
        #expect(s.ai.usedToday == 0)
        await s.ai.refreshIfDue()
        #expect(stub.count == 1) // 24 h spacing at a cap of 1
        await s.ai.searchNow()
        #expect(stub.count == 2)
        #expect(s.ai.capReached)
        clock.zone = TimeZone(identifier: "America/New_York")!
        #expect(s.ai.capReached)
    }

    @Test func theTimeZoneSentIsAnIANAName() async throws {
        let s = try setup()
        clock.zone = TimeZone(secondsFromGMT: -5 * 3600)!
        await s.ai.searchNow()
        clock.zone = TimeZone(identifier: "America/Chicago")!
        await s.ai.searchNow()
        let bodies = stub.requests.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        #expect(bodies.count == 2)
        #expect(bodies[0]["timezone"] == nil)
        #expect(bodies[1]["timezone"] as? String == "America/Chicago")
        #expect(bodies[1]["interests"] as? [String] == ["tide pools", "new telescopes"])
    }

    /// If the count cannot be written, nothing is sent: the cap could not be kept.
    @Test func aCountThatCannotBeWrittenSendsNothing() async throws {
        let context = try inMemoryContext()
        let clock = clock
        let feed = FeedModel(api: stubbedFeedAPI(feedStub), context: context, now: { clock.now })
        let failing = FailingWrites()
        let ai = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: context, keyStore: InMemoryKeyStore(APIKey(typed: fakeKey)),
            feed: feed, now: { clock.now }, zone: { clock.zone }, commit: failing.commit
        )
        ai.setInterests("tide pools")
        #expect(ai.setMode(.aiSearch))
        failing.fail = true
        await ai.searchNow()
        #expect(stub.count == 0)
        #expect(ai.problem == .countNotSaved)
        #expect(ai.usedToday == 0)
        #expect(try context.fetch(FetchDescriptor<SearchCount>()).isEmpty)
    }

    /// The key never leaves the phone it was saved on, so a store restored
    /// elsewhere arrives with AI search on and no key: the pill goes back to
    /// Use My List. So does a store whose interests are empty.
    @Test func aRelaunchWithoutTheKeyShowsUseMyList() throws {
        let s = try setup()
        #expect(s.ai.mode == .aiSearch)
        let clock = clock
        let restored = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: InMemoryKeyStore(),
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        #expect(restored.mode == .myList)
        #expect(!restored.isActive)
        #expect(!s.feed.showsAI)
        #expect(try s.context.fetch(FetchDescriptor<Settings>()).first?.aiModeRaw == "my_list")
    }

    /// A Keychain that cannot be read right now (say, before the first
    /// unlock) does not change the user's choice.
    @Test func anUnreadableKeychainAtLaunchLeavesTheChoiceAlone() throws {
        let s = try setup()
        let clock = clock
        let locked = InMemoryKeyStore(APIKey(typed: fakeKey))
        locked.setFailure(KeychainFailure(status: -25308))
        let again = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: locked,
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        #expect(again.mode == .aiSearch)
        #expect(again.problem == .keyUnreadable)
        #expect(try s.context.fetch(FetchDescriptor<Settings>()).first?.aiModeRaw == "ai_search")
    }

    /// Before the first unlock the Keychain cannot be read. That is not "no
    /// key": the pill keeps its place, Settings does not ask for the key,
    /// nothing is sent, and once the Keychain answers (the app becomes
    /// active, Settings opens, or the next search attempt) all is as before.
    @Test func aKeychainLockedAtLaunchIsNotAMissingKeyAndIsReadAgain() async throws {
        let s = try setup()
        let clock = clock
        let locked = InMemoryKeyStore(APIKey(typed: fakeKey))
        locked.setFailure(KeychainFailure(status: -25308))
        let ai = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: locked,
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        #expect(ai.keyStatus == .unknown)
        #expect(!ai.hasKey)
        #expect(ai.precondition == .keyUnreadable)
        #expect(ai.precondition != .needsKey)
        #expect(ai.mode == .aiSearch)
        #expect(!ai.canSearchNow)
        // Never sent while unknown, by either trigger.
        await ai.searchNow()
        await ai.refreshIfDue()
        #expect(stub.count == 0)
        #expect(ai.usedToday == 0)
        #expect(ai.keyStatus == .unknown)

        // Unlocked: becoming active re-reads it.
        locked.setFailure(nil)
        ai.refreshKeyStatus()
        #expect(ai.keyStatus == .saved)
        #expect(ai.problem == nil)
        #expect(ai.isActive)
        #expect(s.feed.showsAI)
        await ai.refreshIfDue()
        #expect(stub.count == 1)
    }

    /// The search attempt itself asks the Keychain again, so a key locked
    /// away at launch is used once it can be read, even with no other recheck.
    @Test func aSearchAttemptReadsTheKeychainAgain() async throws {
        let s = try setup()
        let clock = clock
        let locked = InMemoryKeyStore(APIKey(typed: fakeKey))
        locked.setFailure(KeychainFailure(status: -25308))
        let ai = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: locked,
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        locked.setFailure(nil)
        await ai.refreshIfDue()
        #expect(stub.count == 1)
        #expect(ai.keyStatus == .saved)
    }

    /// A recheck that finds the Keychain readable and empty applies the
    /// rule a launch would have: back to Use My List.
    @Test func aRecheckThatFindsNoKeyMovesTheToggleBack() throws {
        let s = try setup()
        let clock = clock
        let locked = InMemoryKeyStore()
        locked.setFailure(KeychainFailure(status: -25308))
        let ai = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: locked,
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        #expect(ai.mode == .aiSearch)
        locked.setFailure(nil)
        ai.refreshKeyStatus()
        #expect(ai.keyStatus == .missing)
        #expect(ai.precondition == .needsKey)
        #expect(ai.mode == .myList)
        #expect(try s.context.fetch(FetchDescriptor<Settings>()).first?.aiModeRaw == "my_list")
    }

    /// A key that becomes unreadable after launch stops searches without
    /// counting one or switching anything off.
    @Test func aKeyThatBecomesUnreadableIsUnknownNotMissing() async throws {
        let s = try setup()
        #expect(s.ai.keyStatus == .saved)
        s.keys.setFailure(KeychainFailure(status: -25308))
        s.ai.refreshKeyStatus()
        #expect(s.ai.keyStatus == .unknown)
        #expect(s.ai.mode == .aiSearch)
        #expect(s.ai.precondition == .keyUnreadable)
        #expect(!s.feed.showsAI)
        s.keys.setFailure(nil)
        s.ai.refreshKeyStatus()
        #expect(s.ai.isActive)
        #expect(s.feed.showsAI)
    }

    /// An unreadable-key problem kept from an earlier launch goes once the key reads.
    @Test func aStaleUnreadableKeyProblemIsClearedWhenTheKeyReads() throws {
        let s = try setup()
        s.keys.setFailure(KeychainFailure(status: -25308))
        s.ai.refreshKeyStatus()
        #expect(try s.context.fetch(FetchDescriptor<Settings>()).first?.aiLastProblemRaw == "key_unreadable")
        s.keys.setFailure(nil)
        let clock = clock
        let again = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: s.keys,
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        #expect(again.problem == nil)
        #expect(try s.context.fetch(FetchDescriptor<Settings>()).first?.aiLastProblemRaw == nil)
    }

    @Test func anUnreadableKeySendsNothingAndCountsNothing() async throws {
        let s = try setup()
        s.keys.setFailure(KeychainFailure(status: -25300))
        await s.ai.searchNow()
        #expect(stub.count == 0)
        #expect(s.ai.problem == .keyUnreadable)
        #expect(s.ai.usedToday == 0)
    }

    // MARK: Invalid key

    @Test func anInvalidKeyStopsAutomaticSearchesUntilTheKeyOrProviderChanges() async throws {
        let s = try setup(cap: 20)
        stub.answer(.init(code: 401), discoverErrorJSON("invalid_key"))
        await s.ai.refreshIfDue()
        #expect(s.ai.keyRefused)
        #expect(s.ai.problem == .invalidKey)
        stub.answer(.ok, discoverJSONThreeItems)
        clock.advance(86_400)
        await s.ai.refreshIfDue()
        #expect(stub.count == 1)

        // A new provider lifts it.
        s.ai.setProvider(.openai)
        #expect(!s.ai.keyRefused)
        await s.ai.refreshIfDue()
        #expect(stub.count == 2)

        // Refused again, then a new key lifts it.
        stub.answer(.init(code: 401), discoverErrorJSON("invalid_key"))
        clock.advance(86_400)
        await s.ai.refreshIfDue()
        #expect(s.ai.keyRefused)
        try s.ai.saveKey("test-key-not-real-1111")
        #expect(!s.ai.keyRefused)
        #expect(s.ai.problem == nil)
        stub.answer(.ok, discoverJSONThreeItems)
        clock.advance(2 * 3600)
        await s.ai.refreshIfDue()
        #expect(stub.count == 4)
    }

    @Test func theStopSurvivesARelaunch() async throws {
        let s = try setup()
        stub.answer(.init(code: 401), discoverErrorJSON("invalid_key"))
        await s.ai.refreshIfDue()
        let clock = clock
        let again = AISearchModel(
            api: stubbedDiscoverAPI(stub), context: s.context, keyStore: s.keys,
            feed: s.feed, now: { clock.now }, zone: { clock.zone }
        )
        #expect(again.keyRefused)
        #expect(again.problem == .invalidKey)
        clock.advance(2 * 86_400)
        await again.refreshIfDue()
        #expect(stub.count == 1)
    }

    /// A 401 for a key that was replaced while the search was in flight does
    /// not stop searches with the new key.
    @Test func aRefusalOfAReplacedKeyDoesNotStopTheNewOne() async throws {
        let s = try setup()
        stub.answer(.init(code: 401), discoverErrorJSON("invalid_key"))
        stub.hold(true)
        let search = Task { await s.ai.searchNow() }
        while stub.waitingCount == 0 { await Task.yield() }
        try s.ai.saveKey("test-key-not-real-2222")
        stub.release()
        await search.value
        #expect(!s.ai.keyRefused)
    }

    // MARK: Blending

    @Test func foundItemsAreBlendedCleanedAndLabelled() async throws {
        let s = try setup()
        await s.ai.searchNow()
        // The http link is dropped; the undated item is dated when searched and first seen.
        let ai = s.feed.entries.filter(\.isAI)
        #expect(ai.map(\.title) == [
            "A small telescope caught a comet's tail splitting",
            "Tide pools are filling with warm-water visitors",
        ])
        let comet = ai[0]
        #expect(comet.published == instant("2026-11-15T23:00:00Z"))
        #expect(comet.dateSource == .firstSeen)
        #expect(comet.source == "sky.example.net")
        #expect(comet.siteID == nil)
        #expect(comet.category == "")
        #expect(comet.categoryChoice.label == "AI")
        #expect(comet.provider == .anthropic)
        let pools = ai[1]
        #expect(pools.interest == "tide pools")
        #expect(pools.categoryChoice == CategoryChoice(name: "tide pools", isAI: true))
        #expect(pools.dateSource == .published)
        #expect(s.ai.lastSearch?.found == 3)
        // Both are on Today.
        let today = s.feed.headlines(now: clock.now, timeZone: clock.zone)
        #expect(today.filter(\.isAI).count == 2)
    }

    @Test func aFollowedSitesItemWinsAndIsNotRelabelled() async throws {
        let s = try setup()
        // The site has the tide pools story already, spelled with www and a slash.
        feedStub.resolve("https://coast.example.org/", #"{"ok":true,"title":"Coast Notes","url":"https://coast.example.org/","mode":"links","linkCount":4}"#)
        feedStub.site("https://coast.example.org/", .items([
            StubItem(title: "Tide pools (site's title)", link: "https://www.coast.example.org/2026/tide-pool-visitors/", published: "2026-11-15T19:00:00Z"),
        ]))
        try await s.feed.add(address: "coast.example.org/", category: "Local")
        await s.ai.searchNow()
        let pools = s.feed.entries.filter { $0.title.hasPrefix("Tide pools") }
        #expect(pools.count == 1)
        #expect(pools.first?.isAI == false)
        #expect(pools.first?.title == "Tide pools (site's title)")
        #expect(pools.first?.category == "Local")
    }

    @Test func aSiteThatLaterHasTheAIFoundLinkTakesItOver() async throws {
        let s = try setup()
        await s.ai.searchNow()
        #expect(s.feed.entries.contains { $0.link == "https://coast.example.org/2026/tide-pool-visitors" && $0.isAI })
        feedStub.resolve("https://coast.example.org/", #"{"ok":true,"title":"Coast Notes","url":"https://coast.example.org/","mode":"links","linkCount":4}"#)
        feedStub.site("https://coast.example.org/", .items([
            StubItem(title: "Tide pools (site)", link: "https://coast.example.org/2026/tide-pool-visitors", published: "2026-11-15T19:00:00Z"),
            StubItem(title: "Comet (site)", link: "https://www.sky.example.net/comet-tail/", published: "2026-11-15T18:00:00Z"),
        ]))
        try await s.feed.add(address: "coast.example.org/", category: "Local")
        let rows = try s.context.fetch(FetchDescriptor<FeedItem>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.origin == .site })
        #expect(s.feed.entries.allSatisfy { !$0.isAI })
        // Searching again does not bring an AI copy back.
        await s.ai.searchNow()
        #expect(try s.context.fetch(FetchDescriptor<FeedItem>()).count == 2)
    }

    @Test func anUndatedItemKeepsItsFirstSeenDateAcrossSearches() async throws {
        let s = try setup()
        await s.ai.searchNow()
        stub.answer(.ok, discoverJSONThreeItems.replacingOccurrences(of: "2026-11-15T23:00:00Z", with: "2026-11-16T02:00:00Z"))
        clock.advance(3 * 3600)
        await s.ai.searchNow()
        let comet = try #require(s.feed.entries.first { $0.link == "https://sky.example.net/comet-tail" })
        #expect(comet.published == instant("2026-11-15T23:00:00Z"))
    }

    @Test func aiItemsArePrunedAfterSevenDaysButNotWithSites() async throws {
        let s = try setup()
        await s.ai.searchNow()
        #expect(s.feed.entries.filter(\.isAI).count == 2)
        // Pruning by followed sites (there are none) leaves them alone.
        await s.feed.refresh(force: true)
        #expect(s.feed.entries.filter(\.isAI).count == 2)
        clock.now = instant("2026-11-22T20:30:00Z")
        let relaunched = FeedModel(api: stubbedFeedAPI(feedStub), context: s.context, now: { [clock] in clock.now })
        relaunched.showsAI = true
        // The 20:00Z item is 7 days and 30 minutes old; the comet (23:00Z) is not yet.
        #expect(relaunched.entries.map(\.link) == ["https://sky.example.net/comet-tail"])
    }

    // MARK: Hiding

    @Test func useMyListHidesAIItemsAtOnceAndKeepsThemCached() async throws {
        let s = try setup()
        await s.ai.searchNow()
        #expect(s.feed.entries.contains { $0.isAI })
        s.ai.setMode(.myList)
        #expect(!s.feed.entries.contains { $0.isAI })
        #expect(!s.feed.headlines(now: clock.now, timeZone: clock.zone).contains { $0.isAI })
        #expect(HistoryList.visible(s.feed.entries, now: clock.now, query: ArticleQuery()).allSatisfy { !$0.isAI })
        #expect(try s.context.fetch(FetchDescriptor<FeedItem>()).count == 2)
        // Back on: shown again without another search.
        #expect(s.ai.setMode(.aiSearch))
        #expect(s.feed.entries.filter(\.isAI).count == 2)
        #expect(stub.count == 1)
    }

    @Test func removingTheKeyHidesAIItemsAndTurnsAISearchOff() async throws {
        let s = try setup()
        await s.ai.searchNow()
        try s.ai.removeKey()
        #expect(!s.ai.hasKey)
        #expect(s.ai.mode == .myList)
        #expect(!s.feed.entries.contains { $0.isAI })
        #expect(try s.keys.read() == nil)
        await s.ai.searchNow()
        #expect(stub.count == 1)
    }

    @Test func removingEveryInterestHidesAIItemsAndTurnsAISearchOff() async throws {
        let s = try setup()
        await s.ai.searchNow()
        s.ai.setInterests(" ,, ")
        #expect(s.ai.mode == .myList)
        #expect(!s.feed.entries.contains { $0.isAI })
        await s.ai.searchNow()
        #expect(stub.count == 1)
    }

    @Test func aSavedAIItemStaysSavedAndLabelled() async throws {
        let s = try setup()
        await s.ai.searchNow()
        let saved = SavedModel(context: s.context, now: { [clock] in clock.now })
        let pools = try #require(s.feed.entries.first { $0.interest == "tide pools" })
        #expect(saved.save(ReadingItem(pools)))
        s.ai.setMode(.myList)
        try s.ai.removeKey()
        let entry = try #require(saved.entries.first)
        #expect(entry.item.isAI)
        #expect(entry.item.interest == "tide pools")
        #expect(entry.item.provider == .anthropic)
        #expect(entry.item.category == "tide pools")
        #expect(saved.categories == [CategoryChoice(name: "tide pools", isAI: true)])
        // A relaunch reads the label back from the store.
        let again = SavedModel(context: s.context)
        #expect(again.entries.first?.item.isAI == true)
    }

    // MARK: Problems

    @Test func problemsShowInSettingsOnlyAndNeverBlankTheFeed() async throws {
        let s = try setup()
        feedStub.resolve("https://lakes.example.org/", resolveJSONLinks)
        feedStub.site("https://lakes.example.org/", .items([
            StubItem(title: "Lake story", link: "https://lakes.example.org/a", published: "2026-11-15T20:00:00Z"),
        ]))
        try await s.feed.add(address: "lakes.example.org/", category: "Local")
        stub.answer(.init(code: 502), discoverErrorJSON("provider_error"))
        await s.ai.searchNow()
        #expect(s.ai.problem == .providerError)
        #expect(s.feed.headlines(now: clock.now, timeZone: clock.zone).map(\.title) == ["Lake story"])
        // A good search clears it.
        stub.answer(.ok, discoverJSONThreeItems)
        await s.ai.searchNow()
        #expect(s.ai.problem == nil)
    }

    /// A slow search does not hold up the feed refresh from followed sites.
    @Test func aSlowSearchDoesNotDelayTheFeed() async throws {
        let s = try setup()
        feedStub.resolve("https://lakes.example.org/", resolveJSONLinks)
        feedStub.site("https://lakes.example.org/", .items([
            StubItem(title: "Lake story", link: "https://lakes.example.org/a", published: "2026-11-15T20:00:00Z"),
        ]))
        try await s.feed.add(address: "lakes.example.org/", category: "Local")
        stub.hold(true)
        let search = Task { await s.ai.refreshIfDue() }
        while stub.waitingCount == 0 { await Task.yield() }
        await s.feed.refresh(force: true)
        #expect(feedStub.feedRequests.count == 2)
        #expect(s.feed.entries.map(\.title) == ["Lake story"])
        stub.release()
        await search.value
    }

    @Test func aKeyOfTheWrongShapeIsNotSaved() throws {
        let s = try setup(key: nil, on: false)
        #expect(throws: AISearchModel.KeyProblem.invalidShape) { try s.ai.saveKey("short") }
        #expect(throws: AISearchModel.KeyProblem.invalidShape) { try s.ai.saveKey("has a space in the key 000") }
        #expect(!s.ai.hasKey)
        s.keys.setFailure(KeychainFailure(status: -25299))
        #expect(throws: AISearchModel.KeyProblem.notSaved) { try s.ai.saveKey(fakeKey) }
        #expect(!s.ai.hasKey)
    }

    @Test func changingProviderKeepsTheKeyAndWarns() throws {
        let s = try setup()
        s.ai.setProvider(.gemini)
        #expect(s.ai.hasKey)
        #expect(try s.keys.read()?.secret == fakeKey)
        #expect(s.ai.providerChangedSinceKey)
        try s.ai.saveKey(fakeKey)
        #expect(!s.ai.providerChangedSinceKey)
    }
}

/// `-debugAI` never reaches the real Keychain, even when its samples cannot be built.
@Suite @MainActor struct DebugAIFallbackTests {
    private struct SampleFailure: Error {}

    @Test func aFailedFeedSampleStillUsesTheInMemoryKeyStore() throws {
        let context = try inMemoryContext()
        let feed = FeedModel(context: context)
        let saved = SavedModel(context: context)
        let samples = SeasignApp.debugSamples(
            feed: feed, saved: saved, showFeed: true, showSaved: false, showAI: true,
            feedSample: { _ in throw SampleFailure() }
        )
        let ai = try #require(samples.ai)
        #expect(ai.isDebugFrozenInMemory)
        #expect(samples.feed === feed)
    }

    @Test func theWorkingSampleUsesTheInMemoryKeyStoreToo() throws {
        let context = try inMemoryContext()
        let samples = SeasignApp.debugSamples(
            feed: FeedModel(context: context), saved: SavedModel(context: context),
            showFeed: true, showSaved: false, showAI: true
        )
        #expect(try #require(samples.ai).isDebugFrozenInMemory)
    }

    /// The fallback sends nothing, even with a key and Search now.
    @Test func theFallbackSendsNothing() async throws {
        let context = try inMemoryContext()
        let feed = FeedModel(context: context)
        let ai = AISearchModel.debugFallback(feed: feed, context: context)
        #expect(ai.isDebugFrozenInMemory)
        #expect(ai.hasKey)
        ai.setInterests("tide pools")
        #expect(ai.setMode(.aiSearch))
        await ai.searchNow()
        #expect(ai.usedToday == 0)
        #expect(ai.lastSearch == nil)
    }
}

/// Task 198: the DEBUG flags for the states nobody had seen keep to stores
/// held in memory and the fake key store.
@Suite @MainActor struct DebugStateFlagTests {
    @Test func aSavedProblemAloneUsesTheInMemorySavedStore() throws {
        let context = try inMemoryContext()
        let feed = FeedModel(context: context)
        let saved = SavedModel(context: context)
        let samples = SeasignApp.debugSamples(
            feed: feed, saved: saved, showFeed: false, showSaved: false, showAI: false,
            savedProblem: .notesNotSaved
        )
        #expect(samples.saved !== saved)
        #expect(samples.saved.problem == .notesNotSaved)
        #expect(samples.saved.entries.isEmpty)
        #expect(samples.feed === feed && samples.ai == nil)
        #expect(SavedModel.Problem.debugNamed("notSaved") == .notSaved)
        #expect(SavedModel.Problem.debugNamed("nonsense") == nil)
        // No flag: the user's own models.
        let none = SeasignApp.debugSamples(feed: feed, saved: saved, showFeed: false, showSaved: false, showAI: false)
        #expect(none.saved === saved && none.saved.problem == nil)
    }

    @Test func theUnreadableKeySampleSaysTheKeyCannotBeRead() throws {
        let context = try inMemoryContext()
        let samples = SeasignApp.debugSamples(
            feed: FeedModel(context: context), saved: SavedModel(context: context),
            showFeed: true, showSaved: false, showAI: true, aiKeyUnreadable: true
        )
        let ai = try #require(samples.ai)
        #expect(ai.isDebugFrozenInMemory)
        #expect(ai.keyStatus == .unknown)
        ai.refreshKeyStatus()
        #expect(ai.keyStatus == .unknown)
    }

    @Test func theListSampleHoldsBothListsInMemory() throws {
        let lists = try ListsModel.sample(context: try inMemoryContext())
        #expect(lists.items(.todo).count == 3 && lists.items(.get).count == 3)
        #expect(lists.items.filter(\.isDone).count == 2)
    }

    @Test func theNoZipTodayHasNoZip() throws {
        let today = try #require(SeasignApp.debugTodayWithoutZip())
        #expect(today.zip == nil && today.placeName == nil)
    }
}

/// The key is in the Keychain (here, the in-memory fake) and in the request
/// header, and nowhere else: not in the store files on disk, not in
/// UserDefaults, not in any description of the model or its problems.
@Suite(.serialized) @MainActor struct AIKeyLeakTests {
    @Test func theKeyIsNowhereButTheKeychainAndTheHeader() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AIKeyLeakTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = LocalStore.Files(
            user: directory.appending(path: "default.store"),
            cache: directory.appending(path: "SkyCache.store")
        )
        let stub = DiscoverStub()
        let clock = AIClock()
        do {
            let container = try LocalStore.open(files).container
            let context = container.mainContext
            let feed = FeedModel(api: stubbedFeedAPI(FeedStub()), context: context, now: { clock.now })
            let keys = InMemoryKeyStore()
            let ai = AISearchModel(
                api: stubbedDiscoverAPI(stub), context: context, keyStore: keys,
                feed: feed, now: { clock.now }, zone: { clock.zone }
            )
            try ai.saveKey("  " + fakeKey + "\n")
            ai.setInterests("tide pools")
            ai.setDailyCap(20)
            #expect(ai.setMode(.aiSearch))
            await ai.searchNow()
            // Every answer the API can give, so every problem path runs.
            // 429 twice: the provider's (no Retry-After) and Seasign's own.
            for (code, retryAfter) in [(400, nil), (401, nil), (402, nil), (429, nil), (429, "60"), (500, nil), (502, nil), (504, nil)] as [(Int, String?)] {
                stub.answer(.init(code: code), #"{"error":"x","message":"\#(fakeKey)"}"#, retryAfter: retryAfter)
                try ai.saveKey(fakeKey)
                await ai.searchNow()
                #expect(!String(describing: ai.problem as Any).contains(fakeKey))
                #expect(!(ai.problem?.message.contains(fakeKey) ?? false))
            }
            stub.fail(with: EchoingError(text: fakeKey))
            await ai.searchNow()
            let saved = SavedModel(context: context)
            for entry in feed.allEntries { saved.save(ReadingItem(entry)) }

            #expect(stub.requests.allSatisfy { $0.request.headerFields[RawKeyHeader.name] == fakeKey })
            #expect(stub.requests.allSatisfy { !String(decoding: $0.body, as: UTF8.self).contains(fakeKey) })

            var dumped = ""
            dump(ai, to: &dumped, maxDepth: 6, maxItems: 5_000)
            // Positive control: the dump reaches what the model does hold.
            #expect(dumped.contains("tide pools"))
            #expect(dumped.contains("InMemoryKeyStore"))
            #expect(!dumped.contains(fakeKey))
            #expect(!String(describing: ai).contains(fakeKey))
            #expect(!String(reflecting: keys).contains(fakeKey))

            // Every attribute of every row, read back through SwiftData.
            var rows = ""
            for settings in try context.fetch(FetchDescriptor<Settings>()) { dump(settings, to: &rows) }
            for item in try context.fetch(FetchDescriptor<FeedItem>()) { dump(item.entry, to: &rows) }
            for item in try context.fetch(FetchDescriptor<SavedItem>()) { dump(item.readingItem, to: &rows) }
            for count in try context.fetch(FetchDescriptor<SearchCount>()) { rows += count.day }
            #expect(!rows.isEmpty)
            #expect(!rows.contains(fakeKey))
        }

        // The SQLite files themselves, with their side files.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.contains("default.store"))
        let needle = Data(fakeKey.utf8)
        for name in names {
            let data = try Data(contentsOf: directory.appending(path: name))
            #expect(data.range(of: needle) == nil, "the key is in \(name)")
            // Not as UTF-16 either.
            #expect(data.range(of: fakeKey.data(using: .utf16LittleEndian)!) == nil, "the key is in \(name)")
        }

        // Nothing in UserDefaults.
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        #expect(!String(describing: defaults).contains(fakeKey))
    }
}

/// The real Keychain, under a service of the tests' own so the app's item
/// is never touched.
@Suite(.serialized) struct KeychainKeyStoreTests {
    private let store = KeychainKeyStore(service: "seasign.tests.llm-api-key", account: "test")

    @Test func savesReadsReplacesAndDeletes() throws {
        defer { try? store.delete() }
        try store.delete()
        #expect(try store.read() == nil)
        try store.save(APIKey(typed: fakeKey)!)
        #expect(try store.read()?.secret == fakeKey)
        #expect(try store.storedAccessibility() == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        try store.save(APIKey(typed: "test-key-not-real-1111")!)
        #expect(try store.read()?.secret == "test-key-not-real-1111")
        try store.delete()
        #expect(try store.read() == nil)
        // Deleting when there is nothing is fine.
        try store.delete()
    }
}
