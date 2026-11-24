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
/// History; while not Subscribed the toggle shows Use My List, and the
/// stored choice is left as it was, so it applies again once a read says
/// Subscribed. Since task 217 the app's own wiring is tested here too
/// (`productionSubscription`). `stub.count` is every discover request that
/// reached the transport.
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
        case .lapsed: "AI search is off because your subscription isn't active."
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

    /// For each state but Subscribed, with the stored choice left on Let AI
    /// Search (the stricter case): nothing is sent, automatic or manual, even
    /// days later, and nothing is counted; AI is not in effect, AI-found
    /// items leave Today and History but stay cached; the pill shows Use My
    /// List and cannot move; and the stored choice is untouched.
    @Test(arguments: notSubscribed)
    func aChangeToNotSubscribedTurnsAIOffAndSendsNothing(_ state: SubscriptionState) async throws {
        let s = try await setup()
        await s.ai.searchNow()
        #expect(stub.count == 1)
        #expect(s.feed.showsAI)
        #expect(s.feed.entries.contains { $0.isAI })

        s.store.reading = FixedSubscriptionStore.reading(for: state)
        await s.subscription.refresh()
        #expect(s.subscription.state == state)
        #expect(!s.ai.isActive)
        #expect(!s.feed.showsAI)
        #expect(!s.feed.entries.contains { $0.isAI })
        #expect(s.feed.headlines(now: clock.now, timeZone: clock.zone).allSatisfy { !$0.isAI })
        // Still cached: not fetched again later at a cost.
        #expect(s.feed.allEntries.contains { $0.isAI })

        #expect(s.ai.shownMode == .myList)
        #expect(!s.ai.setMode(.aiSearch))
        #expect(s.ai.shownMode == .myList)
        #expect(s.ai.precondition.message == Self.message(for: state))
        #expect(!s.ai.canSearchNow)
        // The person's choice is kept for when the subscription is back.
        #expect(s.ai.mode == .aiSearch)
        #expect(try storedMode(s.context) == "ai_search")

        let used = s.ai.usedToday
        await s.ai.refreshIfDue()
        await s.ai.searchNow()
        #expect(stub.count == 1)
        #expect(s.ai.usedToday == used)
        clock.advance(2 * 86_400)
        await s.ai.refreshIfDue()
        await s.ai.searchNow()
        #expect(stub.count == 1)
        #expect(s.ai.usedToday == 0)
        #expect(try storedMode(s.context) == "ai_search")
    }

    /// The listener's path: a change StoreKit reports takes AI out of effect
    /// without anyone asking, and leaves the choice alone.
    @Test(arguments: notSubscribed)
    func aChangeTheListenerHearsTurnsAIOff(_ state: SubscriptionState) async throws {
        let s = try await setup()
        #expect(s.feed.showsAI)
        s.subscription.start()
        s.store.reading = FixedSubscriptionStore.reading(for: state)
        s.store.poke()
        #expect(await pollUntil { !s.feed.showsAI })
        #expect(!s.ai.isActive)
        #expect(s.ai.shownMode == .myList)
        #expect(try storedMode(s.context) == "ai_search")
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
            #expect(!s.feed.showsAI)
            #expect(try storedMode(s.context) == "ai_search")
        }
    }

    // MARK: Launch

    /// Before the first read lands the state is the starting Unknown. With
    /// the stored choice on Let AI Search and a first read of free, lapsed
    /// or failed, neither an automatic nor a manual search sends anything or
    /// counts anything. Once a read says Subscribed the next due automatic
    /// search is sent, once.
    @Test(arguments: [SubscriptionReading.noStatus(hasHistory: false), FixedSubscriptionStore.reading(for: .lapsed), .failed])
    func nothingIsSentFromAnUnreadStartUntilAReadSaysSubscribed(_ firstRead: SubscriptionReading) async throws {
        let first = try await setup()
        #expect(try storedMode(first.context) == "ai_search")

        let store = ScriptedSubscriptionStore(firstRead)
        let unread = SubscriptionModel(store: store)
        let (feed, ai) = model(context: first.context, subscription: unread)
        #expect(!unread.hasAnswered)
        #expect(ai.mode == .aiSearch)
        #expect(!ai.isActive)
        #expect(!feed.showsAI)
        #expect(ai.shownMode == .myList)
        #expect(ai.precondition == .subscriptionUnchecked)

        await ai.refreshIfDue()
        #expect(unread.hasAnswered)
        await ai.searchNow()
        await ai.refreshIfDue()
        #expect(store.reads == 3)
        #expect(stub.count == 0)
        #expect(ai.usedToday == 0)
        #expect(!feed.showsAI)
        #expect(try storedMode(first.context) == "ai_search")

        store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        await unread.refresh()
        #expect(ai.isActive)
        #expect(feed.showsAI)
        await ai.refreshIfDue()
        #expect(stub.count == 1)
        await ai.refreshIfDue()
        #expect(stub.count == 1)
        #expect(ai.usedToday == 1)
    }

    /// The stored choice survives a state that is not Subscribed and a
    /// relaunch made in it; a relaunch whose read says Subscribed has AI in
    /// effect with nothing done by the person.
    @Test(arguments: notSubscribed)
    func theStoredChoiceSurvivesARelaunch(_ state: SubscriptionState) async throws {
        let first = try await setup()
        let answered = SubscriptionModel(store: ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: state)))
        await answered.refresh()
        let (feed, ai) = model(context: first.context, subscription: answered)
        #expect(ai.mode == .aiSearch)
        #expect(ai.shownMode == .myList)
        #expect(!feed.showsAI)
        #expect(try storedMode(first.context) == "ai_search")

        let back = SubscriptionModel(store: ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: .subscribed)))
        let (feedAgain, again) = model(context: first.context, subscription: back)
        await back.refresh()
        #expect(again.isActive)
        #expect(again.shownMode == .aiSearch)
        #expect(feedAgain.showsAI)
    }

    // MARK: The toggle

    /// While not subscribed the pill shows Use My List and a tap either way
    /// stores nothing; subscribed again, it shows the stored choice.
    @Test(arguments: notSubscribed)
    func theToggleShowsUseMyListAndATapStoresNothing(_ state: SubscriptionState) async throws {
        for stored in [AIMode.aiSearch, .myList] {
            let s = try await setup(on: stored == .aiSearch)
            #expect(try storedMode(s.context) == (stored == .aiSearch ? "ai_search" : nil))
            s.store.reading = FixedSubscriptionStore.reading(for: state)
            await s.subscription.refresh()
            let before = try storedMode(s.context)
            #expect(s.ai.shownMode == .myList)
            #expect(!s.ai.setMode(.aiSearch))
            #expect(!s.ai.setMode(.myList))
            #expect(s.ai.mode == stored)
            #expect(try storedMode(s.context) == before)

            s.store.reading = FixedSubscriptionStore.reading(for: .subscribed)
            await s.subscription.refresh()
            #expect(s.ai.shownMode == stored)
            #expect(s.feed.showsAI == (stored == .aiSearch))
        }
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
        #expect(s.ai.shownMode == .aiSearch)
        #expect(s.feed.showsAI)
    }

    /// Back to Subscribed, the stored choice applies again by itself: AI-found
    /// headlines show again and automatic searches resume under the usual
    /// gate and cap.
    @Test(arguments: notSubscribed)
    func aiResumesByItselfWhenSubscribedAgain(_ state: SubscriptionState) async throws {
        let s = try await setup(cap: 1)
        await s.ai.searchNow()
        #expect(stub.count == 1)
        s.store.reading = FixedSubscriptionStore.reading(for: state)
        await s.subscription.refresh()
        #expect(!s.feed.entries.contains { $0.isAI })
        clock.advance(2 * 86_400)
        await s.ai.refreshIfDue()
        #expect(stub.count == 1)

        s.store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        await s.subscription.refresh()
        #expect(s.ai.isActive)
        #expect(s.ai.shownMode == .aiSearch)
        #expect(s.feed.showsAI)
        await s.ai.refreshIfDue()
        #expect(stub.count == 2)
        // The cap (1) still holds.
        await s.ai.searchNow()
        #expect(stub.count == 2)
    }

    /// A second tap on Search now while the first is still reading the
    /// subscription sends nothing and charges nothing extra, and the button
    /// cannot be tapped meanwhile.
    @Test func aSecondTapDuringTheReadSendsNothingExtra() async throws {
        let (subscription, store, ai) = try await heldSetup()
        _ = subscription
        let first = Task { await ai.searchNow() }
        try #require(await pollUntil { store.started == 2 })
        #expect(ai.isCheckingSubscription)
        #expect(!ai.canSearchNow)
        let second = Task { await ai.searchNow() }
        let third = Task { await ai.refreshIfDue() }
        for _ in 0..<50 { await Task.yield() }
        #expect(store.started == 2)
        store.answer(read: 1, with: FixedSubscriptionStore.reading(for: .subscribed))
        await first.value
        // Dropped attempts read nothing. Any read one did start is answered,
        // so a broken guard fails on the count below instead of hanging.
        for extra in 2..<max(2, store.started) {
            store.answer(read: extra, with: FixedSubscriptionStore.reading(for: .subscribed))
        }
        await second.value
        await third.value
        #expect(stub.count == 1)
        #expect(ai.usedToday == 1)
        #expect(!ai.isCheckingSubscription)
    }

    /// A search's read overlaps another read (the listener's) that started
    /// later and lands first: the search goes by that later answer, and one
    /// request is sent, counted before it leaves.
    @Test func aSearchWhoseReadIsOvertakenSendsOnce() async throws {
        let (subscription, store, ai) = try await heldSetup()
        stub.hold(true)
        let search = Task { await ai.searchNow() }
        try #require(await pollUntil { store.started == 2 })
        let listener = Task { await subscription.refresh() }
        try #require(await pollUntil { store.started == 3 })
        store.answer(read: 2, with: FixedSubscriptionStore.reading(for: .subscribed))
        await listener.value
        store.answer(read: 1, with: FixedSubscriptionStore.reading(for: .lapsed))
        try #require(await pollUntil { stub.waitingCount >= 1 })
        for _ in 0..<50 { await Task.yield() }
        #expect(stub.count == 1)
        #expect(ai.usedToday == 1)
        // While it is in flight nothing else goes.
        let again = Task { await ai.searchNow() }
        try #require(await pollUntil { store.started == 4 })
        store.answer(read: 3, with: FixedSubscriptionStore.reading(for: .subscribed))
        await again.value
        #expect(stub.count == 1)
        stub.release()
        await search.value
        #expect(stub.count == 1)
        #expect(ai.usedToday == 1)
    }

    /// The same overlap the other way: the search's read is the later one
    /// and says lapsed. Nothing is sent.
    @Test func aLaterReadSayingLapsedStopsTheSend() async throws {
        let (subscription, store, ai) = try await heldSetup()
        let listener = Task { await subscription.refresh() }
        try #require(await pollUntil { store.started == 2 })
        let search = Task { await ai.searchNow() }
        try #require(await pollUntil { store.started == 3 })
        store.answer(read: 2, with: FixedSubscriptionStore.reading(for: .lapsed))
        await search.value
        store.answer(read: 1, with: FixedSubscriptionStore.reading(for: .subscribed))
        await listener.value
        #expect(stub.count == 0)
        #expect(ai.usedToday == 0)
        #expect(subscription.state == .lapsed)
    }

    /// AI search on, over a model whose first read has landed Subscribed and
    /// whose later reads wait for the test.
    private func heldSetup() async throws -> (SubscriptionModel, HeldSubscriptionStore, AISearchModel) {
        let store = HeldSubscriptionStore()
        let subscription = SubscriptionModel(store: store)
        let first = Task { await subscription.refresh() }
        try #require(await pollUntil { store.started == 1 })
        store.answer(read: 0, with: FixedSubscriptionStore.reading(for: .subscribed))
        await first.value
        let (_, ai) = model(context: try inMemoryContext(), subscription: subscription)
        ai.setInterests("tide pools")
        #expect(ai.setMode(.aiSearch))
        return (subscription, store, ai)
    }

    /// A lapse while the read before a send is in flight: the read says
    /// lapsed, so nothing is sent.
    @Test func aLapseReportedByTheReadInFlightSendsNothing() async throws {
        let (_, store, ai) = try await heldSetup()
        let search = Task { await ai.searchNow() }
        try #require(await pollUntil { store.started == 2 })
        #expect(ai.isActive)
        store.answer(read: 1, with: FixedSubscriptionStore.reading(for: .lapsed))
        await search.value
        #expect(stub.count == 0)
        #expect(ai.usedToday == 0)
        #expect(!ai.isActive)
        #expect(ai.mode == .aiSearch)
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

    // MARK: The app's wiring (task 217)

    /// The production wiring: AI search obeys the real model over the
    /// app's store, which starts Unknown with nothing answered. With the
    /// store answering anything but Subscribed, no discover request is sent
    /// by any path; the moment it answers Subscribed, one is.
    @Test(arguments: notSubscribed)
    func theProductionWiringSendsNothingUnlessSubscribed(_ state: SubscriptionState) async throws {
        let store = ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: .subscribed))
        let wiring = SeasignApp.productionSubscription(realStore: store, storefront: DebugStorefront())
        #expect(wiring.ai === wiring.real)
        #expect(wiring.gate.subscription === wiring.real)
        #expect(!wiring.ai.hasAnswered)
        #expect(wiring.real.state == .unknown)

        let context = try inMemoryContext()
        let (feed, ai) = model(context: context, subscription: wiring.ai)
        ai.setInterests("tide pools")
        // Before any read has landed, the starting Unknown allows nothing.
        #expect(!ai.setMode(.aiSearch))
        await wiring.real.refresh()
        #expect(ai.setMode(.aiSearch))

        store.reading = FixedSubscriptionStore.reading(for: state)
        await ai.refreshIfDue()
        await ai.searchNow()
        wiring.real.start()
        store.poke()
        await ai.refreshIfDue()
        #expect(stub.count == 0)
        #expect(!feed.showsAI)
        #expect(ai.shownMode == .myList)
        #expect(try storedMode(context) == AIMode.aiSearch.rawValue)

        store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        await ai.searchNow()
        #expect(stub.count == 1)
        await wiring.real.stop()
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
        #expect(ai.mode == .aiSearch)
        #expect(ai.shownMode == .myList)
        #expect(!samples.feed.showsAI)
        #expect(ai.precondition.message == Self.message(for: .lapsed))
        #expect(try storedMode(context) == nil)
    }
}
