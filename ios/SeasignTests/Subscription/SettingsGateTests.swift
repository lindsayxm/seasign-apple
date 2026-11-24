import Foundation
import StoreKit
import SwiftData
import SwiftUI
import Testing

@testable import Seasign

/// A storefront the tests script: what the offer, a purchase and a restore
/// answer, and what a purchase or restore does to the subscription store.
@MainActor
final class ScriptedStorefront: SubscriptionStorefront {
    var offer: StoreOffer? = StoreOffer(displayPrice: "$2.99")
    var purchaseOutcome: PurchaseOutcome = .purchased
    var restoreOutcome: RestoreOutcome = .synced
    /// Runs when a purchase or restore answers (e.g. the store now says Subscribed).
    var afterPurchase: () -> Void = {}
    var afterRestore: () -> Void = {}
    private(set) var loads = 0
    private(set) var purchases = 0
    private(set) var restores = 0

    func loadOffer() async -> StoreOffer? {
        loads += 1
        return offer
    }

    func purchase(_ perform: PurchasePerformer) async -> PurchaseOutcome {
        purchases += 1
        afterPurchase()
        return purchaseOutcome
    }

    func restore() async -> RestoreOutcome {
        restores += 1
        afterRestore()
        return restoreOutcome
    }
}

/// The gate on Settings (task 217): the decision for each state, the
/// locked default, the popup's content, purchase and restore through the
/// storefront seam, the read-only rule, the free zip code and the DEBUG
/// state. The StoreKit versions of purchase and restore are in
/// `StoreKitPurchaseTests` (`StoreKitSubscriptionTests`, serialized).
@Suite @MainActor struct SettingsGateTests {
    /// A gate over the real `SubscriptionModel`, whose store first answers `state`.
    private func gate(
        _ state: SubscriptionState,
        read: Bool = true,
        storefront: ScriptedStorefront = ScriptedStorefront()
    ) async -> (UpgradeModel, ScriptedSubscriptionStore, ScriptedStorefront) {
        let store = ScriptedSubscriptionStore(FixedSubscriptionStore.reading(for: state))
        let model = SubscriptionModel(store: store)
        if read { await model.refresh() }
        let gate = UpgradeModel(subscription: model, storefront: storefront, confirmReads: 3, confirmDelay: .milliseconds(10))
        return (gate, store, storefront)
    }

    // MARK: The decision

    @Test func theGateDecidesForEachState() {
        #expect(SettingsGate.decision(for: .subscribed) == .settings)
        #expect(SettingsGate.decision(for: .free) == .popup(.free))
        #expect(SettingsGate.decision(for: .lapsed) == .popup(.lapsed))
        #expect(SettingsGate.decision(for: .unknown) == .popup(.unknown))
    }

    @Test(arguments: SubscriptionState.allCases)
    func theGateModelFollowsTheRealSubscription(_ state: SubscriptionState) async {
        let (gate, _, _) = await gate(state)
        #expect(gate.state == state)
        #expect(gate.decision == SettingsGate.decision(for: state))
        #expect(gate.settingsAccess.isReadOnly == (state != .subscribed))
    }

    /// The production default is locked: before any read the state is the
    /// starting Unknown, the gate shows the popup (its checking line),
    /// Settings would be read-only, and the environment's default is
    /// read-only too.
    @Test func theProductionDefaultIsLocked() {
        let wiring = SeasignApp.productionSubscription(realStore: HeldSubscriptionStore(), storefront: ScriptedStorefront())
        #expect(wiring.gate.state == .unknown)
        #expect(!wiring.gate.hasAnswered)
        #expect(wiring.gate.decision == .popup(.unknown))
        #expect(wiring.gate.popupKind == nil)
        #expect(wiring.gate.content.headline == UpgradeWords.checkingHeadline)
        #expect(wiring.gate.content.buttons == [.changeZip])
        #expect(wiring.gate.settingsAccess == .readOnly)
        #expect(EnvironmentValues().settingsAccess == .readOnly)
        #if DEBUG
        #expect(wiring.gate.debugState == nil)
        #endif
    }

