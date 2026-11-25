import Foundation
import SwiftUI

/// What tapping settings does (task 217, `plans/2026-11-24-account-and-subscription.md`,
/// "The upgrade flow"). Pure: the state in, the screen out.
///
/// Subscribed opens Settings; Free, Lapsed and Unknown show the upgrade
/// popup. Unknown never opens Settings (fail closed): a state the app cannot
/// determine is not Subscribed.
enum SettingsGate {
    /// The popup's three kinds.
    enum PopupKind: Equatable, Sendable {
        case free, lapsed, unknown
    }

    enum Decision: Equatable, Sendable {
        case settings
        case popup(PopupKind)
    }

    static func decision(for state: SubscriptionState) -> Decision {
        switch state {
        case .subscribed: .settings
        case .free: .popup(.free)
        case .lapsed: .popup(.lapsed)
        case .unknown: .popup(.unknown)
        }
    }
}

// MARK: Read-only Settings

/// Everything in Settings that can be done, for the read-only rule.
enum SettingsAction: CaseIterable, Sendable {
    case changeZip
    case changeHUDColour
    case connectGoogle
    case chooseGoogleCalendars
    case chooseNewEventsCalendar
    case disconnectGoogle
    case addCalendarLink
    case removeCalendarLink
    case followSite
    case removeSite
    case refreshHeadlines
    case aiSearch
    case chooseVoice
    case restorePurchases
    case manageSubscription
}

/// What Settings allows: everything while Subscribed; otherwise read-only,
/// where everything stays visible and only the zip code, removing, a free
/// headline refresh and the subscription's own controls work. The HUD
/// colour is locked too: only the zip code changes without a subscription
/// (the user's rule; lead, after the task 217 review). Removing costs nothing,
/// and a lapsed person must never be trapped with data they want gone.
/// Fails closed: the environment's default is read-only.
struct SettingsAccess: Equatable, Sendable {
    var isReadOnly: Bool

    static let full = SettingsAccess(isReadOnly: false)
    static let readOnly = SettingsAccess(isReadOnly: true)

    init(isReadOnly: Bool) {
        self.isReadOnly = isReadOnly
    }

    /// Read-only for anything but Subscribed (the hard rule's question).
    init(state: SubscriptionState) {
        isReadOnly = !state.allowsPaidFeatures
    }

    /// What stays usable when read-only.
    static let usableWhenReadOnly: Set<SettingsAction> = [
        .changeZip,
        .disconnectGoogle,
        .removeCalendarLink,
        .removeSite,
        .refreshHeadlines,
        .restorePurchases,
        .manageSubscription,
    ]

    func allows(_ action: SettingsAction) -> Bool {
        !isReadOnly || Self.usableWhenReadOnly.contains(action)
    }
}

extension EnvironmentValues {
    /// What Settings allows; read-only unless the gate says otherwise.
    @Entry var settingsAccess: SettingsAccess = .readOnly
}

extension View {
    /// Disables this control when Settings does not allow `action`
    /// (`\.settingsAccess`). The one way a Settings section applies the
    /// read-only rule.
    func settingsAction(_ action: SettingsAction) -> some View {
        modifier(SettingsActionGate(action: action))
    }
}

private struct SettingsActionGate: ViewModifier {
    let action: SettingsAction
    @Environment(\.settingsAccess) private var access

    func body(content: Content) -> some View {
        content.disabled(!access.allows(action))
    }
}

// MARK: The popup's content

/// A button on the upgrade popup.
enum PopupButton: Equatable, Sendable {
    case upgradeNow
    case tryAgain
    case restorePurchases
    case viewSettings
    case manageSubscription
    case changeZip
}

/// The App Store's offer for the monthly subscription, as the popup needs it.
struct StoreOffer: Equatable, Sendable {
    /// The product's own localized price ("$2.99"); never hard-coded.
    var displayPrice: String
}

/// Whether the product loaded.
enum OfferStatus: Equatable, Sendable {
    case loading
    case available(StoreOffer)
    case unavailable
}

/// What the popup shows, from its kind and the offer. Pure. `kind` nil is
/// "no read has landed yet": only the checking line and the zip code.
struct UpgradePopupContent: Equatable {
    var headline: String
    var showsDescription = false
    /// The price and renewal terms, only from a loaded product.
    var priceLine: String?
    /// The App Store could not be reached for the product.
    var storeUnreachable = false
    var showsTerms = false
    var buttons: [PopupButton]

