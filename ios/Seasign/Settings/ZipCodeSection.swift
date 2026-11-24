import Observation
import SwiftUI

/// The zip code being typed and its save (task 217 moved it out of
/// `SettingsView`, so Settings and the popup's zip sheet share one path):
/// digits only, five at most, checked against the API by
/// `TodayModel.saveZip`. Free: no subscription is asked.
@MainActor @Observable
final class ZipEditor {
    private(set) var text = ""
    private(set) var isSaving = false
    private(set) var problem: TodayModel.ZipProblem?

    @ObservationIgnored private let model: TodayModel

    init(model: TodayModel) {
        self.model = model
        text = model.zip ?? ""
    }

    /// What was typed: digits only, five at most. A change clears the problem.
    func type(_ typed: String) {
        let digits = String(typed.filter(\.isWholeNumber).prefix(5))
        if digits != text { problem = nil }
        text = digits
    }

    var canSave: Bool {
        !isSaving && text.count == 5 && text != model.zip
    }

    /// Saves the typed zip; true when it was saved.
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        problem = nil
        defer { isSaving = false }
        do {
            try await model.saveZip(text)
            return true
        } catch let zipProblem as TodayModel.ZipProblem {
            problem = zipProblem
        } catch {
            problem = .unavailable
        }
        return false
    }

    func remove() {
        model.clearZip()
        text = ""
        problem = nil
    }
}

/// The zip code the Today scene follows: the field, Save, the place found,
/// and Remove. In Settings and in the popup's zip sheet.
struct ZipCodeSection: View {
    var showsHeader = true

    @Environment(TodayModel.self) private var model
    @State private var editor: ZipEditor?
    @FocusState private var zipFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                HUDSectionHeader(title: "Zip code", topPadding: 0)
            }
            if let editor {
                content(editor)
            }
        }
        .onAppear {
            if editor == nil { editor = ZipEditor(model: model) }
        }
        .settingsAction(.changeZip)
    }

    @ViewBuilder
    private func content(_ editor: ZipEditor) -> some View {
        HStack(alignment: .center, spacing: 16) {
            TextField("", text: Binding(get: { editor.text }, set: { editor.type($0) }), prompt: Text("00000").foregroundStyle(Palette.rule))
                .hudField(.display)
                .keyboardType(.numberPad)
                .textContentType(.postalCode)
                .focused($zipFocused)
                .frame(maxWidth: 150)
                .accessibilityLabel("Zip code")

            Button {
                Task {
                    if await editor.save() { zipFocused = false }
                }
            } label: {
                Text(caps: editor.isSaving ? "Checking" : "Save")
            }
            .buttonStyle(.hudFilled)
            .disabled(!editor.canSave)
        }

        HUDRule(accent: true)

        if let problem = editor.problem {
            HUDNote(text: problem.message, warning: true)
                .accessibilityLabel(problem.message)
        } else if let place = model.placeDescription {
            Text(caps: place)
                .hudText(.rowName)
                .foregroundStyle(Palette.white)
        }

        HUDNote(text: "Conditions follow zip code, Seasign never asks for your location.")

        if model.zip != nil {
            Button {
                editor.remove()
            } label: {
                Text(caps: "Remove zip code")
            }
            .buttonStyle(.hudLink)
        }
    }
}
