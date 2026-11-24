import StoreKit

/// Where `SubscriptionModel` reads the subscription from: StoreKit in the
/// app, a fixed answer in tests and with `-debugSubscription`.
protocol SubscriptionStore: Sendable {
    /// One read of the subscription.
    func read() async -> SubscriptionReading
    /// Yields whenever the subscription may have changed. Runs until the
    /// stream's consumer stops.
    func changes() -> AsyncStream<Void>
}

/// The live store: StoreKit 2.
struct StoreKitSubscriptionStore: SubscriptionStore {
    var productID = SubscriptionRules.productID

    func read() async -> SubscriptionReading {
        do {
            let products = try await Product.products(for: [productID])
            guard let subscription = products.first(where: { $0.id == productID })?.subscription else {
                return .failed
            }
            let statuses = try await subscription.status
            // `Transaction.all` is read only when there is no status, to tell
            // Free from a status call that answered empty.
            guard !statuses.isEmpty else { return .noStatus(hasHistory: await hasHistory()) }
            return .statuses(statuses.map(Self.fact))
        } catch {
            return .failed
        }
    }

    /// Transaction updates (purchases, renewals, refunds, and unfinished
    /// transactions once at launch) and subscription status updates.
    /// Verified transactions are finished here, as Apple asks once the
    /// purchase is delivered. Neither stream fired when Xcode's test
    /// environment expired a subscription (task 215); whether a real expiry
    /// reaches a running app is not verified.
    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let transactions = Task.detached {
                for await result in Transaction.updates {
                    if case .verified(let transaction) = result {
                        await transaction.finish()
                    }
                    continuation.yield()
                }
            }
            let statuses = Task.detached {
                for await _ in Product.SubscriptionInfo.Status.updates {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in
                transactions.cancel()
                statuses.cancel()
            }
        }
    }

    /// Any transaction for the product, verified or not, current or not.
    private func hasHistory() async -> Bool {
        for await result in Transaction.all {
            let transaction = switch result {
            case .verified(let transaction), .unverified(let transaction, _): transaction
            }
            if transaction.productID == productID { return true }
        }
        return false
    }

    /// One status entry. The dates come from the transaction only when it
    /// verified; an unverified entry never counts as subscribed anyway.
    private static func fact(_ status: Product.SubscriptionInfo.Status) -> RenewalFact {
        let transaction: Transaction? = if case .verified(let transaction) = status.transaction { transaction } else { nil }
        return RenewalFact(
            renewalState: status.state,
            isVerified: transaction != nil && isVerified(status.renewalInfo),
            expirationDate: transaction?.expirationDate,
            revocationDate: transaction?.revocationDate
        )
    }

    private static func isVerified<T>(_ result: VerificationResult<T>) -> Bool {
        if case .verified = result { return true }
        return false
    }
}

#if DEBUG
/// A store that always gives the same reading: tests, and the DEBUG
/// `-debugSubscription` argument. Its `changes()` yields `pokes` and ends.
struct FixedSubscriptionStore: SubscriptionStore {
    var reading: SubscriptionReading
    var pokes = 0

    init(reading: SubscriptionReading, pokes: Int = 0) {
        self.reading = reading
        self.pokes = pokes
    }

    /// A store whose reading gives `state`.
    init(state: SubscriptionState) {
        self.init(reading: Self.reading(for: state))
    }

    func read() async -> SubscriptionReading {
        reading
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            for _ in 0..<pokes { continuation.yield() }
            continuation.finish()
        }
    }

    /// A reading the rules turn into `state`.
    static func reading(for state: SubscriptionState) -> SubscriptionReading {
        switch state {
        case .free: .noStatus(hasHistory: false)
        // Far from any clock a test or a screenshot uses.
        case .subscribed: .statuses([RenewalFact(renewalState: .subscribed, isVerified: true, expirationDate: .distantFuture)])
        case .lapsed: .statuses([RenewalFact(renewalState: .expired, isVerified: true, expirationDate: .distantPast)])
        case .unknown: .failed
        }
    }
}
#endif
