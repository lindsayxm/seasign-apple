import Foundation
import Observation

/// The subscription state the app shows and gates on. Nothing reads it yet
/// (task 215); the AI gate (task 216) and the Settings popup come next.
///
/// It starts `unknown`, so nothing paid is allowed until StoreKit has
/// answered `subscribed`.
@MainActor @Observable
final class SubscriptionModel {
    private(set) var state: SubscriptionState = .unknown
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

    /// Reads the store again. Reads may overlap (the listener and, later,
    /// callers before a paid request); an answer is used only if no read
    /// that started after it has already been used, so an older, staler
    /// answer never replaces a newer one.
    func refresh() async {
        readsStarted += 1
        let number = readsStarted
        let reading = await store.read()
        guard number > latestUsed else { return }
        latestUsed = number
        state = SubscriptionRules.state(from: reading, now: now())
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
