import Foundation
import SwiftData
import Testing

@testable import Seasign

/// Subscribed, not signed in: what every test that needs AI injects.
let subscribedAccess = SubscriptionAccess(state: .subscribed, isSignedIn: false)

/// A subscription the tests set by hand, answered from the start. For the
/// tests that are not about the subscription; the rule's own tests use the
/// real `SubscriptionModel` over a scripted store.
@MainActor
final class TestSubscription: SubscriptionSource {
    private(set) var access: SubscriptionAccess
    let hasAnswered = true
    private(set) var reads = 0
    private var handlers: [@MainActor (SubscriptionAccess) -> Void] = []

    init(_ state: SubscriptionState) {
        access = SubscriptionAccess(state: state, isSignedIn: false)
    }

    func refresh() async -> SubscriptionAccess {
        reads += 1
        for handler in handlers { handler(access) }
        return access
    }

    func whenJudged(_ handler: @escaping @MainActor (SubscriptionAccess) -> Void) {
        handlers.append(handler)
    }
}

/// A clock and time zone the tests can move.
private final class RuleClock: @unchecked Sendable {
    private let lock = NSLock()
    /// 18:05 on Sunday 15 November 2026 in New York.
    private var value = instant("2026-11-15T23:05:00Z")
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    let zone = TimeZone(identifier: "America/New_York")!
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// THE HARD RULE (task 216): no AI unless Subscribed. No `POST /v1/discover`
/// is sent for a free, lapsed or unknown subscription, by any path; the
/// toggle cannot move to Let AI Search; AI-found items leave Today and
/// History; a lapse puts the toggle on Use My List. `stub.count` is every
/// discover request that reached the transport.
@Suite @MainActor struct AISubscriptionRuleTests {
    private let clock = RuleClock()
    private let stub = DiscoverStub()
    private let feedStub = FeedStub()

    nonisolated static let notSubscribed: [SubscriptionState] = [.free, .lapsed, .unknown]

    private struct Setup {
        var context: ModelContext
        var feed: FeedModel
        var ai: AISearchModel
        var store: ScriptedSubscriptionStore
        var subscription: SubscriptionModel
    }

    /// AI search configured (key, interests, cap) over the real subscription
    /// model, whose store first answers `state`. `read`: whether that first
    /// read has landed before the AI model is built.
    private func setup(
        _ state: SubscriptionState = .subscribed,
        context: ModelContext? = nil,
        read: Bool = true,
        on: Bool = true,
        cap: Int = 3
    ) async throws -> Setup {
        let context = try context ?? inMemoryContext()
        let store = ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: state))
        let subscription = SubscriptionModel(store: store)
        if read { await subscription.refresh() }
        let (feed, ai) = model(context: context, subscription: subscription)
        ai.setInterests("tide pools, new telescopes")
        ai.setDailyCap(cap)
        if on { #expect(ai.setMode(.aiSearch)) }
        return Setup(context: context, feed: feed, ai: ai, store: store, subscription: subscription)
    }

    private func model(context: ModelContext, subscription: any SubscriptionSource) -> (FeedModel, AISearchModel) {
        let clock = clock
        let feed = FeedModel(api: stubbedFeedAPI(feedStub), context: context, now: { clock.now })
        let ai = AISearchModel(
            api: stubbedDiscoverAPI(stub),
            context: context,
            keyStore: InMemoryKeyStore(APIKey(typed: fakeKey)),
            feed: feed,
            subscription: subscription,
            now: { clock.now },
            zone: { clock.zone }
        )
        return (feed, ai)
    }

    private func storedMode(_ context: ModelContext) throws -> String? {
        try context.fetch(FetchDescriptor<Settings>()).first?.aiModeRaw
    }

    private static func message(for state: SubscriptionState) -> String {
        switch state {
        case .free: "AI search needs a subscription."
        case .lapsed: "AI search is off because your subscription has ended."
        case .unknown, .subscribed: "AI search waits until your subscription can be checked."
        }
    }

    // MARK: The pure rule

    @Test func theRuleAllowsOnlySubscribed() {
        for state in SubscriptionState.allCases {
            for signedIn in [false, true] {
                let access = SubscriptionAccess(state: state, isSignedIn: signedIn)
                #expect(AIRule.mayRun(access) == (state == .subscribed))
            }
        }
    }

