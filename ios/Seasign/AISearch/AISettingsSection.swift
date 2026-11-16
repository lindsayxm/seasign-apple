import SwiftUI

/// The AI search part of Settings: the Use My List / Let AI Search pill, the
/// provider, the API key (saved to the Keychain only; shown afterwards as
/// "Key saved" with no characters of it), the interests, the daily cap with
/// today's use, Search now, and what went wrong with the last search.
///
/// The key is typed into a secure field held in this view's state only until
/// it is saved, then the field is emptied, so no part of the key stays on
/// screen or in an accessibility value.
struct AISettingsSection: View {
    @Environment(AISearchModel.self) private var model

    @State private var keyText = ""
    @State private var isReplacingKey = false
    @State private var keyProblem: AISearchModel.KeyProblem?
    @State private var interestsDraft = ""
    @State private var confirmingRemoval = false
    @FocusState private var focus: Field?

    private enum Field {
        case key, interests
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(caps: "AI search")
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            PillToggle(
                label: "AI search",
                left: "Use My List",
                right: "Let AI Search",
                isRight: model.mode == .aiSearch
            ) { right in
                model.setMode(right ? .aiSearch : .myList)
            }

            if let reason = model.precondition.message {
                note(reason, warning: model.mode == .myList)
            }
            note("Let AI Search adds articles your own AI provider finds on your interests to Today and the last 7 days. Each one is marked AI. Use My List shows only the sites you follow, and no search is made.")

            providerPicker
            keySection
            interestsField
            capControls
            searchNowRow

            if let problem = model.problem {
                Text(caps: problem.message)
                    .capsRelative(10.5, tracking: 0.12)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.sun)
            } else if let last = model.lastSearch {
                note(last.found == 1 ? "The last search found 1 article." : "The last search found \(last.found) articles.")
            }