    /// The re-read when the popup opens can open Settings: a subscriber who
    /// taps before the first read landed sees the checking line, then
    /// Settings.
    @Test func openingThePopupReadsAgainAndLoadsTheProduct() async {
        let (gate, store, storefront) = await gate(.subscribed, read: false)
        #expect(gate.decision == .popup(.unknown))
        await gate.opened()
        #expect(store.reads == 1)
        #expect(storefront.loads == 1)
        #expect(gate.decision == .settings)
        #expect(gate.offer == .available(StoreOffer(displayPrice: "$2.99")))
        #expect(storefront.restores == 0)
        #expect(storefront.purchases == 0)
    }

    @Test func comingBackToTheForegroundReadsAgain() async {
        let (gate, store, _) = await gate(.lapsed)
        store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        await gate.refreshSubscription()
        #expect(gate.decision == .settings)
    }

    // MARK: The popup's content

    @Test func theFreePopup() {
        let content = UpgradePopupContent.make(kind: .free, offer: .available(StoreOffer(displayPrice: "$2.99")))
        #expect(content.headline == "You need an account to update settings.")
        #expect(content.showsDescription)
        #expect(content.priceLine == "$2.99 a month. Renews monthly until you cancel.")
        #expect(!content.storeUnreachable)
        #expect(content.showsTerms)
        #expect(content.buttons == [.upgradeNow, .restorePurchases, .changeZip])
    }

    @Test func theLapsedPopup() {
        let content = UpgradePopupContent.make(kind: .lapsed, offer: .available(StoreOffer(displayPrice: "2,99 €")))
        #expect(content.headline == "Your subscription isn't active.")
        #expect(content.showsDescription)
        #expect(content.priceLine == "2,99 € a month. Renews monthly until you cancel.")
        #expect(content.showsTerms)
        #expect(content.buttons == [.upgradeNow, .restorePurchases, .viewSettings, .manageSubscription, .changeZip])
    }

    /// Unknown never claims there is no subscription and never offers to buy.
    @Test(arguments: [OfferStatus.loading, .unavailable, .available(StoreOffer(displayPrice: "$2.99"))])
    func theUnknownPopup(_ offer: OfferStatus) {
        let content = UpgradePopupContent.make(kind: .unknown, offer: offer)
        #expect(content.headline == "We couldn't check your subscription. Check your connection and try again.")
        #expect(!content.showsDescription)
        #expect(content.priceLine == nil)
        #expect(!content.buttons.contains(.upgradeNow))
        #expect(content.buttons == [.tryAgain, .restorePurchases, .changeZip])
    }

    /// No product, no price: never a hard-coded one, and no UPGRADE NOW.
    @Test(arguments: [SettingsGate.PopupKind.free, .lapsed])
    func aProductThatWillNotLoadShowsNoPrice(_ kind: SettingsGate.PopupKind) {
        let content = UpgradePopupContent.make(kind: kind, offer: .unavailable)
        #expect(content.priceLine == nil)
        #expect(content.storeUnreachable)
        #expect(!content.buttons.contains(.upgradeNow))
        #expect(content.buttons.first == .tryAgain)
        #expect(content.buttons.contains(.restorePurchases))
        let loading = UpgradePopupContent.make(kind: kind, offer: .loading)
        #expect(loading.priceLine == nil)
        #expect(!loading.storeUnreachable)
        #expect(!loading.buttons.contains(.upgradeNow))
    }

    @Test func theStoreUnreachableLine() {
        #expect(UpgradeWords.storeUnreachable == "The App Store can't be reached right now. Try again in a moment.")
        #expect(UpgradeWords.termsURL.absoluteString == "https://artisan.technology/seasign-terms")
    }

