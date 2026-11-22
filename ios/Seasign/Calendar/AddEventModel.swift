import Foundation
import Observation

/// Adding an event from the day screen (task 171): the line typed in the
/// one-line field is understood on the phone (`EventPhraseParser`), the
/// confirm popup shows the draft, and only `confirm()` adds it to Google
/// (`GoogleCalendarModel.createEvent`).
///
/// The popup's content and its two answers live here, not in the view, so
/// the voice entry (task 172) can show the same popup, read it aloud and
/// answer it with the same `confirm()` and `cancel()`. Confirm is
/// single-flight: whatever calls it, one draft is sent once at a time, and
/// a retry of the same draft to the same calendar sends the same event id,
/// so a retry after a timeout cannot add it twice.
@MainActor
@Observable
final class AddEventModel {
    /// What the popup shows.
    enum Stage: Equatable {
        case closed
        /// The one-line field.
        case entering
        /// The draft, with Confirm and Cancel.
        case reviewing(EventDraft)
        /// The line was not understood: what is missing, and Try again.
        case problem(EventDraftProblem)
        /// Understood, but Google cannot take it yet: what is needed, and Settings.
        case blocked(EventDraft, Block)
        /// Confirmed; the popup cannot be closed until Google answers.
        case sending(EventDraft)
        /// Not added, or not certain: why, and what can be done.
        case failed(EventDraft, Note)
    }

    /// What Google needs before an event can be added.
    enum Block: Equatable {
        /// No Google connection (or it has ended).
        case connect
        /// Connected without write access (a connection from before it was asked for).
        case connectAgain
        /// Connected with write access, but which calendar takes new events
        /// is not known yet (the list has not been read with its roles).
        case chooseCalendar

        var message: String {
            switch self {
            case .connect:
                "To add events, connect Google Calendar in Settings."
            case .connectAgain:
                "Seasign can only read your Google calendars. Connect again to add events, in Settings."
            case .chooseCalendar:
                "Seasign doesn't know yet which calendar new events go to. Open Settings to choose one under New events go to."
            }
        }
    }

    /// Why an event was not added, in plain words.
    struct Note: Equatable {
        var text: String
        /// Try again sends the same draft again (with the same id).
        var canRetry: Bool
        /// The fix is in Settings.
        var opensSettings: Bool
        /// Try again waits until then (our 429's `Retry-After`).
        var retryAt: Date?
    }

    /// The line on screen after an event was added: "Added · Sun 3:00 PM ·
    /// Meeting with Rahaf". `id` changes with each add, so the day screen
    /// times each note on its own.
    struct AddedNote: Equatable {
        var id = UUID()
        var text: String
    }

    /// How long the day screen shows the "Added" note.
    static let addedNoteSeconds: Double = 5

    /// The one-line field's text.
    var line = ""
    private(set) var stage: Stage = .closed
    private(set) var addedNote: AddedNote?
    /// Called with the event as added, to show it on the day screen at once.
    @ObservationIgnored var onAdded: ((UpcomingEvent) -> Void)?

    @ObservationIgnored private let google: GoogleCalendarModel
    @ObservationIgnored private let parser: EventPhraseParser
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let clock: @MainActor () -> ClockStyle
    @ObservationIgnored private let makeID: @Sendable () -> String
    /// The id minted for a confirmed draft and the calendar it went to,
    /// kept for retries of that same draft to that calendar.
    @ObservationIgnored private var pending: (draft: EventDraft, calendarID: String, id: String)?
    /// The send that is out; owned here, so closing a view cannot cancel it.
    @ObservationIgnored private(set) var sending: Task<Void, Never>?

    init(
        google: GoogleCalendarModel,
        parser: EventPhraseParser = EventPhraseParser(),
        timeZone: @escaping @MainActor () -> TimeZone,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: @escaping @MainActor () -> ClockStyle = { .system },
        makeID: @escaping @Sendable () -> String = { GoogleNewEvent.makeID() }
    ) {
        self.google = google
        self.parser = parser
        self.timeZone = timeZone
        self.now = now
        self.clock = clock
        self.makeID = makeID
    }

    var isOpen: Bool {
        stage != .closed
    }

    var isSending: Bool {
        if case .sending = stage { return true }
        return false
    }

    /// The calendar the draft goes to, by name, for the popup.
    var calendarName: String? {
        google.newEventsCalendar?.name
    }

    // MARK: The field

    /// Opens the one-line field, with `line` in it.
    func open(line: String = "") {
        guard !isSending else { return }
        self.line = line
        stage = .entering
    }

    /// Reads the field's line and shows the popup: the draft, what is
    /// missing from the line, or what Google needs first.
    func submit() {
        guard stage == .entering else { return }
        switch parser.parse(line, now: now(), timeZone: timeZone()) {
        case .problem(let problem):
            stage = .problem(problem)
        case .draft(let draft):
            if let block = block() {
                stage = .blocked(draft, block)
            } else {
                stage = .reviewing(draft)
            }
        }
    }