            note("Each search uses your own provider account and may cost a few cents, even when it fails or times out. Your key stays in this phone's Keychain; it is sent with each search to Seasign's server, which passes it to the provider and never stores it.")
        }
        .onAppear {
            interestsDraft = model.interestsText
        }
        .onDisappear {
            commitInterests()
            keyText = ""
        }
        .onChange(of: focus) { previous, _ in
            if previous == .interests { commitInterests() }
        }
        .confirmationDialog(
            Text(verbatim: "Remove your API key?"),
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                do {
                    try model.removeKey()
                    keyProblem = nil
                } catch {
                    keyProblem = (error as? AISearchModel.KeyProblem) ?? .notRemoved
                }
            } label: {
                Text(verbatim: "Remove key")
            }
        } message: {
            Text(verbatim: "AI search turns off and AI-found articles leave Today and the last 7 days. Saved articles stay saved.")
        }
    }

    // MARK: Provider

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Provider")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        let selected = provider == model.provider
                        Button {
                            model.setProvider(provider)
                        } label: {
                            Text(caps: provider.displayName)
                                .capsRelative(10, medium: selected, tracking: 0.12)
                                .foregroundStyle(selected ? Palette.charcoal : Palette.white)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(selected ? Palette.white : Palette.rule.opacity(0.35), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Provider " + provider.displayName)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if model.providerChangedSinceKey {
                note("Your saved key must be a key for " + model.provider.displayName + ". Replace it if it isn't.", warning: true)
            }
        }
    }

    // MARK: Key

    @ViewBuilder
    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("API key")
            if model.hasKey && !isReplacingKey {
                HStack(alignment: .center, spacing: 16) {
                    Text(caps: "Key saved")
                        .capsRelative(11.5, medium: true)
                        .foregroundStyle(Palette.white)
                    Spacer(minLength: 8)
                    textButton("Replace") {
                        keyProblem = nil
                        isReplacingKey = true
                        focus = .key
                    }
                    .accessibilityLabel("Replace API key")
                    textButton("Remove") {
                        confirmingRemoval = true
                    }
                    .accessibilityLabel("Remove API key")
                }
                .frame(minHeight: 44)
            } else {
                SecureField("", text: $keyText, prompt: Text(verbatim: "Paste your key").foregroundStyle(Palette.rule))
                    .font(.capsRelative(13))
                    .foregroundStyle(Palette.white)
                    .tint(Palette.dayWater)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .submitLabel(.done)
                    .focused($focus, equals: .key)
                    .onSubmit { saveKey() }
                    .frame(minHeight: 44)
                    .accessibilityLabel("API key for " + model.provider.displayName)
                rule
                HStack(spacing: 20) {
                    Button {
                        saveKey()
                    } label: {
                        Text(caps: "Save key")
                            .capsRelative(11, medium: true)
                            .foregroundStyle(keyText.isEmpty ? Palette.dimText : Palette.charcoal)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(keyText.isEmpty ? Palette.rule.opacity(0.4) : Palette.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(keyText.isEmpty)
                    if isReplacingKey {
                        textButton("Cancel") {
                            keyText = ""
                            keyProblem = nil
                            isReplacingKey = false
                        }
                    }
                }
            }
            if let keyProblem {
                Text(caps: keyProblem.message)
                    .capsRelative(10.5, tracking: 0.12)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.sun)
            }
        }
        .onChange(of: keyText) {
            if keyProblem == .invalidShape { keyProblem = nil }
        }
    }

    private func saveKey() {
        do {
            try model.saveKey(keyText)
            keyProblem = nil
            isReplacingKey = false
            focus = nil
        } catch {
            keyProblem = error
        }
        // Emptied whatever happened: the field never keeps the key.
        keyText = ""
    }

    // MARK: Interests

    private var interestsField: some View {
        let parsed = InterestList.parse(interestsDraft)
        return VStack(alignment: .leading, spacing: 6) {
            label("Interests, separated by commas")
            TextField(
                "",
                text: $interestsDraft,
                prompt: Text(verbatim: "tide pools, new telescopes").foregroundStyle(Palette.rule),
                axis: .vertical
            )
            .font(.capsRelative(13))
            .foregroundStyle(Palette.white)
            .tint(Palette.dayWater)
            .lineLimit(1...6)
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .focused($focus, equals: .interests)
            .onSubmit { commitInterests() }
            .frame(minHeight: 44)
            .accessibilityLabel("Interests, separated by commas")
            rule
            if let trimmed = parsed.trim.message {
                note(trimmed, warning: true)
            } else if !parsed.interests.isEmpty {
                note(parsed.interests.count == 1 ? "1 interest" : "\(parsed.interests.count) interests")
            }
        }
    }

    private func commitInterests() {
        model.setInterests(interestsDraft)
    }

    // MARK: Cap

    private var capControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(
                value: Binding(get: { model.dailyCap }, set: { model.setDailyCap($0) }),
                in: DailyCap.range
            ) {
                Text(caps: "Max searches per day: \(model.dailyCap)")
                    .capsRelative(10.5, tracking: 0.12)
                    .foregroundStyle(Palette.white)
            }
            .accessibilityLabel("Maximum searches per day")
            .accessibilityValue("\(model.dailyCap)")
            Text(caps: model.usageLine)
                .capsRelative(10, tracking: 0.12)
                .foregroundStyle(model.capReached ? Palette.sun : Palette.dimText)
        }
    }

    private var searchNowRow: some View {
        Button {
            Task { await model.searchNow() }
        } label: {
            Text(caps: model.isSearching ? "Searching" : "Search now")
                .capsRelative(10)
                .foregroundStyle(model.canSearchNow ? Palette.white : Palette.dimText)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSearchNow)
        .accessibilityHint("Runs one AI search now. It counts toward today's searches.")
    }

    // MARK: Parts

    private func label(_ text: String) -> some View {
        Text(caps: text)
            .capsRelative(9.5, tracking: 0.15)
            .foregroundStyle(Palette.dimText)
            .accessibilityHidden(true)
    }

    private var rule: some View {
        Rectangle()
            .fill(Palette.rule)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(caps: text)
            .capsRelative(10, tracking: 0.12)
            .lineSpacing(4)
            .foregroundStyle(warning ? Palette.sun : Palette.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: text)
                .capsRelative(10)
                .foregroundStyle(Palette.dimText)
                .underline()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
