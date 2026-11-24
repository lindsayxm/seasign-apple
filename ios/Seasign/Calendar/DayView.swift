import SwiftUI

/// The day screen (task 170), opened by tapping the events box on Today:
/// every event of today from Google and the pasted links, ended ones
/// included and dimmed, as a timeline of the whole day that fits the screen
/// (`DayTimelineView`, task 181): all-day events in a strip, each other
/// event a box from its start to its end. The date as the header with the
/// mic, the + and the close mark on the same line, so nothing covers the
/// day; the mic and + add events (tasks 171 and 172). The + is shown only
/// with an `AddEventModel`, whose one-line field and confirm popup open in
/// a sheet, the mic only with a `VoiceEntryModel`, which listens here (the
/// words heard show under the date, and the day shrinks to fit under
/// them), then opens the same popup and reads it aloud. After an add,
/// "Added · Sun 3:00 PM · Meeting with Rahaf" shows for a few seconds and
/// an event for today joins the day at once.
///
/// Design v12 (task 196): the HUD's dark plate and mono type; the date in a
/// white tile like Today's; the mic and + in the accent, each in the frame
/// of Today's settings button (filled while listening); the notes in the
/// HUD's text roles, which follow Dynamic Type.
///
/// It reads through its own `DayModel`, which refreshes while the screen is
/// open and the app is active (Today's Google poll stops under any cover).
struct DayView: View {
    @State private var model: DayModel
    /// Adds an event by typing; the + is hidden while nil.
    @State private var adder: AddEventModel?
    /// Adds an event by voice; the mic is hidden while nil.
    @State private var voice: VoiceEntryModel?
    /// Settings opens once the popup has closed (Connect, Connect again,
    /// New events go to).
    @State private var settingsAfterSheet = false
    @State private var showsSettings = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.clockStyle) private var clockStyle
    @Environment(\.hudAccent) private var accent

    init(model: DayModel, adder: AddEventModel? = nil, voice: VoiceEntryModel? = nil) {
        _model = State(initialValue: model)
        _adder = State(initialValue: adder)
        _voice = State(initialValue: adder == nil ? nil : voice)
        // Kept by the first init only (`State`), as are the two models.
        adder?.onAdded = { [weak model] event in
            guard let model else { return }
            model.showAdded(event)
            Task { await model.refreshGoogle(force: true) }
        }
    }

    var body: some View {
        // Re-read the time often enough that an event dims soon after it
        // ends and the date turns over at midnight.
        TimelineView(.periodic(from: .now, by: 20)) { timeline in
            content(now: timeline.date)
        }
        .background(Palette.hudPlate.ignoresSafeArea())
        .statusBarCover(Palette.hudPlate)
        .preferredColorScheme(.dark)
        // Asks at once whenever the screen opens or the app comes back, then
        // on its own timer; stops when the screen closes or the app leaves
        // the foreground.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await model.run()
        }
        // The voice stops when the app leaves the foreground (not for the
        // permission prompts) and when the screen closes.
        .onChange(of: scenePhase) { _, phase in
            voice?.sceneChanged(active: phase == .active)
        }
        .onDisappear { voice?.interrupt() }
        .sheet(isPresented: sheetShown, onDismiss: {
            voice?.popupClosed()
            if settingsAfterSheet {
                settingsAfterSheet = false
                showsSettings = true
            }
        }) {
            if let adder {
                AddEventSheet(model: adder, voice: voice) {
                    settingsAfterSheet = true
                    adder.cancel()
                }
            }
        }
        .fullScreenCover(isPresented: $showsSettings) {
            // Through the gate on Settings (task 217).
            SettingsCover()
        }
        #if DEBUG
        .onAppear(perform: openDebugEntry)
        #endif
    }

    /// The sheet is up while the popup has something to show.
    private var sheetShown: Binding<Bool> {
        Binding(
            get: { adder?.isOpen ?? false },
            // Swiped down: as Cancel (ignored while an event is being sent).
            set: { shown in
                if !shown {
                    voice?.popupClosed()
                    adder?.cancel()
                }
            }
        )
    }

    #if DEBUG
    /// The `-debugAddEvent…` launch arguments (`AddEventModel.openDebugEntry`),
    /// only with the sample account, which sends nothing: with a real
    /// connection they are ignored here and again in the model.
    private func openDebugEntry() {
        guard let adder, adder.usesSample else { return }
        adder.openDebugEntry()
        // `-debugVoiceStart YES`: the mic, with the scripted listener
        // (`VoiceDebug`), which only the sample gets.
        if VoiceDebug.startsAtOnce, let voice { voice.micTapped() }
    }
    #endif

    private func content(now realNow: Date) -> some View {
        let now = displayedNow(realNow)
        let rows = model.rows(now: now, clock: clockStyle)
        let problem = model.problem(now: now)
        let zone = model.current(at: now).zone
        let empty = rows.isEmpty ? model.emptyLine(now: now) : nil
        let isListening = voice?.isListening == true
        let notice = isListening ? nil : voice?.notice
        let added = adder?.addedNote
        let hasNotes = isListening || notice != nil || added != nil || problem != nil || empty != nil
        return VStack(alignment: .leading, spacing: 0) {
            header(HeaderDate(now: now, timeZone: zone))
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .padding(.top, 4)
            HUDRule(accent: true)
                .padding(.horizontal, 20)
                .padding(.top, 2)
            // The notes take their own room above the day, which shrinks to
            // fit under them, so they never cover an event.
            if hasNotes {
                VStack(alignment: .leading, spacing: 10) {
                    if let voice, isListening {
                        listening(voice.heard ?? "")
                    } else if let notice {
                        voiceNotice(notice)
                    }
                    if let added {
                        addedNote(added)
                    }
                    if let problem {
                        HUDNote(text: problem.message, warning: true)
                    }
                    if let empty {
                        note(empty)
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            DayTimelineView(
                rows: rows, day: DayTimeline.bounds(of: now, in: zone), zone: zone, now: now, clock: clockStyle
            )
            .padding(.leading, 12)
            .padding(.trailing, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The time the screen is drawn for: the real one, except with the
    /// DEBUG sample and `-debugDayNow HH:MM`, which draws today as at that
    /// time (for screenshots; it changes only what is drawn).
    private func displayedNow(_ now: Date) -> Date {
        #if DEBUG
        if model.isSample, let text = UserDefaults.standard.string(forKey: "debugDayNow") {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = model.current(at: now).zone
                let start = calendar.startOfDay(for: now)
                return start.addingTimeInterval(TimeInterval(parts[0] * 3600 + parts[1] * 60))
            }
        }
        #endif
        return now
    }

    /// While the mic listens: what has been heard so far, as said.
    private func listening(_ heard: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caps: "Listening")
                .hudText(.section)
                .foregroundStyle(accent)
            if heard.isEmpty {
                Text(verbatim: "Say the event and when, like “Lunch with Ann tomorrow at noon”.")
                    .hudText(.note)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Verbatim: the user's own words.
                Text(verbatim: heard)
                    .hudText(.field)
                    .fontWeight(.medium)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: "Tap the mic again when you're done.")
                .hudText(.detail)
                .foregroundStyle(Palette.dimText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Why the mic did not listen; the + stays.
    private func voiceNotice(_ notice: VoiceNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HUDNote(text: notice.message, warning: true)
            if notice.opensSystemSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: url) {
                    Text(caps: "Open iPhone Settings")
                        .hudText(.link)
                        .foregroundStyle(accent)
                        .underline()
                        .frame(minHeight: 44)
                }
            }
        }
    }

    /// "Added · Sun 3:00 PM · Meeting with Rahaf", gone after a few seconds.
    private func addedNote(_ added: AddEventModel.AddedNote) -> some View {
        Text(verbatim: added.text)
            .hudText(.note)
            .fontWeight(.semibold)
            .lineSpacing(3)
            .foregroundStyle(Palette.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
            .task(id: added.id) {
                try? await Task.sleep(for: .seconds(AddEventModel.addedNoteSeconds))
                adder?.hideAddedNote(added.id)
            }
    }

    /// The date in a white tile (Today's date tile), then the mic, the +
    /// and the close mark on the same line, so nothing is drawn over the day.
    private func header(_ date: HeaderDate) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(caps: date.spoken)
                .hudText(.section)
                .fontWeight(.semibold)
                .foregroundStyle(Palette.onAccent)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.dateTile, in: HUDShape.rect)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            buttons
            CloseMark { dismiss() }
        }
    }

    /// Mic, then +, each a 44-point target: the icon in the accent inside
    /// the frame of Today's settings button.
    private var buttons: some View {
        HStack(spacing: 0) {
            if let voice {
                let listening = voice.isListening
                iconButton(.mic, label: listening ? "Stop listening" : "Add an event by voice", active: listening) {
                    voice.micTapped()
                }
            }
            if let adder {
                iconButton(.plus, label: "Type an event") {
                    voice?.typingStarted()
                    adder.open()
                }
            }
        }
    }

    private func iconButton(_ icon: LineIcon, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                HUDFrameShape()
                    .fill(active ? accent : Color.clear)
                HUDFrameShape()
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5 * Self.frameSide / 28, lineJoin: .miter))
                LineIconView(icon: icon, size: 12, lineWidth: 1.3)
                    .foregroundStyle(active ? Palette.onAccent : accent)
            }
            .frame(width: Self.frameSide, height: Self.frameSide)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The mic's and the +'s frame: Today's settings button's, 24 points.
    private static let frameSide: CGFloat = 24

    private func note(_ text: String) -> some View {
        HUDNote(text: text)
    }
}

/// The frame of Today's mark and settings button (`HUDGlyph.frame`, rounded
/// at the upper left and lower right), scaled to the rect.
struct HUDFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        HUDGlyph.frame.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / 28, y: rect.height / 28)
        )
    }
}
