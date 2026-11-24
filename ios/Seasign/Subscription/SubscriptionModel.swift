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
    @ObservationIgnored private var listener: Task<Void, Never>?

    init(store: any SubscriptionStore) {
        self.store = store
    }

    /// Reads the store again.
    func refresh() async {
        state = SubscriptionRules.state(from: await store.read())
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
