import StoreKit
import SwiftUI

/// What every way into Settings opens (task 217): the settings button and
/// the zip prompt on Today, the headlines' "Follow sites", the day screen's
/// Open Settings and `-debugOpenSettings`. The gate decides when it opens:
/// Subscribed shows Settings; Free, Lapsed and Unknown show the upgrade
/// popup. A purchase or restore that makes the state Subscribed switches the
/// popup to Settings in place. Settings is read-only whenever the state is
/// not Subscribed (`UpgradeModel.settingsAccess`), so a state that changes
/// while it is open locks editing without closing it.
struct SettingsCover: View {
    @Environment(UpgradeModel.self) private var gate
    @State private var route: Route?

    enum Route: Equatable {
        case popup, settings
    }

    var body: some View {
        Group {
            switch route ?? initialRoute {
            case .settings:
                SettingsView()
                    .environment(\.settingsAccess, gate.settingsAccess)
            case .popup:
                UpgradePopupView(openSettings: { route = .settings })
            }
        }
        .onAppear {
            if route == nil { route = initialRoute }
        }
        .onChange(of: gate.decision) { _, decision in
            if decision == .settings { route = .settings }
        }
    }

    private var initialRoute: Route {
        gate.decision == .settings ? .settings : .popup
    }
}

/// The upgrade popup (task 217), in the HUD's look. Its content comes from
/// `UpgradePopupContent`; every string is in `UpgradeWords`.
struct UpgradePopupView: View {
    /// VIEW SETTINGS (Lapsed): Settings, read-only.
    var openSettings: () -> Void

    @Environment(UpgradeModel.self) private var gate
    @Environment(\.purchase) private var purchase
    @Environment(\.openURL) private var openURL
    @State private var changingZip = false
    @State private var managing = false

    var body: some View {
        let content = gate.content
        SheetScaffold(title: UpgradeWords.popupTitle) {
            Text(verbatim: content.headline)
                .hudText(.itemTitle)
                .foregroundStyle(Palette.white)
                .fixedSize(horizontal: false, vertical: true)

            if content.showsDescription {
                HUDNote(text: UpgradeWords.description)
            }
            if let price = content.priceLine {
                Text(verbatim: price)
                    .hudText(.note)
                    .foregroundStyle(Palette.white)
                    .fixedSize(horizontal: false, vertical: true)
            } else if content.storeUnreachable {
                HUDNote(text: UpgradeWords.storeUnreachable, warning: true)
            } else if content.showsDescription {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(UpgradeWords.checking)
            }
            if content.showsTerms {
                Button {
                    openURL(UpgradeWords.termsURL)
                } label: {
                    Text(caps: UpgradeWords.terms)
                }
                .buttonStyle(.hudLink)
                .accessibilityAddTraits(.isLink)
            }
            if let note = gate.note {
                HUDNote(text: note.text, warning: note.isProblem)
            }

            HUDRule()

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(content.buttons.enumerated()), id: \.offset) { _, button in
                    view(for: button)
                }
            }

            #if DEBUG
            DebugSubscriptionSection()
            #endif
        }
        .task { await gate.opened() }
        .sheet(isPresented: $changingZip) {
            ZipCodeSheet()
        }
        .manageSubscriptionsSheet(isPresented: $managing)
    }

    @ViewBuilder
    private func view(for button: PopupButton) -> some View {
        let busy = gate.busy
        switch button {
        case .upgradeNow:
            Button {
                Task { await gate.upgrade { product in try await purchase(product) } }
            } label: {
                Text(caps: busy == .purchasing ? UpgradeWords.purchasing : UpgradeWords.upgradeNow)
            }
            .buttonStyle(.hudFilled)
            .disabled(busy != nil)
            .padding(.bottom, 8)
        case .tryAgain:
            Button {
                Task { await gate.tryAgain() }
            } label: {
                Text(caps: busy == .checking ? UpgradeWords.checking : UpgradeWords.tryAgain)
            }
            .buttonStyle(.hudFilled)
            .disabled(busy != nil)
            .padding(.bottom, 8)
        case .restorePurchases:
            link(busy == .restoring ? UpgradeWords.restoring : UpgradeWords.restorePurchases) {
                Task { await gate.restore() }
            }
            .disabled(busy != nil)
        case .viewSettings:
            link(UpgradeWords.viewSettings) { openSettings() }
        case .manageSubscription:
            link(UpgradeWords.manageSubscription) { managing = true }
        case .changeZip:
            link(UpgradeWords.changeZip) { changingZip = true }
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: title)
        }
        .buttonStyle(.hudLink)
    }
}

/// The zip code alone, from the popup: free, no subscription needed. The
/// same section and save path as Settings (`ZipCodeSection`).
struct ZipCodeSheet: View {
    var body: some View {
        SheetScaffold(title: UpgradeWords.zipTitle) {
            ZipCodeSection(showsHeader: false)
        }
        // The zip is free, whatever the gate says.
        .environment(\.settingsAccess, .full)
        .presentationDetents([.medium, .large])
    }
}

/// The subscription's own part of Settings: Manage subscription (Apple's
/// page) and Restore Purchases. Both stay usable when read-only.
struct SubscriptionSettingsSection: View {
    @Environment(UpgradeModel.self) private var gate
    @State private var managing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDSectionHeader(title: UpgradeWords.settingsSection)
            Button {
                managing = true
            } label: {
                Text(caps: UpgradeWords.manageSubscription)
            }
            .buttonStyle(.hudLink)
            .settingsAction(.manageSubscription)
            Button {
                Task { await gate.restore() }
            } label: {
                Text(caps: gate.busy == .restoring ? UpgradeWords.restoring : UpgradeWords.restorePurchases)
            }
            .buttonStyle(.hudLink)
            .disabled(gate.busy != nil)
            .settingsAction(.restorePurchases)
            if let note = gate.note {
                HUDNote(text: note.text, warning: note.isProblem)
            }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
    }
}

#if DEBUG
/// Debug-only: the subscription state the gate uses, kept across launches
/// (`SubscriptionDebug.key`, which `-debugSubscription` also sets). Live
/// reads the App Store. It changes the gate and Settings only, never AI
/// search on the user's store (see `SeasignApp.subscriptionWiring`).
struct DebugSubscriptionSection: View {
    @Environment(UpgradeModel.self) private var gate

    private static let options: [(label: String, state: SubscriptionState?)] =
        [("Live", nil)] + SubscriptionState.allCases.map { ($0.rawValue, $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDSectionHeader(title: "Debug subscription")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.options, id: \.label) { option in
                        let selected = gate.debugState == option.state
                        Button {
                            SubscriptionDebug.persist(option.state)
                            gate.setDebugState(option.state)
                        } label: {
                            Text(caps: option.label)
                        }
                        .buttonStyle(.hudChip(selected: selected))
                        .accessibilityLabel("Debug subscription \(option.label)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            HUDNote(text: "Debug builds only, kept across launches. Live reads the App Store. Any other choice sets the gate and Settings only, never AI search.")
        }
        // Usable on read-only Settings too.
        .environment(\.settingsAccess, .full)
    }
}
#endif
