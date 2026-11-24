import Foundation
import StoreKit
import Testing

@testable import Seasign

/// The renewal-state table and the fail-closed rules (task 215). The hard
/// rule: nothing paid unless `subscribed`; `unknown` is not subscribed.
@Suite struct SubscriptionRulesTests {
    typealias Renewal = Product.SubscriptionInfo.RenewalState

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let later = now.addingTimeInterval(30 * 86_400)
    static let earlier = now.addingTimeInterval(-86_400)

    /// A verified entry with an expiry a month away unless given.
    static func fact(
        _ renewal: Renewal,
        verified: Bool = true,
        expires: Date? = later,
        revoked: Date? = nil
    ) -> RenewalFact {
        RenewalFact(renewalState: renewal, isVerified: verified, expirationDate: expires, revocationDate: revoked)
    }

    static func state(_ facts: [RenewalFact]) -> SubscriptionState {
        SubscriptionRules.state(from: .statuses(facts), now: now)
    }

    static func state(_ renewals: [Renewal], verified: Bool = true) -> SubscriptionState {
        state(renewals.map { fact($0, verified: verified) })
    }

    @Test(arguments: [
        (Renewal.subscribed, SubscriptionState.subscribed),
        (.inGracePeriod, .lapsed),
        (.inBillingRetryPeriod, .lapsed),
        (.expired, .lapsed),
        (.revoked, .lapsed),
    ])
    func everyRenewalState(renewal: Renewal, expected: SubscriptionState) {
        #expect(SubscriptionRules.state(for: renewal) == expected)
        #expect(Self.state([renewal]) == expected)
    }

    @Test func aStateThisBuildDoesNotKnowIsUnknown() {
        let future = Renewal(rawValue: 99)
        #expect(SubscriptionRules.state(for: future) == .unknown)
        #expect(Self.state([future]) == .unknown)
        #expect(Self.state([future]).allowsPaidFeatures == false)
    }

    @Test func noStatusAndNoHistoryIsFree() {
        #expect(SubscriptionRules.state(from: .noStatus(hasHistory: false), now: Self.now) == .free)
    }

    /// StoreKit's status call answers an empty list when it fails (task
    /// 215's experiment); with a purchase on record that is not Free.
    @Test func noStatusButSomeHistoryIsUnknown() {
        #expect(SubscriptionRules.state(from: .noStatus(hasHistory: true), now: Self.now) == .unknown)
    }

    /// The store never sends an empty `.statuses`; if one came, it is not Free.
    @Test func anEmptyStatusListIsUnknown() {
        #expect(Self.state([RenewalFact]()) == .unknown)
    }

    @Test func aRefundIsLapsed() {
        #expect(Self.state([.revoked]) == .lapsed)
    }

    @Test func aStoreKitErrorIsUnknown() {
        #expect(SubscriptionRules.state(from: .failed, now: Self.now) == .unknown)
    }

    @Test func anUnverifiedSubscriptionIsUnknown() {
        #expect(Self.state([.subscribed], verified: false) == .unknown)
        #expect(Self.state([.expired], verified: false) == .unknown)
    }

    // StoreKit went on answering "subscribed" in a running process after the
    // subscription had expired (task 215's experiment), so `subscribed` is
    // also checked against the verified transaction's own dates.

    @Test func subscribedButPastItsExpiryIsLapsed() {
        #expect(Self.state([Self.fact(.subscribed, expires: Self.earlier)]) == .lapsed)
    }

    @Test func subscribedExactlyAtItsExpiryIsLapsed() {
        #expect(Self.state([Self.fact(.subscribed, expires: Self.now)]) == .lapsed)
        #expect(Self.state([Self.fact(.subscribed, expires: Self.now.addingTimeInterval(1))]) == .subscribed)
    }

    @Test func subscribedWithARevocationDateIsLapsed() {
        #expect(Self.state([Self.fact(.subscribed, revoked: Self.earlier)]) == .lapsed)
        // A revocation dated later than now still revokes.
        #expect(Self.state([Self.fact(.subscribed, revoked: Self.later)]) == .lapsed)
    }