    @Test func tryAgainReloadsTheProduct() async {
        let storefront = ScriptedStorefront()
        storefront.offer = nil
        let (gate, _, _) = await gate(.free, storefront: storefront)
        await gate.loadOffer()
        #expect(gate.offer == .unavailable)
        storefront.offer = StoreOffer(displayPrice: "$2.99")
        await gate.tryAgain()
        #expect(gate.offer == .available(StoreOffer(displayPrice: "$2.99")))
        #expect(gate.content.buttons.first == .upgradeNow)
    }

    // MARK: Purchase

    @Test(arguments: [SubscriptionState.free, .lapsed])
    func aPurchaseUnlocksSettings(_ state: SubscriptionState) async {
        let (gate, store, storefront) = await gate(state)
        storefront.afterPurchase = { store.reading = FixedSubscriptionStore.reading(for: .subscribed) }
        await gate.loadOffer()
        await gate.upgrade { _ in throw CancellationError() }
        #expect(storefront.purchases == 1)
        #expect(gate.decision == .settings)
        #expect(gate.note == nil)
        #expect(gate.busy == nil)
    }

    /// StoreKit may report the new subscription a moment late (iOS 18.3):
    /// the gate reads again until it does.
    @Test func aPurchaseReportedLateStillUnlocks() async {
        let (gate, store, _) = await gate(.free)
        await gate.loadOffer()
        // The first two reads after the purchase still say Free.
        let base = store.reads
        let late = Task { @MainActor in
            // Bounded: a gate that stops reading must fail, not hang.
            let deadline = ContinuousClock.now + .seconds(2)
            while store.reads < base + 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        }
        await gate.upgrade { _ in throw CancellationError() }
        await late.value
        #expect(gate.decision == .settings)
        #expect(gate.note == nil)
    }

    @Test func aPurchaseTheStoreNeverConfirmsSaysSo() async {
        let (gate, store, _) = await gate(.free)
        await gate.loadOffer()
        let before = store.reads
        await gate.upgrade { _ in throw CancellationError() }
        #expect(store.reads == before + 3)
        #expect(gate.decision == .popup(.free))
        #expect(gate.note == .purchaseNotConfirmed)
    }

    @Test(arguments: [
        (PurchaseOutcome.cancelled, UpgradeNote?.none),
        (.pending, .purchasePending),
        (.failed(nothingCharged: true), .purchaseFailed(nothingCharged: true)),
        (.failed(nothingCharged: false), .purchaseFailed(nothingCharged: false)),
        (.unverified, .purchaseUnverified),
    ])
    func aPurchaseThatDidNotGoThroughChangesNothing(_ outcome: PurchaseOutcome, _ note: UpgradeNote?) async {
        let storefront = ScriptedStorefront()
        storefront.purchaseOutcome = outcome
        let (gate, store, _) = await gate(.free, storefront: storefront)
        await gate.loadOffer()
        await gate.upgrade { _ in throw CancellationError() }
        #expect(gate.state == .free)
        #expect(gate.decision == .popup(.free))
        #expect(gate.note == note)
        #expect(store.reading == FixedSubscriptionStore.reading(for: .free))
    }

    @Test func thePurchaseWordsAreHonest() {
        #expect(UpgradeNote.purchasePending.text == "Your purchase is waiting for approval.")
        #expect(UpgradeNote.purchaseFailed(nothingCharged: true).text == "The purchase didn't go through. Nothing was charged.")
        // Only said where it is certain.
        #expect(!UpgradeNote.purchaseFailed(nothingCharged: false).text.contains("charged"))
        #expect(!UpgradeNote.purchaseUnverified.text.contains("Nothing was charged"))
    }

    @Test func noPurchaseWithoutALoadedProduct() async {
        let storefront = ScriptedStorefront()
        storefront.offer = nil
        let (gate, _, _) = await gate(.free, storefront: storefront)
        await gate.loadOffer()
        await gate.upgrade { _ in throw CancellationError() }
        #expect(storefront.purchases == 0)
    }

