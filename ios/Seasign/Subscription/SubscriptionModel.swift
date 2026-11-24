import Foundation
import Observation

/// What AI search (task 216) reads about the subscription: the state as
/// last judged, a fresh read on demand, and a call after every read that
/// lands. `SubscriptionModel` is the real one.
@MainActor
protocol SubscriptionSource: AnyObject {
    /// The state as last judged; `unknown` until a read has landed.
    var access: SubscriptionAccess { get }
    /// Whether any read has landed yet. Before that, `access` is the
    /// starting `unknown`, which allows nothing but is not an answer.
    var hasAnswered: Bool { get }
    /// Reads again and returns the state judged from a read that started
    /// after this call (this one, or a later one that landed first).
    @discardableResult func refresh() async -> SubscriptionAccess
    /// Calls `handler` with the state after every read that lands, whether
    /// or not it changed (a first read that fails is still Unknown).
    func whenJudged(_ handler: @escaping @MainActor (SubscriptionAccess) -> Void)
}

/// The subscription state the app shows and gates on. AI search obeys it
/// through `SubscriptionSource` (task 216); the Settings popup comes next.
///
/// It starts `unknown`, so nothing paid is allowed until StoreKit has
/// answered `subscribed`.
@MainActor @Observable
final class SubscriptionModel: SubscriptionSource {
    private(set) var state: SubscriptionState = .unknown
    /// A read has landed (`state` is an answer, not the starting value).
    private(set) var hasAnswered = false
    /// Sign in with Apple arrives in phase C; false until then.
    var isSignedIn = false

    var access: SubscriptionAccess {
        SubscriptionAccess(state: state, isSignedIn: isSignedIn)
    }

    /// True only for `subscribed` (the hard rule; see `SubscriptionState`).
    var allowsPaidFeatures: Bool {
        access.allowsPaidFeatures
    }

    @ObservationIgnored private let store: any SubscriptionStore
    /// The time the rules judge an expiry against (the phone's clock in the
    /// app; set by tests).
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var listener: Task<Void, Never>?

    init(store: any SubscriptionStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Numbers each read in the order it started.
    @ObservationIgnored private var readsStarted = 0
    /// The number of the latest-started read whose answer was used.
    @ObservationIgnored private var latestUsed = 0
    @ObservationIgnored private var judgedHandlers: [@MainActor (SubscriptionAccess) -> Void] = []

    func whenJudged(_ handler: @escaping @MainActor (SubscriptionAccess) -> Void) {
        judgedHandlers.append(handler)
    }

    /// Reads the store again. Reads may overlap (the listener and, later,
    /// callers before a paid request); an answer is used only if no read
    /// that started after it has already been used, so an older, staler
    /// answer never replaces a newer one. Returns the state as judged after
    /// this read: its own answer, or that of a read that started later and
    /// landed first. Either way it comes from a read started after the call,
    /// which is what a paid request must go by (task 216).
    @discardableResult
    func refresh() async -> SubscriptionAccess {
        readsStarted += 1
        let number = readsStarted
        let reading = await store.read()
        guard number > latestUsed else { return access }
        latestUsed = number
        state = SubscriptionRules.state(from: reading, now: now())
        hasAnswered = true
        let judged = access
        for handler in judgedHandlers { handler(judged) }
        return judged
    }

    /// Reads once, then again on every change the store reports. Started
    /// once at launch (`SeasignApp.start`); a second call does nothing.
    func start() {
        guard listener == nil else { return }
        let changes = store.changes()
        listener = Task { [weak self] in
            await self?.refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    /// Stops listening. Waits for the listener to end.
    func stop() async {
        listener?.cancel()
        await listener?.value
        listener = nil
    }

    /// The listening task, for tests to wait on with a store whose changes
    /// end.
    var listenerTask: Task<Void, Never>? { listener }
}
