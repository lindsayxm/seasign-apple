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
    /// The verified transaction's expiry, nil when it has none or did not
    /// verify.
    var expirationDate: Date?
    /// The verified transaction's revocation (refund), nil when none.
    var revocationDate: Date?
}

/// What one read of StoreKit gave.
enum SubscriptionReading: Equatable, Sendable {
    /// The group's status list, as StoreKit gave it.
    case statuses([RenewalFact])
    /// StoreKit's status list was empty; `hasHistory` is whether any
    /// transaction for the product is on record (read only in this case).
    case noStatus(hasHistory: Bool)
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

    /// One status entry at `now`. A `subscribed` renewal state is not taken
    /// on StoreKit's word alone: StoreKit went on answering "subscribed" in a
    /// running process after the subscription expired (task 215), so the
    /// verified transaction must also be unrevoked and unexpired.
    /// - unverified: `unknown`;
    /// - `subscribed` with a revocation date: `lapsed` (refunded or revoked);
    /// - `subscribed` with no expiry date: `unknown` (an auto-renewable
    ///   subscription always has one, so this cannot be checked);
    /// - `subscribed` with the expiry at or before `now`: `lapsed`;
    /// - `subscribed` otherwise: `subscribed`;
    /// - any other state: as `state(for:)`, whatever the dates say.
    /// A phone clock set back defeats the expiry check; phase B's server
    /// check is the answer to that.
    static func state(of fact: RenewalFact, now: Date) -> SubscriptionState {
        guard fact.isVerified else { return .unknown }
        let state = state(for: fact.renewalState)
        guard state == .subscribed else { return state }
        if fact.revocationDate != nil { return .lapsed }
        guard let expiry = fact.expirationDate else { return .unknown }
        return expiry > now ? .subscribed : .lapsed
    }

    /// The state from one read of StoreKit at `now`. Fails closed:
    /// - a failed read is `unknown`;
    /// - no status and no history is `free`; no status but some history is
    ///   `unknown` (StoreKit's status call answers an empty list when it
    ///   errors, task 215's experiment, so empty alone is not proof of Free);
    /// - each entry is judged by `state(of:now:)`;
    /// - any `unknown` entry makes it `unknown`;
    /// - entries that all agree give that state;
    /// - `subscribed` beside `lapsed` is `unknown`. Family Sharing is off,
    ///   so StoreKit should give one entry for the group (a returning
    ///   subscriber is one entry, task 215's test); two that disagree cannot
    ///   be told apart on the phone (a stale "subscribed" beside a fresh
    ///   "revoked" looks just like this), so nothing paid is allowed.
    static func state(from reading: SubscriptionReading, now: Date) -> SubscriptionState {
        switch reading {
        case .failed:
            return .unknown
        case .noStatus(let hasHistory):
            return hasHistory ? .unknown : .free
        case .statuses(let facts):
            let states = Set(facts.map { state(of: $0, now: now) })
            guard states.count == 1, let only = states.first else { return .unknown }
            return only
        }
    }

    #if DEBUG
    /// The state a DEBUG launch argument names (`-debugSubscription lapsed`),
    /// or nil.
    static func debugNamed(_ name: String?) -> SubscriptionState? {
        name.flatMap(SubscriptionState.init(rawValue:))
    }
    #endif
}
