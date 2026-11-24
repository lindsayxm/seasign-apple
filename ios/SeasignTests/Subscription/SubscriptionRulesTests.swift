import Foundation
import StoreKit
import Testing

@testable import Seasign

/// The renewal-state table and the fail-closed rules (task 215). The hard
/// rule: nothing paid unless `subscribed`; `unknown` is not subscribed.
@Suite struct SubscriptionRulesTests {
    typealias Renewal = Product.SubscriptionInfo.RenewalState

    static func answered(_ states: [Renewal], verified: Bool = true, history: Bool = true) -> SubscriptionReading {
        .answered(statuses: states.map { RenewalFact(renewalState: $0, isVerified: verified) }, hasHistory: history)
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
        #expect(SubscriptionRules.state(from: Self.answered([renewal])) == expected)
    }

    @Test func aStateThisBuildDoesNotKnowIsUnknown() {
        let future = Renewal(rawValue: 99)
        #expect(SubscriptionRules.state(for: future) == .unknown)
        #expect(SubscriptionRules.state(from: Self.answered([future])) == .unknown)
        #expect(SubscriptionRules.state(from: Self.answered([future])).allowsPaidFeatures == false)
    }

    @Test func noStatusAndNoHistoryIsFree() {
        #expect(SubscriptionRules.state(from: .answered(statuses: [], hasHistory: false)) == .free)
    }

    /// StoreKit's status call answers an empty list when it fails (task
    /// 215's experiment); with a purchase on record that is not Free.
    @Test func noStatusButSomeHistoryIsUnknown() {
        #expect(SubscriptionRules.state(from: .answered(statuses: [], hasHistory: true)) == .unknown)
    }

    @Test func aRefundIsLapsed() {
        #expect(SubscriptionRules.state(from: Self.answered([.revoked])) == .lapsed)
    }

    @Test func aStoreKitErrorIsUnknown() {
        #expect(SubscriptionRules.state(from: .failed) == .unknown)
    }

    @Test func anUnverifiedSubscriptionIsUnknown() {
        #expect(SubscriptionRules.state(from: Self.answered([.subscribed], verified: false)) == .unknown)
        #expect(SubscriptionRules.state(from: Self.answered([.expired], verified: false)) == .unknown)
    }

    @Test func severalStatuses() {
        #expect(SubscriptionRules.state(from: Self.answered([.expired, .subscribed])) == .subscribed)
        #expect(SubscriptionRules.state(from: Self.answered([.expired, .revoked])) == .lapsed)
        #expect(SubscriptionRules.state(from: Self.answered([.expired, Renewal(rawValue: 99)])) == .unknown)
        // One verified subscribed entry is enough; an unverified one beside a lapsed one is not.
        let mixed = SubscriptionReading.answered(
            statuses: [
                RenewalFact(renewalState: .subscribed, isVerified: false),
                RenewalFact(renewalState: .expired, isVerified: true),
            ],
            hasHistory: true
        )
        #expect(SubscriptionRules.state(from: mixed) == .unknown)
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
            #expect(SubscriptionRules.state(from: FixedSubscriptionStore.reading(for: state)) == state)
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
        let store = ScriptedSubscriptionStore(.answered(statuses: [], hasHistory: false))
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
