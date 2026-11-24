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
            HUDSectionHeader(title: "AI search")

            PillToggle(
                label: "AI search",
                left: "Use My List",
                right: "Let AI Search",
                // Use My List while not subscribed, whatever is stored.
                isRight: model.shownMode == .aiSearch
            ) { right in
                // Interests typed with the keyboard still up count.
                commitInterests()
                model.setMode(right ? .aiSearch : .myList)
            }

            if let reason = model.precondition.message {
                note(reason, warning: model.shownMode == .myList)
            }
            note("With Let AI Search enabled, articles are added to your feed based on your interests. This helps find information on new or emerging topics not yet on your radar. This feature requires an API key.")

            providerPicker
            keySection
            interestsField
            capControls
            searchNowRow

            if let problem = model.problem {
                HUDNote(text: problem.message, warning: true)
            } else if let last = model.lastSearch {
                note(last.found == 1 ? "The last search found 1 article." : "The last search found \(last.found) articles.")
            }

            note("Each search uses your own provider account and may cost a few cents, even when it fails or times out. Your key stays in this phone's Keychain; it is sent with each search to Seasign's server, which passes it to the provider and never stores it.")
        }
        .onAppear {
            interestsDraft = model.interestsText
            // A Keychain that could not be read before may be readable now.
            model.refreshKeyStatus()
        }
        .onDisappear {
            commitInterests()
            keyText = ""
        }
        .onChange(of: focus) { previous, _ in
            if previous == .interests { commitInterests() }
        }
        .onChange(of: interestsDraft) { _, draft in
            // Kept as typed while there is at least one interest, so the pill
            // and Search now see it at once. An empty field (cleared to
            // retype) is committed only when editing ends, so AI search is
            // not switched off halfway through.
            if !InterestList.parse(draft).interests.isEmpty { commitInterests() }
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
                        }
                        .buttonStyle(.hudChip(selected: selected))
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
            if model.keyStatus == .unknown && !isReplacingKey {
                // The Keychain cannot be read right now: the key is probably
                // there, so this does not ask for it. Replace stays possible.
                HStack(alignment: .center, spacing: 16) {
                    HUDWarning(text: "Key can't be read now", role: .rowName)
                    Spacer(minLength: 8)
                    textButton("Try again") {
                        model.refreshKeyStatus()
                    }
                    .accessibilityLabel("Read the API key again")
                    textButton("Replace") {
                        keyProblem = nil
                        isReplacingKey = true
                        focus = .key
                    }
                    .accessibilityLabel("Replace API key")
                }
                .frame(minHeight: 44)
            } else if model.hasKey && !isReplacingKey {
                HStack(alignment: .center, spacing: 16) {
                    Text(caps: "Key saved")
                        .hudText(.rowName)
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
                    .hudField()
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
                    }
                    .buttonStyle(.hudFilled)
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
                HUDNote(text: keyProblem.message, warning: true)
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
                prompt: Text(verbatim: "New Tech, Scientific Breakthroughs").foregroundStyle(Palette.rule),
                axis: .vertical
            )
            .hudField()
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
                    .hudText(.rowName)
                    .foregroundStyle(Palette.white)
            }
            .accessibilityLabel("Maximum searches per day")
            .accessibilityValue("\(model.dailyCap)")
            HUDNote(text: model.usageLine, warning: model.capReached)
        }
    }

    private var searchNowRow: some View {
        Button {
            commitInterests()
            Task { await model.searchNow() }
        } label: {
            Text(caps: model.isSearching ? "Searching" : "Search now")
        }
        .buttonStyle(.hudLink)
        .disabled(!model.canSearchNow)
        .accessibilityHint("Runs one AI search now. It counts toward today's searches.")
    }

    // MARK: Parts

    private func label(_ text: String) -> some View {
        Text(caps: text)
            .hudText(.label)
            .foregroundStyle(Palette.dimText)
            .accessibilityHidden(true)
    }

    private var rule: some View {
        HUDRule(accent: true)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        HUDNote(text: text, warning: warning)
    }

    private func textButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: text)
        }
        .buttonStyle(.hudLink(minWidth: 44, alignment: .center))
    }
}
