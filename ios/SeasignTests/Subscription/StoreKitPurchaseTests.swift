import Foundation
import StoreKit
import StoreKitTest
import Testing

@testable import Seasign

/// UPGRADE NOW and RESTORE PURCHASES (task 217) against Xcode's local
/// StoreKit test environment, through the live `StoreKitStorefront` and the
/// real `SubscriptionModel` over `StoreKitSubscriptionStore`. An extension
/// of `StoreKitSubscriptionTests`, so it shares that suite's one-at-a-time
/// run and its clean start and end: there is one test environment per
/// simulator. The app's purchase goes through SwiftUI's `PurchaseAction`;
/// here it is `Product.purchase()`, the same call underneath with no scene.
extension StoreKitSubscriptionTests {
    private static let buy: PurchasePerformer = { try await $0.purchase() }

    private func storeKitGate() -> UpgradeModel {
        UpgradeModel(
            subscription: SubscriptionModel(store: StoreKitSubscriptionStore()),
            storefront: StoreKitStorefront(),
            // StoreKit can take a moment to report a purchase (iOS 18.3).
            confirmReads: 20,
            confirmDelay: .milliseconds(250)
        )
    }

    /// Any transaction for the product on record.
    private static func hasTransaction() async -> Bool {
        for await result in Transaction.all {
            if (try? result.payloadValue)?.productID == productID { return true }
        }
        return false
    }

    /// Unfinished transactions for the product bought at or after `since`.
    private static func unfinished(since: Date) async -> Int {
        var count = 0
        for await result in Transaction.unfinished {
            if let transaction = try? result.payloadValue,
               transaction.productID == productID, transaction.purchaseDate >= since.addingTimeInterval(-1) {
                count += 1
            }
        }
        return count
    }

    @Test func storeKitPurchaseUnlocksSettingsAndFinishesTheTransaction() async throws {
        try await withSession { _, _ in
            let gate = storeKitGate()
            await gate.opened()
            #expect(gate.state == .free)
            #expect(gate.offer == .available(StoreOffer(displayPrice: "$2.99")))
            #expect(gate.content.buttons.first == .upgradeNow)

            let started = Date()
            await gate.upgrade(Self.buy)
            #expect(gate.decision == .settings)
            #expect(gate.note == nil)
            if Self.unfinishedIsReliable {
                // Finished by the purchase code itself, not by a listener
                // (none runs here).
                #expect(await Self.unfinished(since: started) == 0)
            }
        }
    }

    /// A thrown cancel changes nothing and says nothing.
    @Test func storeKitPurchaseCancelledChangesNothing() async throws {
        try await withSession { session, _ in
            let gate = storeKitGate()
            await gate.opened()
            try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
            await gate.upgrade(Self.buy)
            #expect(gate.note == nil)
            #expect(gate.decision == .popup(.free))
            #expect(!(await Self.hasTransaction()))
        }
    }

    @Test func storeKitPurchaseAskToBuyIsPending() async throws {
        try await withSession { session, _ in
            session.askToBuyEnabled = true
            let gate = storeKitGate()
            await gate.opened()
            await gate.upgrade(Self.buy)
            #expect(gate.note == .purchasePending)
            #expect(gate.decision == .popup(.free))
        }
    }

    /// A purchase error stops it before anything is bought: no transaction,
    /// and the popup may say nothing was charged.
    @Test func storeKitPurchaseNotAllowedChargesNothing() async throws {
        try await withSession { session, _ in
            let gate = storeKitGate()
            await gate.opened()
            try await session.setSimulatedError(.purchase(.purchaseNotAllowed), forAPI: .purchase)
            await gate.upgrade(Self.buy)
            #expect(gate.note == .purchaseFailed(nothingCharged: true))
            #expect(gate.decision == .popup(.free))
            #expect(!(await Self.hasTransaction()))
        }
    }

    /// A network failure is worded without the claim.
    @Test func storeKitPurchaseNetworkFailureIsNeutral() async throws {
        try await withSession { session, _ in
            let gate = storeKitGate()
            await gate.opened()
            try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
            await gate.upgrade(Self.buy)
            #expect(gate.note == .purchaseFailed(nothingCharged: false))
            #expect(gate.decision == .popup(.free))
        }
    }

    /// A transaction that does not verify unlocks nothing.
    @Test func storeKitPurchaseUnverifiedUnlocksNothing() async throws {
        try await withSession { session, _ in
            let gate = storeKitGate()
            await gate.opened()
            try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
            await gate.upgrade(Self.buy)
            #expect(gate.note == .purchaseUnverified)
            #expect(gate.decision != .settings)
        }
    }

    /// Restore: a subscription bought elsewhere (the session's purchase, as
    /// on another device) is found and opens Settings.
    @Test(.timeLimit(.minutes(1)))
    func storeKitRestoreFindsASubscription() async throws {
        try await withSession { session, _ in
            let gate = storeKitGate()
            await gate.opened()
            #expect(gate.state == .free)
            let transaction = try await session.buyProduct(identifier: Self.productID)
            await transaction.finish()
            await gate.restore()
            #expect(gate.decision == .settings)
            #expect(gate.note == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func storeKitRestoreWithNothingSaysSo() async throws {
        try await withSession { _, _ in
            let gate = storeKitGate()
            await gate.opened()
            await gate.restore()
            #expect(gate.note == .restoreFoundNothing)
            #expect(gate.decision == .popup(.free))
        }
    }

    /// A cancelled App Store sign-in (or any sync error) says it could not
    /// be checked, not that there is nothing.
    @Test func storeKitRestoreCancelledCouldNotCheck() async throws {
        try await withSession { session, _ in
            let gate = storeKitGate()
            await gate.opened()
            try await session.setSimulatedError(.generic(.userCancelled), forAPI: .appStoreSync)
            await gate.restore()
            #expect(gate.note == .restoreFailed)
        }
    }
}
