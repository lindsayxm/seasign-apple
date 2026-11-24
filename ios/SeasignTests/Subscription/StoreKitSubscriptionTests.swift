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

    private func withSession(_ body: (SKTestSession, StoreKitSubscriptionStore) async throws -> Void) async throws {
        // `Bundle.main` is the host app; the file is in the test bundle.
        let url = try #require(Bundle(for: TestBundleMarker.self).url(forResource: "Seasign", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        // The environment outlives a run, so no simulated error is left over.
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try await session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        session.clearTransactions()
        defer {
            session.clearTransactions()
            session.resetToDefaultState()
        }
        try await body(session, StoreKitSubscriptionStore())
    }

    private func state(_ store: StoreKitSubscriptionStore) async -> SubscriptionState {
        SubscriptionRules.state(from: await store.read())
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

    @Test func aRefundGivesLapsed() async throws {
        try await withSession { session, store in
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            #expect(await becomes(.subscribed, store))
            try session.refundTransaction(identifier: UInt(transaction.id))
            #expect(await becomes(.lapsed, store))
        }
    }

    @Test func aProductThatWillNotLoadIsUnknown() async throws {
        try await withSession { session, store in
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            #expect(await becomes(.subscribed, store))
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
            try await session.buyProduct(identifier: Self.productID)
            #expect(await pollUntil { await Self.unfinishedCount() == 0 })
            await model.stop()
        }
    }

    nonisolated static var unfinishedIsReliable: Bool {
        if #available(iOS 26, *) { true } else { false }
    }

    private static func unfinishedCount() async -> Int {
        var count = 0
        for await result in Transaction.unfinished where (try? result.payloadValue.productID) == productID {
            count += 1
        }
        return count
    }
}