    @Test(arguments: notSubscribed)
    func theGateSendsNothingUnlessSubscribed(_ state: SubscriptionState) {
        func gate(_ state: SubscriptionState) -> SearchGate {
            SearchGate(
                subscription: SubscriptionAccess(state: state, isSignedIn: false),
                mode: .aiSearch, key: .saved, interests: ["tide pools"], cap: 3, usedToday: 0,
                lastSentAt: nil, keyRefused: false, isSearching: false
            )
        }
        let now = clock.now
        #expect(gate(state).decide(.automatic, now: now) == .notSubscribed)
        #expect(gate(state).decide(.manual, now: now) == .notSubscribed)
        #expect(gate(.subscribed).decide(.automatic, now: now) == .send)
        #expect(gate(.subscribed).decide(.manual, now: now) == .send)
    }

    /// The toggle's message says why, before anything about the key or the
    /// interests: without the subscription neither would help.
    @Test(arguments: notSubscribed)
    func theToggleSaysWhy(_ state: SubscriptionState) throws {
        let access = SubscriptionAccess(state: state, isSignedIn: false)
        for key in [KeyStatus.saved, .missing, .unknown] {
            for interests in [["x"], []] {
                let precondition = AIPrecondition(subscription: access, key: key, interests: interests)
                #expect(precondition != .ready)
                #expect(precondition.message == Self.message(for: state))
            }
        }
        #expect(AIPrecondition(subscription: subscribedAccess, key: .saved, interests: ["x"]) == .ready)
    }

    // MARK: A change to not subscribed

    /// For each state but Subscribed: the toggle goes to Use My List (and is
    /// stored there), AI-found items leave Today and History but stay
    /// cached, the toggle cannot move back, and no search is sent, automatic
    /// or manual, even days later.
    @Test(arguments: notSubscribed)
    func aChangeToNotSubscribedSwitchesAIOffAndSendsNothing(_ state: SubscriptionState) async throws {
        let s = try await setup()
        await s.ai.searchNow()
        #expect(stub.count == 1)
        #expect(s.feed.showsAI)
        #expect(s.feed.entries.contains{ $0.isAI })

        s.store.reading = FixedSubscriptionStore.reading(for: state)
        await s.subscription.refresh()
        #expect(s.subscription.state == state)
        #expect(s.ai.mode == .myList)
        #expect(try storedMode(s.context) == "my_list")
        #expect(!s.ai.isActive)
        #expect(!s.feed.showsAI)
        #expect(!s.feed.entries.contains{ $0.isAI })
        #expect(s.feed.headlines(now: clock.now, timeZone: clock.zone).allSatisfy { !$0.isAI })
        // Still cached: not fetched again later at a cost.
        #expect(s.feed.allEntries.contains{ $0.isAI })

        #expect(!s.ai.setMode(.aiSearch))
        #expect(s.ai.mode == .myList)
        #expect(s.ai.precondition.message == Self.message(for: state))
        #expect(!s.ai.canSearchNow)

        clock.advance(2 * 86_400)
        await s.ai.refreshIfDue()
        await s.ai.searchNow()
        #expect(stub.count == 1)
        #expect(s.ai.usedToday == 0)
    }

    /// The listener's path: a change StoreKit reports reaches the toggle
    /// without anyone asking.
    @Test(arguments: notSubscribed)
    func aChangeTheListenerHearsSwitchesAIOff(_ state: SubscriptionState) async throws {
        let s = try await setup()
        s.subscription.start()
        s.store.reading = FixedSubscriptionStore.reading(for: state)
        s.store.poke()
        #expect(await pollUntil { s.ai.mode == .myList })
        #expect(!s.feed.showsAI)
        await s.subscription.stop()
    }

    /// The subscription changed and nobody told the app (a running app is
    /// not always told of an expiry): the read made just before the send
    /// says so, and nothing is sent or counted. Automatic and manual.
    @Test(arguments: notSubscribed)
    func aChangeNobodyWasToldAboutIsCaughtBeforeTheSend(_ state: SubscriptionState) async throws {
        for trigger in [SearchGate.Trigger.automatic, .manual] {
            let s = try await setup()
            #expect(s.ai.isActive)
            s.store.reading = FixedSubscriptionStore.reading(for: state)
            let readsBefore = s.store.reads
            switch trigger {
            case .automatic: await s.ai.refreshIfDue()
            case .manual: await s.ai.searchNow()
            }
            #expect(s.store.reads == readsBefore + 1)
            #expect(stub.count == 0)
            #expect(s.ai.usedToday == 0)
            #expect(s.ai.mode == .myList)
            #expect(!s.feed.showsAI)
        }
    }

