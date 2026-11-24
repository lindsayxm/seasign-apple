import Foundation
import StoreKit
import StoreKitTest
import Testing

@testable import Seasign

private final class TestBundleMarker {}

/// The live store against Xcode's local StoreKit test environment
/// (`Seasign.storekit`, in the test bundle only). There is one test
/// environment per simulator, so these run one at a time, and each clears
/// its transactions when it ends: a later `simctl launch` of the app on the
/// same simulator sees whatever is left (task 215, experiment 2).
@Suite(.serialized) @MainActor struct StoreKitSubscriptionTests {
    static let productID = SubscriptionRules.productID

    func withSession(_ body: (SKTestSession, StoreKitSubscriptionStore) async throws -> Void) async throws {
        // `Bundle.main` is the host app; the file is in the test bundle.
        let url = try #require(Bundle(for: TestBundleMarker.self).url(forResource: "Seasign", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        // The environment outlives a run, so nothing is left over from one.
        await Self.reset(session)
        session.disableDialogs = true
        do {
            try await body(session, StoreKitSubscriptionStore())
        } catch {
            await Self.reset(session)
            throw error
        }
        await Self.reset(session)
    }

    /// No simulated errors, no transactions, default settings.
    static func reset(_ session: SKTestSession) async {
        try? await session.setSimulatedError(nil, forAPI: .loadProducts)
        try? await session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        // Task 217's purchase and restore tests.
        try? await session.setSimulatedError(nil, forAPI: .purchase)
        try? await session.setSimulatedError(nil, forAPI: .verification)
        try? await session.setSimulatedError(nil, forAPI: .appStoreSync)
        session.askToBuyEnabled = false
        session.clearTransactions()
        session.resetToDefaultState()
    }

    private func state(_ store: StoreKitSubscriptionStore) async -> SubscriptionState {
        SubscriptionRules.state(from: await store.read(), now: Date())
    }

    /// StoreKit takes a moment to report a change (on iOS 18 the status
    /// straight after a purchase is still empty), so each check waits.
    private func becomes(_ expected: SubscriptionState, _ store: StoreKitSubscriptionStore) async -> Bool {
        await pollUntil { await state(store) == expected }
    }

    @Test func theTestFileHasTheMonthlyProductAt299() async throws {
        try await withSession { _, _ in
            let products = try await Product.products(for: [Self.productID])
            let product = try #require(products.first)
            #expect(products.count == 1)
            #expect(product.type == .autoRenewable)
            #expect(product.price == Decimal(string: "2.99"))
            #expect(product.subscription?.subscriptionPeriod.unit == .month)
            #expect(product.subscription?.subscriptionPeriod.value == 1)
            #expect(product.subscription?.introductoryOffer == nil)
        }
    }

    @Test func aFreshSessionIsFree() async throws {
        try await withSession { _, store in
            #expect(await state(store) == .free)
        }
    }

    @Test func buyingGivesSubscribed() async throws {
        try await withSession { session, store in
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            #expect(await becomes(.subscribed, store))
        }
    }

    /// An expired subscription: bought 40 days ago and not renewed, so it
    /// was never active in this run. `expireSubscription` is not used: in
    /// this suite StoreKit went on reporting the subscription as active
    /// after it (status, entitlements and latest transaction alike) with no
    /// update, in every run on iOS 27.2 (task 215's log).
    @Test func expiryGivesLapsed() async throws {
        try await withSession { session, store in
            let transaction = try await session.buyProduct(
                identifier: Self.productID,
                options: [.purchaseDate(Date().addingTimeInterval(-40 * 86_400), renewalBehavior: .cancelImmediately)]
            )
            await transaction.finish()
            #expect(try #require(transaction.expirationDate) < Date())
            #expect(await becomes(.lapsed, store))
        }
    }

