import StoreKit

/// How a purchase ended, as the popup needs it.
enum PurchaseOutcome: Equatable, Sendable {
    /// A verified transaction, finished.
    case purchased
    /// The person cancelled: nothing changes, nothing is said.
    case cancelled
    /// Waiting for approval (Ask to Buy); it arrives on `Transaction.updates`.
    case pending
    /// StoreKit returned a transaction that did not verify: nothing is
    /// unlocked and it is not finished.
    case unverified
    /// It did not go through. `nothingCharged` only where that is certain:
    /// a `Product.PurchaseError` is raised before any purchase is made.
    case failed(nothingCharged: Bool)
}

/// How Restore Purchases ended.
enum RestoreOutcome: Equatable, Sendable {
    /// `AppStore.sync()` finished; read the subscription again to see what it found.
    case synced
    /// It threw: a network problem, or the App Store sign-in was cancelled.
    case failed
}

/// Starts the App Store's purchase for a product. In the app this is
/// SwiftUI's `PurchaseAction` (Apple's choice for SwiftUI apps, which puts
/// the confirmation in the right scene); in tests `Product.purchase()`.
typealias PurchasePerformer = @MainActor (Product) async throws -> Product.PurchaseResult

/// Where the popup gets the product and makes the purchase and restore.
@MainActor
protocol SubscriptionStorefront: AnyObject {
    /// The monthly product's offer, or nil when it cannot be loaded.
    func loadOffer() async -> StoreOffer?
    /// Runs the purchase and handles its result itself: verifies it and
    /// finishes a verified transaction (a purchase made on this phone comes
    /// back only in the result, not on `Transaction.updates`).
    func purchase(_ perform: PurchasePerformer) async -> PurchaseOutcome
    /// `AppStore.sync()`. Only ever on the person's tap: it can show an App
    /// Store sign-in.
    func restore() async -> RestoreOutcome
}

/// The live storefront: StoreKit 2.
@MainActor
final class StoreKitStorefront: SubscriptionStorefront {
    let productID: String
    private var product: Product?
    private let sync: @MainActor () async throws -> Void

    init(productID: String = SubscriptionRules.productID, sync: @escaping @MainActor () async throws -> Void = { try await AppStore.sync() }) {
        self.productID = productID
        self.sync = sync
    }

    func loadOffer() async -> StoreOffer? {
        do {
            let products = try await Product.products(for: [productID])
            product = products.first { $0.id == productID }
        } catch {
            product = nil
        }
        return product.map { StoreOffer(displayPrice: $0.displayPrice) }
    }

    func purchase(_ perform: PurchasePerformer) async -> PurchaseOutcome {
        if product == nil { _ = await loadOffer() }
        // Never asked of the App Store, so nothing can have been charged.
        guard let product else { return .failed(nothingCharged: true) }
        do {
            return await Self.outcome(of: try await perform(product))
        } catch {
            return Self.outcome(of: error)
        }
    }

    func restore() async -> RestoreOutcome {
        do {
            try await sync()
            return .synced
        } catch {
            return .failed
        }
    }

    /// Verifies the result and finishes a verified transaction. An
    /// unverified one is neither trusted nor finished.
    static func outcome(of result: Product.PurchaseResult) async -> PurchaseOutcome {
        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            return .purchased
        case .success(.unverified):
            return .unverified
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .failed(nothingCharged: false)
        }
    }

    /// A thrown cancel is a cancel; a `Product.PurchaseError` (product
    /// unavailable, purchases not allowed, and the like) stops the purchase
    /// before it is made; anything else (network, system) is not certain.
    static func outcome(of error: any Error) -> PurchaseOutcome {
        if let error = error as? StoreKitError, case .userCancelled = error { return .cancelled }
        if error is Product.PurchaseError { return .failed(nothingCharged: true) }
        return .failed(nothingCharged: false)
    }
}

#if DEBUG
/// DEBUG: the storefront behind a debug subscription state. It never calls
/// StoreKit: the offer is a sample price (or none, with
/// `-debugProductUnavailable YES`), a purchase succeeds at once and Restore
/// finds whatever the debug state says.
@MainActor
final class DebugStorefront: SubscriptionStorefront {
    var offerAvailable: Bool
    /// What the next purchase answers (tests and screenshots).
    var purchaseOutcome: PurchaseOutcome = .purchased
    private(set) var purchases = 0
    private(set) var restores = 0

    /// The sample offer's price, for screenshots only.
    static let samplePrice = "$2.99"

    init(offerAvailable: Bool = true) {
        self.offerAvailable = offerAvailable
    }

    func loadOffer() async -> StoreOffer? {
        offerAvailable ? StoreOffer(displayPrice: Self.samplePrice) : nil
    }

    func purchase(_ perform: PurchasePerformer) async -> PurchaseOutcome {
        purchases += 1
        return purchaseOutcome
    }

    func restore() async -> RestoreOutcome {
        restores += 1
        return .synced
    }
}
#endif