    /// An auto-renewable subscription's transaction always has an expiry; one
    /// without cannot be checked, so it is not trusted.
    @Test func subscribedWithNoExpiryIsUnknown() {
        #expect(Self.state([Self.fact(.subscribed, expires: nil)]) == .unknown)
    }

    /// Only `subscribed` entries are checked against the dates; every other
    /// known state is Lapsed whatever they say.
    @Test func otherStatesIgnoreTheDates() {
        #expect(Self.state([Self.fact(.expired, expires: Self.later)]) == .lapsed)
        #expect(Self.state([Self.fact(.inGracePeriod, expires: nil)]) == .lapsed)
        #expect(Self.state([Self.fact(.revoked, expires: Self.later, revoked: nil)]) == .lapsed)
    }

    /// Family Sharing is off (`Seasign.storekit`, the plan), so StoreKit
    /// should give one entry for the group. Entries that agree give their
    /// state; entries that disagree are Unknown, since the phone cannot tell
    /// a stale entry from a current one (a cached "subscribed" beside a fresh
    /// "revoked" looks exactly like this). Phase B's server check settles it.
    @Test func severalStatuses() {
        #expect(Self.state([.subscribed, .subscribed]) == .subscribed)
        #expect(Self.state([.expired, .revoked]) == .lapsed)
        #expect(Self.state([.subscribed, .revoked]) == .unknown)
        #expect(Self.state([.expired, .subscribed]) == .unknown)
        #expect(Self.state([.expired, Renewal(rawValue: 99)]) == .unknown)
        #expect(Self.state([Self.fact(.subscribed), Self.fact(.subscribed, expires: Self.earlier)]) == .unknown)
        #expect(Self.state([Self.fact(.subscribed, verified: false), Self.fact(.expired)]) == .unknown)
    }

    /// The hard rule in one place: only `subscribed` allows anything paid,
    /// signed in or not.
    @Test(arguments: SubscriptionState.allCases, [false, true])
    func paidFeaturesOnlyWhenSubscribed(state: SubscriptionState, signedIn: Bool) {
        #expect(state.allowsPaidFeatures == (state == .subscribed))
        let access = SubscriptionAccess(state: state, isSignedIn: signedIn)
        #expect(access.allowsPaidFeatures == (state == .subscribed))
        #expect(access.accountNotFinished == (state == .subscribed && !signedIn))
    }

    @Test func theDebugArgumentNamesEachState() {
        #expect(SubscriptionRules.debugNamed("free") == .free)
        #expect(SubscriptionRules.debugNamed("subscribed") == .subscribed)
        #expect(SubscriptionRules.debugNamed("lapsed") == .lapsed)
        #expect(SubscriptionRules.debugNamed("unknown") == .unknown)
        #expect(SubscriptionRules.debugNamed("Subscribed") == nil)
        #expect(SubscriptionRules.debugNamed("") == nil)
        #expect(SubscriptionRules.debugNamed(nil) == nil)
    }

    @Test func theFixedStoreGivesEachState() {
        for state in SubscriptionState.allCases {
            #expect(SubscriptionRules.state(from: FixedSubscriptionStore.reading(for: state), now: Date()) == state)
        }
    }
}

/// The model over a fixed store.
@Suite @MainActor struct SubscriptionModelTests {
    @Test func startsUnknownSoNothingPaidIsAllowed() {
        let model = SubscriptionModel(store: FixedSubscriptionStore(state: .subscribed))
        #expect(model.state == .unknown)
        #expect(model.allowsPaidFeatures == false)
        #expect(model.isSignedIn == false)
    }

    @Test(arguments: SubscriptionState.allCases)
    func refreshReadsTheStore(state: SubscriptionState) async {
        let model = SubscriptionModel(store: FixedSubscriptionStore(state: state))
        await model.refresh()
        #expect(model.state == state)
        #expect(model.allowsPaidFeatures == (state == .subscribed))
        #expect(model.access.accountNotFinished == (state == .subscribed))
    }

