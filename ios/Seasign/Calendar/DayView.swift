import SwiftUI

/// The day screen (task 170), opened by tapping the events box on Today:
/// every event of today from Google and the pasted links, ended ones
/// included and dimmed, all-day events first, times worded as on Today
/// (`EventLabel`). The date as the header, the close mark at the top
/// right, and under it the mic and + buttons, which add events (tasks 171
/// and 172); each is shown only when its closure is set.
///
/// It reads through its own `DayModel`, which refreshes while the screen is
/// open and the app is active (Today's Google poll stops under any cover).
struct DayView: View {
    /// Adds an event by voice; the mic is hidden while nil.
    var speak: (() -> Void)?
    /// Adds an event by typing; the + is hidden while nil.
    var type: (() -> Void)?

    @State private var model: DayModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.clockStyle) private var clockStyle

    init(model: DayModel, speak: (() -> Void)? = nil, type: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        self.speak = speak
        self.type = type
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
    }

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
                        if let problem {
                            note(problem.message)
                                .padding(.top, 14)
                        }
                        if rows.isEmpty {
                            note(emptyText(now: now))
                                .padding(.top, 24)
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
        speak != nil || type != nil
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
            if let speak {
                iconButton(.mic, label: "Add an event by voice", action: speak)
            }
            if let type {
                iconButton(.plus, label: "Type an event", action: type)
            }
        }
    }

    private func iconButton(_ icon: LineIcon, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LineIconView(icon: icon, size: 20, lineWidth: 1.3)
                .foregroundStyle(Palette.dimText)
                .frame(width: 44, height: 44)
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

    private func emptyText(now: Date) -> String {
        if !model.hasCalendars {
            return "No calendars yet. Connect Google Calendar or paste a calendar link in Settings."
        }
        if model.isWaiting(now: now) {
            return "Reading your calendars…"
        }
        return "Nothing on your calendar today."
    }
}