    // MARK: Launch

    /// Before the first read lands the state is the starting Unknown: AI is
    /// inactive and nothing is sent, but the stored choice is left alone, so
    /// a subscriber is not switched off at every launch. The first answer
    /// decides: Subscribed brings AI in; a failed read switches it off.
    @Test func aLaunchBeforeTheFirstReadLeavesTheChoiceAlone() async throws {
        let first = try await setup()
        #expect(try storedMode(first.context) == "ai_search")

        let store = ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: .subscribed))
        let unread = SubscriptionModel(store: store)
        let (feed, ai) = model(context: first.context, subscription: unread)
        #expect(ai.mode == .aiSearch)
        #expect(!ai.isActive)
        #expect(!feed.showsAI)
        #expect(ai.precondition == .subscriptionUnchecked)
        #expect(try storedMode(first.context) == "ai_search")

        // The launch's automatic search waits for its own read, then sends.
        await ai.refreshIfDue()
        #expect(stub.count == 1)
        #expect(ai.isActive)
        #expect(feed.showsAI)

        let failing = ScriptedSubscriptionStore(.failed)
        let failingModel = SubscriptionModel(store: failing)
        let (feedAgain, again) = model(context: first.context, subscription: failingModel)
        #expect(again.mode == .aiSearch)
        await failingModel.refresh()
        #expect(again.mode == .myList)
        #expect(!feedAgain.showsAI)
        #expect(try storedMode(first.context) == "my_list")
    }

    /// An answer already in when the model is built is applied at once.
    @Test(arguments: notSubscribed)
    func aLaunchWithAnAnswerAlreadyInAppliesIt(_ state: SubscriptionState) async throws {
        let first = try await setup()
        let answered = SubscriptionModel(store: ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: state)))
        await answered.refresh()
        let (feed, ai) = model(context: first.context, subscription: answered)
        #expect(ai.mode == .myList)
        #expect(!feed.showsAI)
        #expect(try storedMode(first.context) == "my_list")
    }

    // MARK: Subscribed

    /// Subscribed behaves as before: searches are sent up to the day's cap,
    /// and each one reads the subscription first.
    @Test func subscribedSearchesAsBeforeUpToTheCap() async throws {
        let s = try await setup(cap: 2)
        let readsBefore = s.store.reads
        await s.ai.searchNow()
        await s.ai.searchNow()
        await s.ai.searchNow()
        #expect(stub.count == 2)
        #expect(s.ai.usedToday == 2)
        #expect(s.ai.capReached)
        #expect(s.store.reads == readsBefore + 3)
        #expect(s.ai.mode == .aiSearch)
        #expect(s.feed.showsAI)
    }

    /// Coming back to Subscribed does not switch AI search on by itself;
    /// the person can switch it on again.
    @Test(arguments: notSubscribed)
    func regainingTheSubscriptionDoesNotSwitchAIOn(_ state: SubscriptionState) async throws {
        let s = try await setup()
        s.store.reading = FixedSubscriptionStore.reading(for: state)
        await s.subscription.refresh()
        #expect(s.ai.mode == .myList)

        s.store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        await s.subscription.refresh()
        #expect(s.ai.mode == .myList)
        #expect(!s.feed.showsAI)
        await s.ai.refreshIfDue()
        await s.ai.searchNow()
        #expect(stub.count == 0)

        #expect(s.ai.setMode(.aiSearch))
        #expect(s.feed.showsAI)
        await s.ai.searchNow()
        #expect(stub.count == 1)
    }

    /// Three searches whose subscription reads overlap and land out of order:
    /// one request is sent while the first is in flight, and it is counted
    /// before it leaves. The check and the count still happen in one turn
    /// after each read lands.
    @Test func searchesWhoseReadsOverlapSendOnce() async throws {
        let store = HeldSubscriptionStore()
        let subscription = SubscriptionModel(store: store)
        let first = Task { await subscription.refresh() }
        try #require(await pollUntil { store.started == 1 })
        store.answer(read: 0, with: FixedSubscriptionStore.reading(for: .subscribed))
        await first.value
        let (_, ai) = model(context: try inMemoryContext(), subscription: subscription)
        ai.setInterests("tide pools")
        #expect(ai.setMode(.aiSearch))

        stub.hold(true)
        let searches = [
            Task { await ai.searchNow() },
            Task { await ai.refreshIfDue() },
            Task { await ai.searchNow() },
        ]
        try #require(await pollUntil { store.started == 4 })
        for read in [3, 1, 2] {
            store.answer(read: read, with: FixedSubscriptionStore.reading(for: .subscribed))
        }
        try #require(await pollUntil { stub.waitingCount == 1 })
        for _ in 0..<50 { await Task.yield() }
        #expect(stub.count == 1)
        #expect(ai.usedToday == 1)
        stub.release()
        for search in searches { await search.value }
        #expect(stub.count == 1)
    }

    /// A lapse while the read before a send is in flight: the read says
    /// lapsed, so nothing is sent.
    @Test func aLapseReportedByTheReadInFlightSendsNothing() async throws {
        let store = HeldSubscriptionStore()
        let subscription = SubscriptionModel(store: store)
        let first = Task { await subscription.refresh() }
        try #require(await pollUntil { store.started == 1 })
        store.answer(read: 0, with: FixedSubscriptionStore.reading(for: .subscribed))
        await first.value
        let (feed, ai) = model(context: try inMemoryContext(), subscription: subscription)
        ai.setInterests("tide pools")
        #expect(ai.setMode(.aiSearch))

        let search = Task { await ai.searchNow() }
        try #require(await pollUntil { store.started == 2 })
        #expect(ai.isActive)
        store.answer(read: 1, with: FixedSubscriptionStore.reading(for: .lapsed))
        await search.value
        #expect(stub.count == 0)
        #expect(ai.usedToday == 0)
        #expect(ai.mode == .myList)
        #expect(!feed.showsAI)
    }

    // MARK: Saved

    /// An AI-found article the person saved stays in Saved after a lapse:
    /// it is already fetched and costs nothing to show (the user, 2026-11-24).
    @Test(arguments: notSubscribed)
    func savedAIFoundArticlesStayListed(_ state: SubscriptionState) async throws {
        let s = try await setup()
        await s.ai.searchNow()
        let found = try #require(s.feed.entries.first{ $0.isAI })
        let saved = SavedModel(context: s.context)
        #expect(saved.save(ReadingItem(found)))

        s.store.reading = FixedSubscriptionStore.reading(for: state)
        await s.subscription.refresh()
        #expect(!s.feed.entries.contains{ $0.isAI })
        #expect(saved.entries.contains { $0.item.link == found.link })
        let reopened = SavedModel(context: s.context)
        #expect(reopened.entries.contains { $0.item.link == found.link && $0.item.isAI })
    }

    // MARK: The pre-gate default (task 217 removes it)

    /// Until task 217 builds the gate, AI search obeys a default that says
    /// Subscribed, so nothing changes for anyone: StoreKit's real answer is
    /// Unknown on every phone until the product exists. `SubscribedUntilTheGate`
    /// is private to `SeasignApp.swift`, so `subscriptionForAI` is the only
    /// way to it. When task 217 removes it, this test goes with it.
    @Test func beforeTask217AISearchObeysADefaultThatSaysSubscribed() async throws {
        let source = SeasignApp.subscriptionForAI(override: nil)
        #expect(source.hasAnswered)
        #expect(source.access == subscribedAccess)
        #expect(await source.refresh() == subscribedAccess)

        let (feed, ai) = model(context: try inMemoryContext(), subscription: source)
        ai.setInterests("tide pools")
        #expect(ai.setMode(.aiSearch))
        #expect(feed.showsAI)
        await ai.refreshIfDue()
        #expect(stub.count == 1)

        // A given source wins (DEBUG's `-debugSubscription` and `-debugAI`).
        let lapsed = TestSubscription(.lapsed)
        #expect(SeasignApp.subscriptionForAI(override: lapsed) === lapsed)
    }

    /// `-debugSubscription lapsed -debugAI YES`: the AI sample follows the
    /// state, in its store in memory.
    @Test func theAISampleFollowsTheDebugSubscription() async throws {
        let context = try inMemoryContext()
        let lapsed = SubscriptionModel(store: FixedSubscriptionStore(state: .lapsed))
        let samples = SeasignApp.debugSamples(
            feed: FeedModel(context: context), saved: SavedModel(context: context),
            subscription: lapsed, showFeed: true, showSaved: false, showAI: true
        )
        let ai = try #require(samples.ai)
        #expect(ai.isDebugFrozenInMemory)
        await lapsed.refresh()
        #expect(ai.mode == .myList)
        #expect(!samples.feed.showsAI)
        #expect(ai.precondition.message == Self.message(for: .lapsed))
        #expect(try storedMode(context) == nil)
    }
}