    @Test func startReadsThenReadsAgainOnEveryChange() async throws {
        let store = ScriptedSubscriptionStore(.noStatus(hasHistory: false))
        let model = SubscriptionModel(store: store)
        model.start()
        #expect(await pollUntil { model.state == .free })

        store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        store.poke()
        #expect(await pollUntil { model.state == .subscribed })

        store.reading = .failed
        store.poke()
        #expect(await pollUntil { model.state == .unknown })
        #expect(model.allowsPaidFeatures == false)

        // A second start does not add a second listener.
        let listener = try #require(model.listenerTask)
        model.start()
        #expect(model.listenerTask == listener)

        await model.stop()
        #expect(model.listenerTask == nil)
        store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        store.poke()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.state == .unknown)
    }

    /// The model judges expiry by its clock: the same StoreKit answer is
    /// Subscribed before the transaction's expiry and Lapsed after it.
    @Test func theClockDecidesWhenASubscribedAnswerHasRunOut() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = SubscriptionTestClock(expiry.addingTimeInterval(-60))
        let store = ScriptedSubscriptionStore(.statuses([
            RenewalFact(renewalState: .subscribed, isVerified: true, expirationDate: expiry),
        ]))
        let model = SubscriptionModel(store: store, now: { clock.now })
        await model.refresh()
        #expect(model.state == .subscribed)
        clock.now = expiry.addingTimeInterval(1)
        await model.refresh()
        #expect(model.state == .lapsed)
        #expect(model.allowsPaidFeatures == false)
    }

    /// Two reads overlap and the later one answers first: the earlier,
    /// staler answer arriving after it must not replace it.
    @Test func anEarlierReadNeverOverwritesALaterOne() async {
        let store = HeldSubscriptionStore()
        let model = SubscriptionModel(store: store)
        let earlier = Task { await model.refresh() }
        #expect(await pollUntil { store.started == 1 })
        let later = Task { await model.refresh() }
        #expect(await pollUntil { store.started == 2 })

        store.answer(read: 1, with: .failed)
        await later.value
        #expect(model.state == .unknown)

        store.answer(read: 0, with: FixedSubscriptionStore.reading(for: .subscribed))
        await earlier.value
        #expect(model.state == .unknown)
        #expect(model.allowsPaidFeatures == false)
    }

    /// In order, each answer lands.
    @Test func readsAnsweredInOrderEachLand() async {
        let store = HeldSubscriptionStore()
        let model = SubscriptionModel(store: store)
        let earlier = Task { await model.refresh() }
        #expect(await pollUntil { store.started == 1 })
        let later = Task { await model.refresh() }
        #expect(await pollUntil { store.started == 2 })

        store.answer(read: 0, with: FixedSubscriptionStore.reading(for: .lapsed))
        await earlier.value
        #expect(model.state == .lapsed)
        store.answer(read: 1, with: FixedSubscriptionStore.reading(for: .subscribed))
        await later.value
        #expect(model.state == .subscribed)
    }
}

/// A clock the test moves.
final class SubscriptionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// A store whose reads wait until the test answers them, in any order.
final class HeldSubscriptionStore: SubscriptionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<SubscriptionReading, Never>] = []

    /// How many reads have started.
    var started: Int { lock.withLock { waiting.count } }

    /// Answers the `read`th read (from 0, in the order they started).
    func answer(read index: Int, with reading: SubscriptionReading) {
        let continuation = lock.withLock { waiting[index] }
        continuation.resume(returning: reading)
    }

    func read() async -> SubscriptionReading {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// A store whose reading the test sets and whose changes the test sends.
final class ScriptedSubscriptionStore: SubscriptionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SubscriptionReading
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(_ reading: SubscriptionReading) {
        current = reading
        (stream, continuation) = AsyncStream.makeStream()
    }

    var reading: SubscriptionReading {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func poke() {
        continuation.yield()
    }

    func read() async -> SubscriptionReading {
        reading
    }

    func changes() -> AsyncStream<Void> {
        stream
    }
}

/// Waits up to `timeout` for `condition`, checking every 50 ms.
@MainActor
func pollUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
