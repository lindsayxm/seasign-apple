import SwiftUI

/// Settings: the zip code the Today scene follows (`ZipCodeSection`), the HUD colour
/// (`HUDColourSettingsSection`), Google Calendar (`GoogleSettingsSection`), the calendar links (`CalendarSettingsSection`), the followed sites (`SitesSettingsSection`)
/// AI search (`AISettingsSection`), the read-aloud voice (`VoiceSettingsSection`)
/// and the subscription (`SubscriptionSettingsSection`).
/// Drawn in the HUD's look (design v12): `SheetScaffold` and `HUDForm`.
///
/// Opened only through the gate (`SettingsCover`, task 217), which sets
/// `\.settingsAccess`: read-only unless Subscribed. Each control that the
/// read-only rule covers says which `SettingsAction` it is
/// (`.settingsAction(_:)`); the note at the top says why.
struct SettingsView: View {
    @Environment(UpgradeModel.self) private var gate
    @Environment(\.settingsAccess) private var access

    var body: some View {
        SheetScaffold(title: "Settings") {
            if access.isReadOnly {
                HUDNote(text: UpgradeWords.readOnlyNote(gate.state), warning: true)
            }
            ZipCodeSection()
            HUDColourSettingsSection()
                .settingsAction(.changeHUDColour)
            GoogleSettingsSection()
            CalendarSettingsSection()
            SitesSettingsSection()
            // Only disabled when read-only: further work on this section is
            // on hold by the user's decision.
            AISettingsSection()
                .settingsAction(.aiSearch)
            VoiceSettingsSection()
                .settingsAction(.chooseVoice)
            SubscriptionSettingsSection()
            #if DEBUG
            DebugSceneSection()
            DebugSubscriptionSection()
            #endif
        }
    }
}

#if DEBUG
/// Debug-only: forces the scene's time of day, moon phase and weather. The
/// values live in `UserDefaults`, which launch arguments can also set; see
/// `SceneDebugOverride`.
private struct DebugSceneSection: View {
    @AppStorage(SceneDebugOverride.timeKey) private var time = ""
    @AppStorage(SceneDebugOverride.moonKey) private var moon = ""
    @AppStorage(SceneDebugOverride.weatherKey) private var weather = ""

    private static let moons: [(label: String, value: String)] = [
        ("New", "0"), ("Waxing", "0.35"), ("Full", "0.5"), ("Waning", "0.65"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HUDSectionHeader(title: "Debug scene")

            picker("Time", selection: $time, options: SceneDebugOverride.Time.allCases.map { ($0.rawValue, $0.rawValue) })
            picker("Moon", selection: $moon, options: Self.moons.map { ($0.label, $0.value) })
            picker("Weather", selection: $weather, options: SceneDebugOverride.Weather.allCases.map { ($0.rawValue, $0.rawValue) })

            HUDNote(text: "Debug builds only. Live uses the real clock and the zip's weather.")
        }
    }

    private func picker(_ title: String, selection: Binding<String>, options: [(label: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caps: title)
                .hudText(.label)
                .foregroundStyle(Palette.dimText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([(label: "Live", value: "")] + options, id: \.value) { option in
                        let selected = selection.wrappedValue == option.value
                        Button {
                            selection.wrappedValue = option.value
                        } label: {
                            Text(caps: option.label)
                        }
                        .buttonStyle(.hudChip(selected: selected))
                        .accessibilityLabel("\(title) \(option.label)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }
}
#endif