    /// What keeps an event from being added now; nil when nothing does.
    private func block() -> Block? {
        guard google.connection == .connected else { return .connect }
        guard google.canAddEvents else { return .connectAgain }
        guard google.newEventsCalendar != nil else { return .chooseCalendar }
        return nil
    }

    /// Back to the field with the line kept, to change it.
    func tryAgain() {
        guard !isSending else { return }
        stage = .entering
    }

    // MARK: The popup's answers

    /// Adds the draft on show. Does nothing unless the popup shows a draft
    /// (or a failure that can be tried again, once any wait is over), so a
    /// second tap, or a tap and a spoken "confirm", send it once.
    func confirm() {
        let draft: EventDraft
        switch stage {
        case .reviewing(let shown):
            draft = shown
        case .failed(let shown, let note) where note.canRetry:
            if let retryAt = note.retryAt, now() < retryAt { return }
            draft = shown
        default:
            return
        }
        if let block = block() {
            stage = .blocked(draft, block)
            return
        }
        guard let calendar = google.newEventsCalendar else { return }
        // The same draft to the same calendar keeps its id; anything else gets a new one.
        let id: String
        if let pending, pending.draft == draft, pending.calendarID == calendar.calendarID {
            id = pending.id
        } else {
            id = makeID()
            pending = (draft, calendar.calendarID, id)
        }
        stage = .sending(draft)
        let event = GoogleNewEvent(
            calendarID: calendar.calendarID, id: id, title: draft.title,
            timezone: GoogleNewEvent.zoneName(draft.timeZone), timing: draft.timing
        )
        let link = calendar.id
        sending = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.send(event)
            self.finish(outcome, draft: draft, link: link)
        }
    }

    /// Closes the popup; nothing is added. Ignored while a confirmed draft
    /// is being sent: its outcome is shown when Google answers.
    func cancel() {
        guard !isSending else { return }
        stage = .closed
        line = ""
    }

    private func send(_ event: GoogleNewEvent) async -> GoogleCalendarModel.CreateOutcome {
        #if DEBUG
        // `-debugAddEventFail <problem>` with the sample: as if Google answered so.
        if google.isSample, let problem = Self.debugFailure() { return .failed(problem) }
        #endif
        return await google.createEvent(event)
    }

    private func finish(_ outcome: GoogleCalendarModel.CreateOutcome, draft: EventDraft, link: UUID) {
        sending = nil
        switch outcome {
        case .added:
            // `created: false` is Google already having this id: an earlier
            // try did add it, so the draft is shown as added.
            pending = nil
            stage = .closed
            line = ""
            addedNote = AddedNote(text: Self.addedText(draft, now: now(), clock: clock()))
            onAdded?(Self.event(draft, link: link))
        case .failed(let problem):
            let note = Self.note(for: problem, calendar: calendarName)
            if !note.canRetry { pending = nil }
            stage = .failed(draft, note)
        }
    }

    /// The day screen hides the note after `addedNoteSeconds`.
    func hideAddedNote(_ id: UUID) {
        if addedNote?.id == id { addedNote = nil }
    }

    // MARK: Words

    static func note(for problem: GoogleCalendarModel.CreateProblem, calendar: String?) -> Note {
        let name = calendar.map { "“\($0)”" } ?? "that calendar"
        switch problem {
        case .notConnected:
            return Note(text: "Google Calendar isn't connected, so the event wasn't added. Connect it in Settings.", canRetry: false, opensSettings: true)
        case .needsWriteAccess:
            return Note(text: "Google hasn't allowed Seasign to add events, so it wasn't added. Connect again to add events, in Settings.", canRetry: false, opensSettings: true)
        case .calendarRefused:
            return Note(text: "Google won't take new events in \(name), so it wasn't added. Choose another calendar under New events go to, in Settings.", canRetry: false, opensSettings: true)
        case .calendarMissing:
            return Note(text: "Google couldn't find \(name), so the event wasn't added. Choose another calendar under New events go to, in Settings.", canRetry: false, opensSettings: true)
        case .rejected:
            return Note(text: "Google refused this event, so it wasn't added.", canRetry: false, opensSettings: false)
        case .invalid:
            return Note(text: "Seasign couldn't send this event, so it wasn't added. Try writing it another way.", canRetry: false, opensSettings: false)
        case .rateLimited(let until):
            return Note(text: "Too many requests just now, so the event wasn't added. Try again in a minute.", canRetry: true, opensSettings: false, retryAt: until)
        case .unavailable:
            return Note(text: "Google couldn't be reached, so the event may not have been added. Try again; it won't be added twice.", canRetry: true, opensSettings: false)
        case .signInTrouble:
            return Note(text: "Google didn't accept the sign-in just now, so the event wasn't added. Try again in a moment.", canRetry: true, opensSettings: false)
        }
    }

    /// "Added · Sun 3:00 PM · Meeting with Rahaf"; "Added · Sun all day · …";
    /// a date more than six days off by its month and day ("Dec 3").
    static func addedText(_ draft: EventDraft, now: Date, clock: ClockStyle) -> String {
        "Added · \(DraftSummary.shortWhen(draft, now: now, clock: clock)) · \(draft.title)"
    }

    /// The event as the day screen lists it, on calendar `link`.
    static func event(_ draft: EventDraft, link: UUID) -> UpcomingEvent {
        switch draft.timing {
        case .timed(let start, let end):
            return UpcomingEvent(link: link, title: draft.title, start: start, end: end, allDay: false)
        case .allDay(let date):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = draft.timeZone
            let parts = date.split(separator: "-").compactMap { Int($0) }
            let start = parts.count == 3
                ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
                : Date()
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return UpcomingEvent(link: link, title: draft.title, start: start, end: end, allDay: true, date: date)
        }
    }

    #if DEBUG
    private static func debugFailure() -> GoogleCalendarModel.CreateProblem? {
        switch UserDefaults.standard.string(forKey: "debugAddEventFail") {
        case "insufficient_scope": .needsWriteAccess
        case "forbidden": .calendarRefused
        case "not_found": .calendarMissing
        case "rejected": .rejected
        case "rate_limited": .rateLimited(until: nil)
        case "timeout", "fetch_failed": .unavailable
        default: nil
        }
    }
    #endif
}

