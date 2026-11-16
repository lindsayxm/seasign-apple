import SwiftUI

/// Settings: the zip code the Today scene follows, the calendar links
/// (`CalendarSettingsSection`) and the followed sites (`SitesSettingsSection`);
/// a later task adds AI search.
struct SettingsView: View {
    @Environment(TodayModel.self) private var model

    @State private var zipText = ""
    @State private var isSaving = false
    @State private var problem: TodayModel.ZipProblem?
    @FocusState private var zipFocused: Bool

    var body: some View {
        SheetScaffold(title: "Settings") {
            zipSection
            CalendarSettingsSection()
            SitesSettingsSection()
            AISettingsSection()
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
            Text(caps: "Zip code")
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)

            HStack(alignment: .center, spacing: 16) {
                TextField("", text: $zipText, prompt: Text("00000").foregroundStyle(Palette.rule))
                    .font(.custom(FontName.dayName, size: 44, relativeTo: .largeTitle))
                    .foregroundStyle(Palette.white)
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
                        .capsRelative(11, medium: true)
                        .foregroundStyle(canSave ? Palette.charcoal : Palette.dimText)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(canSave ? Palette.white : Palette.rule.opacity(0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }

            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)

            if let problem {
                Text(caps: problem.message)
                    .capsRelative(10.5, tracking: 0.12)
                    .foregroundStyle(Palette.sun)
                    .accessibilityLabel(problem.message)
            } else if let place = model.placeDescription {
                Text(caps: place)
                    .capsRelative(10.5, medium: true)
                    .foregroundStyle(Palette.white)
            }

            Text(caps: "Today follows the sun, moon and weather over this zip code. Seasign never asks for your location.")
                .capsRelative(10, tracking: 0.12)
                .lineSpacing(4)
                .foregroundStyle(Palette.dimText)

            if model.zip != nil {
                Button {
                    model.clearZip()
                    zipText = ""
                    problem = nil
                } label: {
                    Text(caps: "Remove zip code")
                        .capsRelative(10)
                        .foregroundStyle(Palette.dimText)
                        .underline()
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            Text(caps: "Debug scene")
                .capsRelative(11)
                .foregroundStyle(Palette.sun)
                .padding(.top, 24)

            picker("Time", selection: $time, options: SceneDebugOverride.Time.allCases.map { ($0.rawValue, $0.rawValue) })
            picker("Moon", selection: $moon, options: Self.moons.map { ($0.label, $0.value) })
            picker("Weather", selection: $weather, options: SceneDebugOverride.Weather.allCases.map { ($0.rawValue, $0.rawValue) })

            Text(caps: "Debug builds only. Live uses the real clock and the zip's weather.")
                .capsRelative(9.5, tracking: 0.12)
                .foregroundStyle(Palette.dimText)
        }
    }

    private func picker(_ title: String, selection: Binding<String>, options: [(label: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caps: title)
                .capsRelative(10)
                .foregroundStyle(Palette.dimText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([(label: "Live", value: "")] + options, id: \.value) { option in
                        let selected = selection.wrappedValue == option.value
                        Button {
                            selection.wrappedValue = option.value
                        } label: {
                            Text(caps: option.label)
                                .capsRelative(10, medium: selected, tracking: 0.12)
                                .foregroundStyle(selected ? Palette.charcoal : Palette.white)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(selected ? Palette.white : Palette.rule.opacity(0.35), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title) \(option.label)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }
}
#endif
