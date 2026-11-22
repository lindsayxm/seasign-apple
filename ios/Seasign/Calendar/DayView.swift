import SwiftUI

/// The day screen (task 170), opened by tapping the events box on Today:
/// every event of today from Google and the pasted links, ended ones
/// included and dimmed, all-day events first, times worded as on Today
/// (`EventLabel`). The date as the header, the close mark at the top
/// right, and under it the mic and + buttons, which add events (tasks 171
/// and 172); the + is shown only with an `AddEventModel`, whose one-line
/// field and confirm popup open in a sheet, the mic only with a
/// `VoiceEntryModel`, which listens here (the words heard show under the
/// date), then opens the same popup and reads it aloud. After an add,
/// "Added · Sun 3:00 PM · Meeting with Rahaf" shows for a few seconds and
/// an event for today joins the list at once.
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
        .background(Palette.charcoal.ignoresSafeArea())
        .statusBarCover()
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
            SettingsView()
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

    private func content(now: Date) -> some View {
        let rows = model.rows(now: now, clock: clockStyle)
        let problem = model.problem(now: now)
        let zone = model.current(at: now).zone
        return VStack(alignment: .leading, spacing: 0) {
            header(HeaderDate(now: now, timeZone: zone))
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let voice, voice.isListening {
                            listening(voice.heard ?? "")
                                .padding(.top, 14)
                        } else if let notice = voice?.notice {
                            voiceNotice(notice)
                                .padding(.top, 14)
                        }
                        if let added = adder?.addedNote {
                            addedNote(added)
                                .padding(.top, 14)
                        }
                        if let problem {
                            note(problem.message)
                                .padding(.top, 14)
                        }
                        if rows.isEmpty {
                            if let empty = model.emptyLine(now: now) {
                                note(empty)
                                    .padding(.top, 24)
                            }
                        } else {
                            list(rows)
                                .padding(.top, 6)
                        }
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, hasButtons ? 8 : 20)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if hasButtons {
                    buttons
                        .padding(.top, 4)
                        .padding(.trailing, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var hasButtons: Bool {
        voice != nil || adder != nil
    }

    /// While the mic listens: what has been heard so far, as said.
    private func listening(_ heard: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caps: "Listening")
                .capsRelative(9.5, medium: true, tracking: 0.15)
                .foregroundStyle(Palette.dayWater)
            if heard.isEmpty {
                Text(caps: "Say the event and when, like “Lunch with Ann tomorrow at noon”.")
                    .capsRelative(10, tracking: 0.15)
                    .lineSpacing(4)
                    .foregroundStyle(Palette.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Verbatim: the user's own words.
                Text(caps: heard)
                    .capsRelative(13, medium: true, tracking: 0.12)
                    .lineSpacing(4)
                    .foregroundStyle(Palette.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(caps: "Tap the mic again when you're done.")
                .capsRelative(9.5, tracking: 0.15)
                .foregroundStyle(Palette.dimText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Why the mic did not listen; the + stays.
    private func voiceNotice(_ notice: VoiceNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caps: notice.message)
                .capsRelative(10, tracking: 0.15)
                .lineSpacing(4)
                .foregroundStyle(Palette.sun)
                .fixedSize(horizontal: false, vertical: true)
            if notice.opensSystemSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: url) {
                    Text(caps: "Open iPhone Settings")
                        .capsRelative(10)
                        .foregroundStyle(Palette.dimText)
                        .underline()
                        .frame(minHeight: 44)
                }
            }
        }
    }

    /// "Added · Sun 3:00 PM · Meeting with Rahaf", gone after a few seconds.
    private func addedNote(_ added: AddEventModel.AddedNote) -> some View {
        Text(caps: added.text)
            .capsRelative(10, medium: true, tracking: 0.15)
            .lineSpacing(4)
            .foregroundStyle(Palette.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
            .task(id: added.id) {
                try? await Task.sleep(for: .seconds(AddEventModel.addedNoteSeconds))
                adder?.hideAddedNote(added.id)
            }
    }

    private func header(_ date: HeaderDate) -> some View {
        HStack(alignment: .center) {
            Text(caps: date.spoken)
                .capsRelative(11, medium: true, tracking: 0.15)
                .foregroundStyle(Palette.white)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            CloseMark { dismiss() }
        }
    }

    /// Mic above +, each a 44-point target, in the line style of Today's icons.
    private var buttons: some View {
        VStack(spacing: 0) {
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
            LineIconView(icon: icon, size: 20, lineWidth: 1.3)
                .foregroundStyle(active ? Palette.charcoal : Palette.dimText)
                .frame(width: 44, height: 44)
                .background(active ? Palette.white : Color.clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func list(_ rows: [DayRow]) -> some View {
        // The time columns are as wide as their widest entry (each sized by
        // a hidden copy of it), so the titles line up.
        let widestLead = rows.map(\.label.timeLead).max { $0.count < $1.count } ?? ""
        let widestTail = rows.compactMap(\.label.timeTail).max { $0.count < $1.count }
        return VStack(alignment: .leading, spacing: 0) {
            // By position: two identical events would share an id.
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.rule)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                rowView(row, widestLead: widestLead, widestTail: widestTail)
            }
        }
    }

    private func rowView(_ row: DayRow, widestLead: String, widestTail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            column(row.label.timeLead, widest: widestLead)
            if let widestTail {
                column(row.label.timeTail ?? "", widest: widestTail)
                    .padding(.leading, 6)
            }
            // Verbatim: titles come from calendars and are never read as markup.
            Text(caps: row.label.title)
                .capsRelative(12, tracking: 0.15)
                .lineSpacing(5)
                .foregroundStyle(Palette.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .opacity(row.hasEnded ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.hasEnded ? "\(row.label.spoken), ended" : row.label.spoken))
    }

    private func column(_ text: String, widest: String) -> some View {
        ZStack(alignment: .leading) {
            Text(verbatim: widest).hidden()
            Text(verbatim: text)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Palette.dimText)
    }

    private func note(_ text: String) -> some View {
        Text(caps: text)
            .capsRelative(10, tracking: 0.15)
            .lineSpacing(4)
            .foregroundStyle(Palette.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