    static func make(kind: SettingsGate.PopupKind?, offer: OfferStatus) -> UpgradePopupContent {
        guard let kind else {
            return UpgradePopupContent(headline: UpgradeWords.checkingHeadline, buttons: [.changeZip])
        }
        switch kind {
        case .unknown:
            // No claim that the person has no subscription, and no UPGRADE
            // NOW: a paying customer must not be pushed to buy twice.
            return UpgradePopupContent(headline: UpgradeWords.unknownHeadline, buttons: [.tryAgain, .restorePurchases, .changeZip])
        case .free, .lapsed:
            var content = UpgradePopupContent(
                headline: kind == .free ? UpgradeWords.freeHeadline : UpgradeWords.lapsedHeadline,
                showsDescription: true,
                showsTerms: true,
                buttons: []
            )
            switch offer {
            case .available(let offer):
                content.priceLine = UpgradeWords.priceLine(offer.displayPrice)
                content.buttons.append(.upgradeNow)
            case .unavailable:
                content.storeUnreachable = true
                content.buttons.append(.tryAgain)
            case .loading:
                break
            }
            content.buttons.append(.restorePurchases)
            if kind == .lapsed {
                content.buttons += [.viewSettings, .manageSubscription]
            }
            content.buttons.append(.changeZip)
            return content
        }
    }
}

/// A line the popup shows after an action.
enum UpgradeNote: Equatable, Sendable {
    case purchasePending
    case purchaseFailed(nothingCharged: Bool)
    case purchaseUnverified
    case purchaseNotConfirmed
    case restoreFoundNothing
    case restoreFailed

    var text: String {
        switch self {
        case .purchasePending: UpgradeWords.purchasePending
        case .purchaseFailed(true): UpgradeWords.purchaseFailedNothingCharged
        case .purchaseFailed(false): UpgradeWords.purchaseFailed
        case .purchaseUnverified: UpgradeWords.purchaseUnverified
        case .purchaseNotConfirmed: UpgradeWords.purchaseNotConfirmed
        case .restoreFoundNothing: UpgradeWords.restoreFoundNothing
        case .restoreFailed: UpgradeWords.restoreFailed
        }
    }

    /// Shown as a problem (the white "!"), or as a plain note.
    var isProblem: Bool {
        switch self {
        case .purchasePending, .purchaseNotConfirmed: false
        default: true
        }
    }
}

/// Every string the gate, the popup, the zip sheet and read-only Settings
/// show, in one place (task 217). The first line of the Free popup is the
/// user's own; the rest is the lead's draft for the user to approve.
enum UpgradeWords {
    // The popup
    static let popupTitle = "Subscription"
    static let freeHeadline = "You need an account to update settings."
    static let lapsedHeadline = "Your subscription isn't active."
    static let unknownHeadline = "We couldn't check your subscription. Check your connection and try again."
    static let checkingHeadline = "Checking your subscription…"
    static let description = "A subscription lets you choose your own sites, connect your calendars, use AI search and keep everything in sync across your devices."
    static func priceLine(_ displayPrice: String) -> String {
        "\(displayPrice) a month. Renews monthly until you cancel."
    }
    static let storeUnreachable = "The App Store can't be reached right now. Try again in a moment."
    static let terms = "Terms and privacy"
    static let termsURL = URL(string: "https://artisan.technology/seasign-terms")!

    // Buttons (shown in capitals)
    static let upgradeNow = "Upgrade now"
    static let purchasing = "Purchasing"
    static let tryAgain = "Try again"
    static let checking = "Checking"
    static let restorePurchases = "Restore purchases"
    static let restoring = "Restoring"
    static let viewSettings = "View settings"
    static let manageSubscription = "Manage subscription"
    static let changeZip = "Change zip code"

    // After a purchase or a restore
    static let purchasePending = "Your purchase is waiting for approval."
    static let purchaseFailedNothingCharged = "The purchase didn't go through. Nothing was charged."
    static let purchaseFailed = "The purchase didn't go through. Try again in a moment."
    static let purchaseUnverified = "The App Store's answer couldn't be verified, so nothing was unlocked. If you were charged, tap Restore purchases."
    static let purchaseNotConfirmed = "Your purchase went through, but the App Store hasn't confirmed it yet. Tap Restore purchases in a moment."
    static let restoreFoundNothing = "No active subscription was found for this Apple Account."
    static let restoreFailed = "Your purchases couldn't be checked. Check your connection and try again."

    // The zip code sheet
    static let zipTitle = "Zip code"

    // Settings
    static let settingsSection = "Subscription"
    static func readOnlyNote(_ state: SubscriptionState) -> String {
        switch state {
        case .lapsed:
            "Your subscription isn't active, so these settings are read-only. You can still change your zip code, remove calendars, sites and Google, and restore or manage your subscription."
        case .unknown:
            "We couldn't check your subscription, so these settings are read-only for now."
        case .free, .subscribed:
            "These settings need a subscription, so they are read-only."
        }
    }
}
