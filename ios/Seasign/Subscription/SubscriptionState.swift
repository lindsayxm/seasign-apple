import StoreKit

/// Where the person stands with the monthly subscription
/// (`plans/2026-11-24-account-and-subscription.md`, "The three states", plus
/// Unknown for when StoreKit cannot say).
///
/// HARD RULE (`memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md`):
/// no AI, nothing that costs money, unless the state is `subscribed`.
/// `unknown` counts as not subscribed. Ask `allowsPaidFeatures`, never
/// compare against the other cases.
enum SubscriptionState: String, Sendable, CaseIterable {
    /// No subscription ever bought on this Apple account.
    case free
    /// An active subscription.
    case subscribed
    /// Had one; now expired, refunded, revoked, or a renewal failed (grace
    /// period and billing retry count as lapsed: the user, 2026-11-24).
    case lapsed
    /// StoreKit did not answer, answered with something this build does not
    /// know, or answered with data that did not verify.
    case unknown

    /// True only for `subscribed`. The one question every paid feature asks.
    var allowsPaidFeatures: Bool {
        self == .subscribed
    }
}

/// The subscription state together with whether the person has signed in.
/// Signing in arrives in phase C; until then `isSignedIn` is always false.
/// It is a separate input so the account step adds to these rules rather
/// than rewriting them.
struct SubscriptionAccess: Equatable, Sendable {
    var state: SubscriptionState
    var isSignedIn: Bool

    /// True only for `subscribed`, whatever `isSignedIn` says.
    var allowsPaidFeatures: Bool {
        state.allowsPaidFeatures
    }

    /// Paid, but has not finished Sign in with Apple ("account not
    /// finished" in the plan).
    var accountNotFinished: Bool {
        state == .subscribed && !isSignedIn
    }
}

/// One entry of StoreKit's subscription status for our group, reduced to
/// what the rules need.
struct RenewalFact: Equatable, Sendable {
    var renewalState: Product.SubscriptionInfo.RenewalState
    /// Both the transaction and the renewal info passed StoreKit's
    /// verification.
    var isVerified: Bool
}

/// What one read of StoreKit gave.
enum SubscriptionReading: Equatable, Sendable {
    /// StoreKit answered. `statuses` is the group's status list;
    /// `hasHistory` is whether any transaction for the product exists.
    case answered(statuses: [RenewalFact], hasHistory: Bool)
    /// The product did not load or the status call threw.
    case failed
}

enum SubscriptionRules {
    /// The one product (App Store Connect, set up by the user in phase D).
    static let productID = "technology.artisan.seasign.monthly"

    /// One renewal state as the app sees it (table in
    /// `memory/notes/2026-11-24-storekit-research.md`).
    /// `RenewalState` is a struct, so anything a later StoreKit adds lands
    /// in `default`: not subscribed.
    static func state(for renewalState: Product.SubscriptionInfo.RenewalState) -> SubscriptionState {
        switch renewalState {
        case .subscribed: .subscribed
        case .inGracePeriod, .inBillingRetryPeriod, .expired, .revoked: .lapsed
        default: .unknown
        }
    }

    /// The state from one read of StoreKit. Fails closed:
    /// - a failed read is `unknown`;
    /// - no status and no history is `free`; no status but some history is
    ///   `unknown` (StoreKit's status call answers an empty list when it
    ///   errors, task 215's experiment, so empty alone is not proof of Free);
    /// - a verified `subscribed` entry makes it `subscribed`;
    /// - otherwise any unverified or unrecognised entry makes it `unknown`;
    /// - otherwise (all entries verified and lapsed) `lapsed`.
    static func state(from reading: SubscriptionReading) -> SubscriptionState {
        guard case .answered(let statuses, let hasHistory) = reading else { return .unknown }
        if statuses.isEmpty { return hasHistory ? .unknown : .free }
        let states = statuses.map { $0.isVerified ? state(for: $0.renewalState) : .unknown }
        if states.contains(.subscribed) { return .subscribed }
        if states.contains(.unknown) { return .unknown }
        return .lapsed
    }

    #if DEBUG
    /// The state a DEBUG launch argument names (`-debugSubscription lapsed`),
    /// or nil.
    static func debugNamed(_ name: String?) -> SubscriptionState? {
        name.flatMap(SubscriptionState.init(rawValue:))
    }
    #endif
}