/// The popup's lines for one draft, worded for the screen and for reading
/// aloud (task 172). Pure.
struct DraftSummary: Equatable {
    var title: String
    /// "Sunday, November 29"
    var day: String
    /// "3:00 PM – 4:00 PM", or "All day".
    var time: String
    /// "1 hour", "1 hour 30 minutes"; nil for an all-day event.
    var length: String?
    /// "This time has already passed today." or "This day has already
    /// passed." when the draft is in the past; nil otherwise.
    var pastNote: String?
    /// "Meeting with Rahaf, Sunday at 3 PM, one hour." for reading aloud.
    var spoken: String

    init(_ draft: EventDraft, now: Date, clock: ClockStyle) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = draft.timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = draft.timeZone
        formatter.dateFormat = "EEEE, MMMM d"
        title = draft.title
        let spokenDay: String
        switch draft.timing {
        case .timed(let start, let end):
            day = formatter.string(from: start)
            formatter.dateFormat = "EEEE"
            spokenDay = formatter.string(from: start)
            let begin = calendar.dateComponents([.hour, .minute], from: start)
            let finish = calendar.dateComponents([.hour, .minute], from: end)
            let from = clock.clock(hour: begin.hour ?? 0, minute: begin.minute ?? 0).spoken
            let to = clock.clock(hour: finish.hour ?? 0, minute: finish.minute ?? 0).spoken
            time = "\(from) – \(to)"
            let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
            length = Self.length(minutes: minutes)
            if start < now {
                pastNote = calendar.isDate(start, inSameDayAs: now)
                    ? "This time has already passed today." : "This day has already passed."
            }
            spoken = "\(draft.title), \(spokenDay) at \(Self.spokenClock(begin.hour ?? 0, begin.minute ?? 0, clock: clock)), \(Self.length(minutes: minutes, words: true))."
        case .allDay(let date):
            let parts = date.split(separator: "-").compactMap { Int($0) }
            let start = parts.count == 3 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? now : now
            day = formatter.string(from: start)
            formatter.dateFormat = "EEEE"
            spokenDay = formatter.string(from: start)
            time = "All day"
            length = nil
            if start < calendar.startOfDay(for: now) { pastNote = "This day has already passed." }
            spoken = "\(draft.title), \(spokenDay), all day."
        }
    }

    /// "1 hour", "30 minutes", "1 hour 30 minutes"; with `words`, "one hour".
    static func length(minutes: Int, words: Bool = false) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        func count(_ value: Int, _ unit: String) -> String {
            let number = words && value == 1 ? "one" : "\(value)"
            return "\(number) \(unit)\(value == 1 ? "" : "s")"
        }
        switch (hours, rest) {
        case (0, _): return count(rest, "minute")
        case (_, 0): return count(hours, "hour")
        default: return "\(count(hours, "hour")) \(count(rest, "minute"))"
        }
    }

    private static func spokenClock(_ hour: Int, _ minute: Int, clock: ClockStyle) -> String {
        guard clock == .twelveHour else { return String(format: "%02d:%02d", hour, minute) }
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let half = hour < 12 ? "AM" : "PM"
        return minute == 0 ? "\(hour12) \(half)" : String(format: "%d:%02d %@", hour12, minute, half)
    }

    /// "Sun 3:00 PM", "Sun all day"; more than six days off, "Dec 3 3:00 PM".
    static func shortWhen(_ draft: EventDraft, now: Date, clock: ClockStyle) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = draft.timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = draft.timeZone
        let start: Date
        var time = "all day"
        switch draft.timing {
        case .timed(let begin, _):
            start = begin
            let parts = calendar.dateComponents([.hour, .minute], from: begin)
            time = clock.clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0).spoken
        case .allDay(let date):
            let parts = date.split(separator: "-").compactMap { Int($0) }
            start = parts.count == 3 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? now : now
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
        formatter.dateFormat = (0...6).contains(days) ? "EEE" : "MMM d"
        return "\(formatter.string(from: start)) \(time)"
    }
}