    /// The case the clock check is for. Once this process has read the
    /// subscription as active, StoreKit goes on answering "subscribed" after
    /// `expireSubscription` (experiment 1). Judged at a time after that
    /// transaction's own expiry (the model's clock moved past it), the
    /// stale answer is Lapsed. What is real here is StoreKit's stale answer;
    /// the passing of time is the injected clock.
    @Test func aStaleSubscribedAnswerPastItsExpiryIsLapsed() async throws {
        try await withSession { session, store in
            let clock = SubscriptionTestClock(Date())
            let model = SubscriptionModel(store: store, now: { clock.now })
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            #expect(await pollUntil {
                await model.refresh()
                return model.state == .subscribed
            })
            try session.expireSubscription(productIdentifier: Self.productID)
            await model.refresh()
            // The stale answer this test is about: before the clock moves,
            // the model still says subscribed.
            #expect(model.state == .subscribed)
            clock.now = try #require(transaction.expirationDate).addingTimeInterval(1)
            await model.refresh()
            #expect(model.state == .lapsed)
            #expect(model.allowsPaidFeatures == false)
        }
    }

    /// A subscription that simply runs out while the process watches (auto
    /// renew off, one renewal every two seconds) is read as Lapsed on the
    /// real clock. StoreKit reports this expiry itself (renewal state 2),
    /// unlike `expireSubscription`, though on iOS 18.3 a moment after the
    /// expiry date.
    @Test func aSubscriptionThatRunsOutWhileTheProcessWatchesIsLapsed() async throws {
        try await withSession { session, store in
            session.timeRate = .oneRenewalEveryTwoSeconds
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
            #expect(await becomes(.subscribed, store))
            let expiry = try #require(transaction.expirationDate)
            #expect(expiry.timeIntervalSinceNow < 10)
            #expect(await pollUntil(timeout: .seconds(15)) {
                guard Date() > expiry else { return false }
                return await state(store) == .lapsed
            })
            // What StoreKit itself reported: expired (renewal state 2). On
            // iOS 27.2 it already says so when the model reads Lapsed; on
            // iOS 18.3 it still said subscribed at that moment (the clock
            // check read Lapsed first) and expired a moment later (task 216),
            // so this waits for it.
            #expect(await pollUntil(timeout: .seconds(10)) {
                guard case .statuses(let facts) = await store.read() else { return false }
                return facts.map(\.renewalState) == [.expired]
            })
        }
    }

    /// A returning subscriber (expired, then bought again) is one status
    /// entry, Subscribed: the several-entries rule does not lock them out.
    @Test func resubscribingAfterAnExpiryGivesSubscribed() async throws {
        try await withSession { session, store in
            let old = try await session.buyProduct(
                identifier: Self.productID,
                options: [.purchaseDate(Date().addingTimeInterval(-40 * 86_400), renewalBehavior: .cancelImmediately)]
            )
            await old.finish()
            let new = try await session.buyProduct(identifier: Self.productID)
            await new.finish()
            #expect(await becomes(.subscribed, store))
            guard case .statuses(let facts) = await store.read() else {
                Issue.record("no status list")
                return
            }
            #expect(facts.count == 1)
        }
    }

    @Test func aRefundGivesLapsed() async throws {
        try await withSession { session, store in
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            #expect(await becomes(.subscribed, store))
            try session.refundTransaction(identifier: UInt(transaction.id))
            #expect(await becomes(.lapsed, store))
        }
    }

    /// No purchase here: with products failing, the host app's listener
    /// could not finish one, and an unfinished transaction left in this
    /// process confused `theListenerFinishesTransactions` (task 215's log).
    @Test func aProductThatWillNotLoadIsUnknown() async throws {
        try await withSession { session, store in
            try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
            #expect(await store.read() == .failed)
            #expect(await state(store) == .unknown)
            try await session.setSimulatedError(nil, forAPI: .loadProducts)
        }
    }

    /// A failing status call answers an empty list rather than throwing
    /// (experiment 1). With a purchase on record that must not read as Free.
    @Test func aStatusErrorAfterAPurchaseIsUnknownNotFree() async throws {
        try await withSession { session, store in
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            #expect(await becomes(.subscribed, store))
            try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .subscriptionStatus)
            #expect(await state(store) == .unknown)
            try await session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        }
    }

    /// The model's listener: a purchase and a refund made outside the app
    /// reach it without a manual refresh.
    @Test func theListenerFollowsAPurchaseAndARefund() async throws {
        try await withSession { session, store in
            let model = SubscriptionModel(store: store)
            model.start()
            #expect(await pollUntil { model.state == .free })

            let transaction = try await session.buyProduct(identifier: Self.productID)
            #expect(await pollUntil { model.state == .subscribed })
            #expect(model.allowsPaidFeatures)

            try session.refundTransaction(identifier: UInt(transaction.id))
            #expect(await pollUntil { model.state == .lapsed })
            #expect(model.allowsPaidFeatures == false)

            await model.stop()
        }
    }

    /// The listener finishes what it is told about, as Apple asks.
    /// Only on iOS 26 and later: on iOS 18.3 `Transaction.unfinished` was
    /// empty straight after a session purchase that nothing had finished yet,
    /// so it cannot show finishing there, and `SKTestTransaction` has no
    /// finished flag (task 215's log).
    @Test(.enabled(if: Self.unfinishedIsReliable))
    func theListenerFinishesTransactions() async throws {
        try await withSession { session, store in
            let model = SubscriptionModel(store: store)
            model.start()
            // Its first read done, the listener is running before the purchase.
            #expect(await pollUntil { model.state == .free })
            let transaction = try await session.buyProduct(identifier: Self.productID)
            #expect(await pollUntil { await Self.isUnfinished(transaction) == false })
            await model.stop()
        }
    }

    nonisolated static var unfinishedIsReliable: Bool {
        if #available(iOS 26, *) { true } else { false }
    }

    /// Whether this purchase is still unfinished. Matched on ID and purchase
    /// date: IDs start again at 0 after `clearTransactions`, and an earlier
    /// test's transaction whose finishing failed (under a simulated error)
    /// stays in this process's unfinished list.
    private static func isUnfinished(_ transaction: Transaction) async -> Bool {
        for await result in Transaction.unfinished {
            if let other = try? result.payloadValue,
               other.id == transaction.id, other.purchaseDate == transaction.purchaseDate {
                return true
            }
        }
        return false
    }
}
