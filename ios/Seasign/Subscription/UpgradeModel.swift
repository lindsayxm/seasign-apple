import Foundation
import Observation

/// The gate on Settings and its upgrade popup (task 217). It reads the real
/// subscription (`SubscriptionModel` in the app) and decides with
/// `SettingsGate`; it loads the product, runs the purchase and Restore
/// Purchases through a `SubscriptionStorefront`, and says what happened.
///
/// It never decides AI search: AI search reads the subscription model
/// itself (`SeasignApp.subscriptionWiring`). In DEBUG a debug state set
/// here (`-debugSubscription`, or the Debug subscription control) changes
/// the gate and Settings only.
@MainActor @Observable
final class UpgradeModel {
    /// The real subscription.
    let subscription: any SubscriptionSource
    @ObservationIgnored private let storefront: any SubscriptionStorefront
    /// After a purchase, how often and how far apart the subscription is
    /// read again until it says Subscribed (on iOS 18.3 the first status
    /// read straight after a purchase was still empty, task 215).
    @ObservationIgnored private let confirmReads: Int
    @ObservationIgnored private let confirmDelay: Duration

    private(set) var offer: OfferStatus = .loading
    /// What is running: the popup's buttons wait while it is set.
    private(set) var busy: Busy?
    /// A line about the last purchase or restore.
    private(set) var note: UpgradeNote?

    enum Busy: Equatable {
        case checking, purchasing, restoring
    }

    #if DEBUG
    /// DEBUG: the state the gate uses instead of the real one, or nil.
    private(set) var debugState: SubscriptionState?
    @ObservationIgnored private let debugStorefront: DebugStorefront
    #endif

    init(
        subscription: any SubscriptionSource,
        storefront: any SubscriptionStorefront,
        confirmReads: Int = 6,
        confirmDelay: Duration = .milliseconds(500)
    ) {
        self.subscription = subscription
        self.storefront = storefront
        self.confirmReads = max(1, confirmReads)
        self.confirmDelay = confirmDelay
        #if DEBUG
        debugStorefront = DebugStorefront()
        #endif
    }

    /// The state the gate goes by.
    var state: SubscriptionState {
        #if DEBUG
        if let debugState { return debugState }
        #endif
        return subscription.access.state
    }

    /// Whether the state is an answer (a read has landed, or a debug state is set).
    var hasAnswered: Bool {
        #if DEBUG
        if debugState != nil { return true }
        #endif
        return subscription.hasAnswered
    }

    var decision: SettingsGate.Decision {
        SettingsGate.decision(for: state)
    }

    /// What Settings allows now (read-only unless Subscribed).
    var settingsAccess: SettingsAccess {
        SettingsAccess(state: state)
    }

    /// The popup's kind, or nil while no read has landed.
    var popupKind: SettingsGate.PopupKind? {
        guard hasAnswered else { return nil }
        switch decision {
        case .settings: return nil
        case .popup(let kind): return kind
        }
    }

    var content: UpgradePopupContent {
        // Subscribed has no popup; if one is still on screen it shows the
        // checking line until the cover switches to Settings.
        UpgradePopupContent.make(kind: popupKind, offer: offer)
    }

    // MARK: Reading

    /// Reads the subscription again (the app coming to the foreground).
    func refreshSubscription() async {
        await subscription.refresh()
    }

    /// The popup opened: read the subscription again and load the product.
    func opened() async {
        note = nil
        async let read: Void = refreshSubscription()
        async let load: Void = loadOffer()
        _ = await (read, load)
    }

    /// TRY AGAIN: reads the subscription again and reloads the product.
    func tryAgain() async {
        guard busy == nil else { return }
        busy = .checking
        note = nil
        offer = .loading
        await opened()
        busy = nil
    }

    func loadOffer() async {
        offer = await activeStorefront.loadOffer().map(OfferStatus.available) ?? .unavailable
    }

    // MARK: Purchase and restore

    /// UPGRADE NOW. Runs the purchase only for Free or Lapsed (never for a
    /// subscriber, nor for Unknown, which may be one; also refused before
    /// any read has landed) and only when the product loaded; on a
    /// verified purchase reads the subscription until it says Subscribed,
    /// which opens Settings (`decision`). Cancel changes nothing.
    func upgrade(_ perform: @escaping PurchasePerformer) async {
        guard busy == nil, state == .free || state == .lapsed, case .available = offer else { return }
        busy = .purchasing
        note = nil
        let outcome = await activeStorefront.purchase(perform)
        switch outcome {
        case .purchased:
            #if DEBUG
            if debugState != nil { debugState = .subscribed }
            #endif
            note = await readUntilSubscribed() ? nil : .purchaseNotConfirmed
        case .cancelled:
            break
        case .pending:
            note = .purchasePending
        case .unverified:
            note = .purchaseUnverified
        case .failed(let nothingCharged):
            note = .purchaseFailed(nothingCharged: nothingCharged)
        }
        busy = nil
    }

    /// RESTORE PURCHASES: `AppStore.sync()` (on this tap only), then reads
    /// the subscription. Subscribed opens Settings; Free or Lapsed says none
    /// was found; a failed sync or an Unknown state says it could not be
    /// checked, never that there is none.
    func restore() async {
        guard busy == nil else { return }
        busy = .restoring
        note = nil
        switch await activeStorefront.restore() {
        case .synced:
            if !(await readUntilSubscribed()) {
                note = state == .unknown ? .restoreFailed : .restoreFoundNothing
            }
        case .failed:
            await refreshSubscription()
            if state != .subscribed { note = .restoreFailed }
        }
        busy = nil
    }

    /// Reads until the state is Subscribed, at most `confirmReads` times.
    private func readUntilSubscribed() async -> Bool {
        #if DEBUG
        // A debug state does not change by waiting.
        if debugState != nil {
            await refreshSubscription()
            return state == .subscribed
        }
        #endif
        for attempt in 0..<confirmReads {
            if attempt > 0 { try? await Task.sleep(for: confirmDelay) }
            await refreshSubscription()
            if state == .subscribed { return true }
        }
        return false
    }

    private var activeStorefront: any SubscriptionStorefront {
        #if DEBUG
        if debugState != nil { return debugStorefront }
        #endif
        return storefront
    }

    // MARK: DEBUG

    #if DEBUG
    /// Sets the debug state (nil: the real one) and reloads the offer from
    /// the storefront that now applies. It never touches AI search.
    func setDebugState(_ state: SubscriptionState?, offerAvailable: Bool? = nil) {
        debugState = state
        if let offerAvailable { debugStorefront.offerAvailable = offerAvailable }
        note = nil
        offer = .loading
        Task { await loadOffer() }
    }

    /// The DEBUG storefront, for tests.
    var debugStorefrontForTests: DebugStorefront { debugStorefront }
    #endif
}

#if DEBUG
/// DEBUG: the persistent subscription state for the gate (task 217). One
/// `UserDefaults` key serves the `-debugSubscription` launch argument and
/// the Debug subscription control in Settings and on the popup, like the
/// Debug scene's keys. Release builds have neither.
enum SubscriptionDebug {
    static let key = "debugSubscription"
    /// `-debugProductUnavailable YES`: the debug storefront has no product.
    static let productUnavailableKey = "debugProductUnavailable"

    /// Stores `state` for later launches (nil: Live).
    static func persist(_ state: SubscriptionState?, in defaults: UserDefaults = .standard) {
        if let state {
            defaults.set(state.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
