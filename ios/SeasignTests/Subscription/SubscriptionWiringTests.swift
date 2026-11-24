import Foundation
import SwiftData
import Testing

@testable import Seasign

/// How the app wires the subscription (task 217). The production wiring
/// gives AI search the real StoreKit-backed model, starting Unknown, with
/// no default that says Subscribed; a DEBUG subscription state never
/// reaches AI search on the user's own store and Keychain.
@Suite @MainActor struct SubscriptionWiringTests {
    private let stub = DiscoverStub()

    /// AI search on `subscription`, configured with a key (in memory: the
    /// stand-in for the real Keychain) and interests, its choice on Let AI
    /// Search while `realStore` answered Subscribed.
    private func aiSearch(on subscription: any SubscriptionSource, realStore: ScriptedSubscriptionStore) async throws -> AISearchModel {
        let context = try inMemoryContext()
        let feed = FeedModel(api: stubbedFeedAPI(FeedStub()), context: context)
        let ai = AISearchModel(
            api: stubbedDiscoverAPI(stub),
            context: context,
            keyStore: InMemoryKeyStore(APIKey(typed: fakeKey)),
            feed: feed,
            subscription: subscription,
            zone: { TimeZone(identifier: "America/New_York")! }
        )
        ai.setInterests("tide pools")
        return ai
    }

    @Test func theProductionWiringGivesAISearchTheRealModel() async throws {
        let store = ScriptedSubscriptionStore(.failed)
        let wiring = SeasignApp.subscriptionWiring(debugState: nil, showAI: false, realStore: store)
        #expect(wiring.ai === wiring.real)
        #expect(wiring.gate.subscription === wiring.real)
        #expect(wiring.gate.decision == .popup(.unknown))
        // The Release path's own function gives the same.
        let release = SeasignApp.productionSubscription(realStore: store, storefront: DebugStorefront())
        #expect(release.ai === release.real)
        #expect(release.gate.subscription === release.real)
        // Locked from the start: nothing has answered, and the state allows nothing.
        #expect(wiring.real.state == .unknown)
        #expect(!wiring.real.hasAnswered)
        #expect(!wiring.ai.hasAnswered)
        #expect(!wiring.ai.access.allowsPaidFeatures)
        // AI search reads the real store, and nothing says Subscribed for it.
        #expect(await wiring.ai.refresh().state == .unknown)
        #expect(store.reads == 1)
    }

    /// The task 216 hazard: a DEBUG subscription state without the AI
    /// sample must never decide AI search on the user's store and Keychain.
    /// AI search follows the real store whatever the debug state says.
    @Test(arguments: SubscriptionState.allCases)
    func aDebugStateWithoutTheAISampleNeverReachesAISearch(_ debugState: SubscriptionState) async throws {
        let store = ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: .subscribed))
        let wiring = SeasignApp.subscriptionWiring(debugState: debugState, showAI: false, realStore: store)
        #expect(wiring.ai === wiring.real)
        // The debug state is the gate's alone.
        #expect(wiring.gate.state == debugState)
        let ai = try await aiSearch(on: wiring.ai, realStore: store)
        await wiring.ai.refresh()
        #expect(ai.setMode(.aiSearch))

        // The real store can't be read (every phone until the product exists).
        store.reading = .failed
        await ai.searchNow()
        await ai.refreshIfDue()
        #expect(stub.count == 0)
        #expect(!ai.isActive)

        // And it is the real store that lets it through again, not the debug state.
        store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        await ai.searchNow()
        #expect(stub.count == 1)
    }

    /// With `-debugAI` the frozen in-memory sample follows the debug state.
    @Test func theAISampleFollowsTheDebugState() async throws {
        let store = ScriptedSubscriptionStore(.failed)
        let wiring = SeasignApp.subscriptionWiring(debugState: .lapsed, showAI: true, realStore: store)
        #expect(wiring.ai !== wiring.real)
        #expect(await wiring.ai.refresh().state == .lapsed)
        #expect(store.reads == 0)
    }
}
