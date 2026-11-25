import Foundation
import Testing

@testable import Seasign

/// A store that answers its set reading, or, while `hangs` is on, waits
/// until the reading task is cancelled and then answers `.failed`: what
/// `StoreKitSubscriptionStore.read()` does when a StoreKit call throws
/// `CancellationError` (it turns any thrown error into `.failed`).
final class CancellableSubscriptionStore: SubscriptionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SubscriptionReading
    private var hanging = false
    private var waiting: [CheckedContinuation<SubscriptionReading, Never>] = []
    private var startedHanging = 0

    init(_ reading: SubscriptionReading) {
        current = reading
    }

    var reading: SubscriptionReading {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Reads wait for cancellation while this is on.
    var hangs: Bool {
        get { lock.withLock { hanging } }
        set { lock.withLock { hanging = newValue } }
    }

    /// How many reads are waiting or have waited for cancellation.
    var hangingReads: Int { lock.withLock { startedHanging } }

    func read() async -> SubscriptionReading {
        let answer: SubscriptionReading? = lock.withLock { hanging ? nil : current }
        if let answer { return answer }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancelled: Bool = lock.withLock {
                    startedHanging += 1
                    if Task.isCancelled { return true }
                    waiting.append(continuation)
                    return false
                }
                if cancelled { continuation.resume(returning: .failed) }
            }
        } onCancel: {
            let resumed = lock.withLock {
                let all = waiting
                waiting = []
                return all
            }
            for continuation in resumed { continuation.resume(returning: .failed) }
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// A read whose task is cancelled (the popup closed while its `.task` was
/// reading) must not replace the state already held, and must never be
/// taken as an answer that allows anything (task 217 review).
@Suite @MainActor struct SubscriptionCancelledReadTests {
    /// Starts `body` in a task, waits until the store has a read waiting,
    /// cancels the task and returns what the task returned.
    private func cancelMidRead<T: Sendable>(
        _ store: CancellableSubscriptionStore,
        _ body: @escaping @MainActor () async -> T
    ) async -> T {
        let before = store.hangingReads
        let task = Task { @MainActor in await body() }
        #expect(await pollUntil { store.hangingReads > before })
        task.cancel()
        return await task.value
    }

    @Test(arguments: [SubscriptionState.subscribed, .free, .lapsed])
    func aCancelledReadKeepsTheStateAlreadyHeld(_ state: SubscriptionState) async {
        let store = CancellableSubscriptionStore(FixedSubscriptionStore.reading(for: state))
        let model = SubscriptionModel(store: store)
        await model.refresh()
        #expect(model.state == state)

        store.hangs = true
        let returned = await cancelMidRead(store) { await model.refresh() }
        #expect(model.state == state)
        #expect(model.hasAnswered)
        // The caller of a cancelled read is never told anything paid is allowed.
        #expect(returned.state == .unknown)
        #expect(!returned.allowsPaidFeatures)
    }

    /// Fail-closed is kept: a first read that is cancelled leaves the
    /// starting Unknown, with nothing answered.
    @Test func aCancelledFirstReadLeavesTheStartingUnknown() async {
        let store = CancellableSubscriptionStore(FixedSubscriptionStore.reading(for: .subscribed))
        store.hangs = true
        let model = SubscriptionModel(store: store)
        let returned = await cancelMidRead(store) { await model.refresh() }
        #expect(model.state == .unknown)
        #expect(!model.hasAnswered)
        #expect(returned.state == .unknown)
    }

    /// The popup closed during the read it started: the gate still says
    /// what it said (a subscriber is not pushed to the Unknown popup).
    @Test func closingThePopupMidReadKeepsTheGate() async {
        let store = CancellableSubscriptionStore(FixedSubscriptionStore.reading(for: .subscribed))
        let model = SubscriptionModel(store: store)
        await model.refresh()
        let gate = UpgradeModel(subscription: model, storefront: ScriptedStorefront())
        store.hangs = true
        await cancelMidRead(store) { await gate.opened() }
        #expect(gate.decision == .settings)
        #expect(gate.state == .subscribed)
    }

    /// A later read that is not cancelled still lands as usual.
    @Test func aReadAfterACancelledOneLands() async {
        let store = CancellableSubscriptionStore(FixedSubscriptionStore.reading(for: .subscribed))
        let model = SubscriptionModel(store: store)
        await model.refresh()
        store.hangs = true
        _ = await cancelMidRead(store) { await model.refresh() }
        store.hangs = false
        store.reading = FixedSubscriptionStore.reading(for: .lapsed)
        #expect(await model.refresh().state == .lapsed)
        #expect(model.state == .lapsed)
    }
}