    /// The thrown-error mapping of the live storefront.
    @Test func thrownPurchaseErrors() {
        #expect(StoreKitStorefront.outcome(of: StoreKitError.userCancelled) == .cancelled)
        #expect(StoreKitStorefront.outcome(of: Product.PurchaseError.purchaseNotAllowed) == .failed(nothingCharged: true))
        #expect(StoreKitStorefront.outcome(of: StoreKitError.networkError(URLError(.notConnectedToInternet))) == .failed(nothingCharged: false))
        #expect(StoreKitStorefront.outcome(of: URLError(.timedOut)) == .failed(nothingCharged: false))
    }

    // MARK: Restore

    @Test func aRestoreThatFindsTheSubscriptionOpensSettings() async {
        let (gate, store, storefront) = await gate(.lapsed)
        storefront.afterRestore = { store.reading = FixedSubscriptionStore.reading(for: .subscribed) }
        await gate.restore()
        #expect(storefront.restores == 1)
        #expect(gate.decision == .settings)
        #expect(gate.note == nil)
    }

    @Test(arguments: [SubscriptionState.free, .lapsed])
    func aRestoreThatFindsNothingSaysSo(_ state: SubscriptionState) async {
        let (gate, _, _) = await gate(state)
        await gate.restore()
        #expect(gate.decision == .popup(state == .free ? .free : .lapsed))
        #expect(gate.note == .restoreFoundNothing)
        #expect(gate.note?.text == "No active subscription was found for this Apple Account.")
    }

    /// A failed or cancelled sync, or a state that can't be read afterwards,
    /// never says there is no subscription.
    @Test func aRestoreThatCouldNotCheckSaysSo() async {
        let storefront = ScriptedStorefront()
        storefront.restoreOutcome = .failed
        let (gate, _, _) = await gate(.free, storefront: storefront)
        await gate.restore()
        #expect(gate.note == .restoreFailed)

        let (unknown, _, _) = await self.gate(.unknown)
        await unknown.restore()
        #expect(unknown.note == .restoreFailed)
        #expect(!UpgradeNote.restoreFailed.text.contains("No active subscription"))
    }

    // MARK: Read-only Settings

    /// The read-only rule as a table: what stays usable without a
    /// subscription, and that everything works when Subscribed.
    @Test func theReadOnlyRule() {
        let usable: Set<SettingsAction> = [
            .changeZip, .changeHUDColour, .disconnectGoogle, .removeCalendarLink,
            .removeSite, .refreshHeadlines, .restorePurchases, .manageSubscription,
        ]
        let locked: Set<SettingsAction> = [
            .connectGoogle, .chooseGoogleCalendars, .chooseNewEventsCalendar,
            .addCalendarLink, .followSite, .aiSearch, .chooseVoice,
        ]
        #expect(usable.union(locked) == Set(SettingsAction.allCases))
        #expect(usable.isDisjoint(with: locked))
        for state in SubscriptionState.allCases {
            let access = SettingsAccess(state: state)
            for action in SettingsAction.allCases {
                let expected = state == .subscribed || usable.contains(action)
                #expect(access.allows(action) == expected, "\(state) \(action)")
            }
        }
    }

    /// Settings opened while Subscribed turns read-only when a later read
    /// says Lapsed, and editable again on renewal.
    @Test func settingsAccessFollowsTheState() async {
        let (gate, store, _) = await gate(.subscribed)
        #expect(gate.settingsAccess == .full)
        store.reading = FixedSubscriptionStore.reading(for: .lapsed)
        await gate.refreshSubscription()
        #expect(gate.settingsAccess == .readOnly)
        #expect(gate.settingsAccess.allows(.removeSite))
        #expect(!gate.settingsAccess.allows(.followSite))
        #expect(UpgradeWords.readOnlyNote(gate.state).hasPrefix("Your subscription isn't active"))
        store.reading = FixedSubscriptionStore.reading(for: .subscribed)
        await gate.refreshSubscription()
        #expect(gate.settingsAccess == .full)
    }

