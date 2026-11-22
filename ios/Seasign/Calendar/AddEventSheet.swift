import SwiftUI

/// The + entry and the confirm popup (task 171), one sheet over the day
/// screen whose content follows `AddEventModel.stage`: the one-line field,
/// then the draft with Confirm and Cancel, what is missing from the line,
/// what Google needs first, or why the event was not added. Charcoal and
/// Jost caps, with the Settings field style.
struct AddEventSheet: View {
    @Bindable var model: AddEventModel
    /// After a mic entry (task 172): the popup says while it is read aloud
    /// and while it listens for the answer; any tap on it stops both; a
    /// problem offers Speak again.
    var voice: VoiceEntryModel?
    /// Closes the sheet and opens Settings (Connect, Connect again, New events go to).
    var openSettings: () -> Void

    @Environment(\.clockStyle) private var clockStyle
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
                if let status = voiceStatus {
                    Text(caps: status)
                        .capsRelative(9.5, medium: true, tracking: 0.15)
                        .foregroundStyle(Palette.dayWater)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Any tap on the popup stops the reading and closes the answer
            // window: on a button, in its action before anything else
            // (`primary`, `textButton`); anywhere else, through this
            // background, which never competes with the buttons.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { voice?.popupTouched() }
            )
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.charcoal.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.charcoal)
        // A confirmed event is being sent: the sheet stays until Google answers.
        .interactiveDismissDisabled(model.isSending)
    }

    /// What the voice is doing with the popup, when anything.
    private var voiceStatus: String? {
        switch voice?.phase {
        case .speaking: "Reading it aloud"
        case .awaitingAnswer: "Listening for “confirm” or “cancel”"
        default: nil
        }
    }

    private var title: String {
        switch model.stage {
        case .entering, .closed: "New event"
        case .problem: "Not understood"
        case .failed(_, let note): note.header
        default: "Add this event?"
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(caps: title)
                .capsRelative(13, medium: true)
                .foregroundStyle(Palette.white)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !model.isSending {
                textButton("Cancel") { model.cancel() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .closed:
            EmptyView()
        case .entering:
            entry
        case .reviewing(let draft):
            summary(draft)
            if let past = DraftSummary(draft, now: Date(), clock: clockStyle).pastNote {
                note(past, problem: false)
            }
            buttons {
                primary("Confirm") { model.confirm() }
                textButton("Change") { model.tryAgain() }
            }
        case .problem(let problem):
            note(problem.message, problem: true)
            buttons {
                if let voice, voice.popupFromVoice {
                    primary("Speak again") { voice.speakAgain() }
                    textButton("Type it") { model.tryAgain() }
                } else {
                    primary("Try again") { model.tryAgain() }
                }
            }
        case .blocked(let draft, let block):
            summary(draft)
            note(block.message, problem: true)
            buttons {
                primary("Open Settings") { openSettings() }
            }
        case .sending(let draft):
            summary(draft)
            buttons {
                primary("Adding…", enabled: false) {}
            }
        case .failed(let draft, let failure):
            summary(draft)
            note(failure.text, problem: true)
            buttons {
                if failure.canRetry {
                    // Re-read each second, so a 429's wait ends on screen.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        primary("Try again", enabled: failure.retryAt.map { timeline.date >= $0 } ?? true) { model.confirm() }
                    }
                } else if failure.opensSettings {
                    primary("Open Settings") { openSettings() }
                } else {
                    primary("Change it") { model.tryAgain() }
                }
            }
        }
    }

    // MARK: The field

    private var entry: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(caps: "What and when")
                    .capsRelative(9.5, tracking: 0.15)
                    .foregroundStyle(Palette.dimText)
                    .accessibilityHidden(true)
                TextField("", text: $model.line, prompt: Text("Lunch with Ann tomorrow at noon").foregroundStyle(Palette.rule))
                    .font(.capsRelative(13))
                    .foregroundStyle(Palette.white)
                    .tint(Palette.dayWater)
                    .frame(minHeight: 44)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .onSubmit { model.submit() }
                    .accessibilityLabel("What and when")
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
            }
            note("Write it as you would say it, like “Meeting with Rahaf Sunday at 3pm”. Nothing is added until you confirm.", problem: false)
            buttons {
                primary("Continue", enabled: !model.line.trimmingCharacters(in: .whitespaces).isEmpty) { model.submit() }
            }
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: The draft

    private func summary(_ draft: EventDraft) -> some View {
        let lines = DraftSummary(draft, now: Date(), clock: clockStyle)
        return VStack(alignment: .leading, spacing: 12) {
            // Verbatim: the title is the user's own words.
            Text(caps: lines.title)
                .capsRelative(15, medium: true, tracking: 0.12)
                .lineSpacing(4)
                .foregroundStyle(Palette.white)
                .fixedSize(horizontal: false, vertical: true)
            row("Day", lines.day)
            row("Time", lines.time)
            if let length = lines.length {
                row("Length", length)
            }
            if let calendar = model.calendarName {
                row("Calendar", calendar)
            }
            // A start at 00:00: which night it is.
            if let midnight = lines.midnightNote {
                note(midnight, problem: false)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(caps: label)
                .capsRelative(9.5, tracking: 0.15)
                .foregroundStyle(Palette.dimText)
                .frame(width: 78, alignment: .leading)
            Text(caps: value)
                .capsRelative(11.5, tracking: 0.12)
                .foregroundStyle(Palette.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func note(_ text: String, problem: Bool) -> some View {
        Text(caps: text)
            .capsRelative(10, tracking: 0.12)
            .lineSpacing(4)
            .foregroundStyle(problem ? Palette.sun : Palette.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 18) {
            content()
        }
        .padding(.top, 6)
    }

    private func primary(_ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            voice?.popupTouched()
            action()
        } label: {
            Text(caps: label)
                .capsRelative(11, medium: true)
                .foregroundStyle(enabled ? Palette.charcoal : Palette.dimText)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(enabled ? Palette.white : Palette.rule.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func textButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            voice?.popupTouched()
            action()
        } label: {
            Text(caps: label)
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
