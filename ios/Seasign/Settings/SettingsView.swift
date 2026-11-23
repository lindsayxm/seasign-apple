import SwiftUI

/// Settings: the zip code the Today scene follows, the HUD colour
/// (`HUDColourSettingsSection`), Google Calendar (`GoogleSettingsSection`), the calendar links (`CalendarSettingsSection`), the followed sites (`SitesSettingsSection`)
/// AI search (`AISettingsSection`) and the read-aloud voice (`VoiceSettingsSection`).
/// Drawn in the HUD's look (design v12): `SheetScaffold` and `HUDForm`.
struct SettingsView: View {
    @Environment(TodayModel.self) private var model

    @State private var zipText = ""
    @State private var isSaving = false
    @State private var problem: TodayModel.ZipProblem?
    @FocusState private var zipFocused: Bool

    var body: some View {
        SheetScaffold(title: "Settings") {
            zipSection
            HUDColourSettingsSection()
            GoogleSettingsSection()
            CalendarSettingsSection()
            SitesSettingsSection()
            AISettingsSection()
            VoiceSettingsSection()
            #if DEBUG
            DebugSceneSection()
            #endif
        }
        .onAppear {
            zipText = model.zip ?? ""
        }
    }

    private var zipSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDSectionHeader(title: "Zip code", topPadding: 0)

            HStack(alignment: .center, spacing: 16) {
                TextField("", text: $zipText, prompt: Text("00000").foregroundStyle(Palette.rule))
                    .hudField(.display)
                    .keyboardType(.numberPad)
                    .textContentType(.postalCode)
                    .focused($zipFocused)
                    .frame(maxWidth: 150)
                    .accessibilityLabel("Zip code")
                    .onChange(of: zipText) { _, text in
                        // Digits only, five at most.
                        let digits = String(text.filter(\.isWholeNumber).prefix(5))
                        if digits != text { zipText = digits }
                        problem = nil
                    }

                Button {
                    save()
                } label: {
                    Text(caps: isSaving ? "Checking" : "Save")
                }
                .buttonStyle(.hudFilled)
                .disabled(!canSave)
            }

            HUDRule(accent: true)

            if let problem {
                HUDNote(text: problem.message, warning: true)
                    .accessibilityLabel(problem.message)
            } else if let place = model.placeDescription {
                Text(caps: place)
                    .hudText(.rowName)
                    .foregroundStyle(Palette.white)
            }

            HUDNote(text: "Today follows the sun, moon and weather over this zip code. Seasign never asks for your location.")

            if model.zip != nil {
                Button {
                    model.clearZip()
                    zipText = ""
                    problem = nil
                } label: {
                    Text(caps: "Remove zip code")
                }
                .buttonStyle(.hudLink)
            }
        }
    }

    private var canSave: Bool {
        !isSaving && zipText.count == 5 && zipText != model.zip
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        problem = nil
        let text = zipText
        Task {
            do {
                try await model.saveZip(text)
                zipFocused = false
            } catch let zipProblem as TodayModel.ZipProblem {
                problem = zipProblem
            } catch {
                problem = .unavailable
            }
            isSaving = false
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