    // MARK: The zip code, free

    @Test(arguments: [SettingsGate.PopupKind?.none, .free, .lapsed, .unknown])
    func everyPopupOffersTheZipCode(_ kind: SettingsGate.PopupKind?) {
        for offer in [OfferStatus.loading, .unavailable, .available(StoreOffer(displayPrice: "$2.99"))] {
            #expect(UpgradePopupContent.make(kind: kind, offer: offer).buttons.last == .changeZip)
        }
    }

    /// A Free person changes the zip from the popup's sheet: the same
    /// editor and save path as Settings, with no subscription asked.
    @Test func theZipChangesWhileFree() async throws {
        let (gate, _, _) = await gate(.free)
        #expect(gate.settingsAccess.allows(.changeZip))
        let today = TodayModel(api: stubbedSkyAPI(), context: try inMemoryContext())
        let editor = ZipEditor(model: today)
        editor.type("1a0-0019")
        #expect(editor.text == "10001")
        #expect(editor.canSave)
        #expect(await editor.save())
        #expect(today.zip == "10001")
        #expect(gate.state == .free)

        editor.type("99999")
        #expect(!(await editor.save()))
        #expect(editor.problem == .unknown)
        #expect(today.zip == "10001")
    }

    // MARK: DEBUG

    #if DEBUG
    /// A debug state changes the gate only: AI search keeps the real model
    /// (`SubscriptionWiringTests`), and the purchase and restore go to the
    /// debug storefront, never StoreKit's.
    @Test func aDebugPurchaseSucceedsWithoutTheStore() async {
        let (gate, store, storefront) = await gate(.unknown)
        gate.setDebugState(.free)
        await gate.loadOffer()
        #expect(gate.decision == .popup(.free))
        #expect(gate.offer == .available(StoreOffer(displayPrice: DebugStorefront.samplePrice)))
        await gate.upgrade { _ in throw CancellationError() }
        #expect(gate.decision == .settings)
        #expect(gate.debugState == .subscribed)
        #expect(gate.debugStorefrontForTests.purchases == 1)
        #expect(storefront.purchases == 0)
        // The real subscription is untouched.
        #expect(gate.subscription.access.state == .unknown)
        #expect(store.reading == .failed)

        await gate.restore()
        #expect(storefront.restores == 0)
        #expect(gate.debugStorefrontForTests.restores == 1)
    }

    @Test func aDebugStateWithNoProductShowsTheUnreachableLine() async {
        let (gate, _, storefront) = await gate(.unknown)
        gate.setDebugState(.free, offerAvailable: false)
        await gate.loadOffer()
        #expect(gate.offer == .unavailable)
        #expect(gate.content.storeUnreachable)
        #expect(storefront.loads == 0)
    }

    @Test func liveGoesBackToTheRealState() async {
        let (gate, _, _) = await gate(.lapsed)
        gate.setDebugState(.subscribed)
        #expect(gate.decision == .settings)
        gate.setDebugState(nil)
        #expect(gate.decision == .popup(.lapsed))
    }

    /// The persisted key, in a suite of its own (never the user's defaults).
    @Test func theDebugStateIsKeptUnderOneKey() throws {
        let suite = "SettingsGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SubscriptionDebug.persist(.subscribed, in: defaults)
        #expect(SubscriptionRules.debugNamed(defaults.string(forKey: SubscriptionDebug.key)) == .subscribed)
        SubscriptionDebug.persist(nil, in: defaults)
        #expect(defaults.string(forKey: SubscriptionDebug.key) == nil)
        #expect(SubscriptionDebug.key == "debugSubscription")
    }
    #endif
}
