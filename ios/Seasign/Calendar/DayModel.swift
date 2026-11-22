import Foundation
import Observation

/// The events of one source (the pasted links, or Google) for one day, as
/// the day screen holds them. Kept in memory only: the day screen reads
/// afresh each time it opens, and Today's snapshots and caches are not
/// touched. Ended events are kept.
struct DaySourceSnapshot: Equatable, Sendable {
    /// `YYYY-MM-DD` in `timezone`: the day asked for.
    var day: String
    /// IANA identifier of the zone the day was asked in.
    var timezone: String
    /// Every event that overlaps the day, with `end` never before `start`.
    var events: [UpcomingEvent]
    /// The links or Google calendars (their ids) whose last read failed.
    var failed: Set<UUID>
    var fetchedAt: Date

    func isFor(day: String, timezone: String) -> Bool {
        self.day == day && self.timezone == timezone
    }
}

/// How a day answer becomes a `DaySourceSnapshot`. Unlike Today's
/// snapshots (`EventsSnapshot.make`, `GoogleEventsSnapshot.make`) nothing
/// that has ended is dropped.
enum DaySchedule {
    /// One status of an answer, in the terms both routes share.
    struct Status: Equatable {
        var failed: Bool
        /// The failure may pass by itself, so the events read earlier the
        /// same day stay (as on Today).
        var transient: Bool
    }

    /// `ids` are the links' or calendars' ids in the order they were sent;
    /// `status(index)` is the answer's status for the one at `index`, nil
    /// when the answer has none (then it counts as a passing failure, as
    /// on Today). Events of a source that failed in a passing way are
    /// carried over from `previous` when it is for the same day and zone.
    /// An event whose end is before its start (a floating time in a
    /// skipped clock hour) is kept as an event without a length.
    static func make(
        events: [CalendarAnswer.Event],
        ids: [UUID],
        status: (Int) -> Status?,
        day: String,
        timezone: String,
        previous: DaySourceSnapshot?,
        now: Date
    ) -> DaySourceSnapshot {
        var kept: [UpcomingEvent] = events.compactMap { event in
            guard ids.indices.contains(event.calendar) else { return nil }
            return UpcomingEvent(
                link: ids[event.calendar],
                title: event.title,
                start: event.start,
                end: max(event.start, event.end),
                allDay: event.allDay,
                date: event.date
            )
        }
        var failed = Set<UUID>()
        var carried = Set<UUID>()
        for (index, id) in ids.enumerated() {
            let status = status(index) ?? Status(failed: true, transient: true)
            guard status.failed else { continue }
            failed.insert(id)
            if status.transient { carried.insert(id) }
        }
        if let previous, previous.isFor(day: day, timezone: timezone) {
            kept += previous.events.filter { carried.contains($0.link) }
        }
        return DaySourceSnapshot(day: day, timezone: timezone, events: DayOrder.ordered(kept), failed: failed, fetchedAt: now)
    }

    /// A pasted-links answer.
    static func links(
        _ answer: CalendarAnswer, ids: [UUID], day: String, timezone: String, previous: DaySourceSnapshot?, now: Date
    ) -> DaySourceSnapshot {
        make(events: answer.events, ids: ids, status: { index in
            guard let status = answer.calendars.first(where: { $0.index == index }) else { return nil }
            let problem = status.ok ? nil : (status.error ?? .fetchFailed)
            return Status(failed: problem != nil, transient: problem?.isTransient ?? false)
        }, day: day, timezone: timezone, previous: previous, now: now)
    }

    /// A Google answer.
    static func google(
        _ answer: GoogleEventsAnswer, ids: [UUID], day: String, timezone: String, previous: DaySourceSnapshot?, now: Date
    ) -> DaySourceSnapshot {
        make(events: answer.events, ids: ids, status: { index in
            guard let status = answer.calendars.first(where: { $0.index == index }) else { return nil }
            let problem = status.ok ? nil : (status.error ?? .fetchFailed)
            return Status(failed: problem != nil, transient: problem?.isTransient ?? false)
        }, day: day, timezone: timezone, previous: previous, now: now)
    }
}

/// The order of the day screen: all-day events first, then the rest by
/// start (an event that began the evening before comes first among them).
/// Within each, `EventPicker`'s fixed order for equal starts: by title.
enum DayOrder {
    static func ordered(_ events: [UpcomingEvent]) -> [UpcomingEvent] {
        events.sorted { first, second in
            if first.allDay != second.allDay { return first.allDay }
            if first.start != second.start { return first.start < second.start }
            if first.title != second.title { return first.title < second.title }
            if first.end != second.end { return first.end < second.end }
            return first.link.uuidString < second.link.uuidString
        }
    }
}

/// When the day screen asks a source again. Pure, so it is tested without
/// waiting.
enum DayRefresh {
    /// How often the day screen's loops look again: Today's Google poll
    /// interval without push (`GooglePoll.interval`). Each turn asks Google
    /// and looks whether the pasted links are due.
    static let tick: Duration = GooglePoll.interval
    /// Google is asked on every turn: just under `tick`, as Today does.
    @MainActor static let googleInterval: TimeInterval = GoogleCalendarModel.minimumGap
    /// The pasted links, as on Today (`EventsModel.refreshInterval`).
    @MainActor static let linksInterval: TimeInterval = EventsModel.refreshInterval
    /// After the links could not be read, they are asked again this soon.
    static let linksRetry: TimeInterval = 30
    /// After a day refused for a date that has not changed (so it was not
    /// the midnight case), that source waits this long.
    static let refusedHold: TimeInterval = 60

    /// Whether a source is asked now. A hold (a 429's delay, a refusal)
    /// holds back even a forced ask; otherwise it is asked when forced
    /// (the screen opened, the app came back), when the day or zone it was
    /// last asked for is not the current one, or `interval` after the last ask.
    static func isDue(
        force: Bool, askedFor: String?, current: String, askedAt: Date?, interval: TimeInterval, hold: Date?, now: Date
    ) -> Bool {
        if let hold, now < hold { return false }
        if force || askedFor != current { return true }
        guard let askedAt else { return true }
        return now.timeIntervalSince(askedAt) >= interval
    }
}

/// One event as the day screen shows it.
struct DayRow: Equatable {
    var event: UpcomingEvent
    var label: EventLabel
    var hasEnded: Bool
}

/// Why the day screen shows a status line. Fixed words: never a link,
/// a calendar name or anything from an answer.
enum DayProblem: Equatable {
    case links
    case google
    case both

    var message: String {
        switch self {
        case .links:
            "A pasted calendar couldn't be read just now, so some events may be missing."
        case .google:
            "Google Calendar couldn't be read just now, so some events may be missing."
        case .both:
            "Some calendars couldn't be read just now, so some events may be missing."
        }
    }
}

/// The day screen's events (task 170): every event of today, ended ones
/// included, from the pasted links and Google, through the `day` parameter
/// of both event routes, merged in `DayOrder`, in the events' zone
/// (`EventZone`, the same closure Today's models use).
///
/// It holds its own snapshot in memory and never changes Today's models,
/// snapshots or caches. While the screen is open and the app active, `run`
/// asks Google every `DayRefresh.tick` (Today's poll stops under any cover)
/// and the links every 5 minutes, both at once when it starts (the screen
/// opened or the app came back). A failure keeps what is shown and sets
/// the status line. Google goes through `GoogleCalendarModel.dayEvents`,
/// which renews the token and handles failures as Today's poll does.
@MainActor
@Observable
final class DayModel {
    private(set) var links: DaySourceSnapshot?
    private(set) var google: DaySourceSnapshot?
    /// The last request for the links failed as a whole.
    private(set) var linksFailed = false
    /// The last read of Google failed as a whole.
    private(set) var googleFailed = false

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let events: EventsModel
    @ObservationIgnored private let googleModel: GoogleCalendarModel
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var linksAskedAt: Date?
    @ObservationIgnored private var linksAskedFor: String?
    @ObservationIgnored private var linksHold: Date?
    @ObservationIgnored private var linksInFlight = false
    @ObservationIgnored private var googleAskedAt: Date?
    @ObservationIgnored private var googleAskedFor: String?
    @ObservationIgnored private var googleHold: Date?
    @ObservationIgnored private var googleInFlight = false

    init(
        api: SeasignAPI = SeasignAPI(),
        events: EventsModel,
        google: GoogleCalendarModel,
        timeZone: @escaping @MainActor () -> TimeZone,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.events = events
        googleModel = google
        self.timeZone = timeZone
        self.now = now
        self.sleep = sleep
    }

    /// The day and zone events are asked for and shown in at `date`.
    func current(at date: Date) -> (day: String, zone: TimeZone) {
        let zone = timeZone()
        return (SkySnapshot.localDateString(for: date, in: zone), zone)
    }

    private func key(_ day: String, _ zone: TimeZone) -> String {
        "\(day) \(zone.identifier)"
    }

    // MARK: What the screen shows

    /// Today's events at `date`, all-day first, then by start; times worded
    /// as on Today. Only what was read for the current day and zone.
    func rows(now date: Date, clock: ClockStyle) -> [DayRow] {
        let (day, zone) = current(at: date)
        var merged: [UpcomingEvent] = []
        if let links = currentLinks(day: day, zone: zone) { merged += links.events }
        if let google = currentGoogle(day: day, zone: zone) { merged += google.events }
        return DayOrder.ordered(merged).map {
            DayRow(
                event: $0,
                label: EventLabel(event: $0, now: date, timeZone: zone, clock: clock),
                hasEnded: $0.hasEnded(at: date)
            )
        }
    }

    /// The status line at `date`; nil when every source was read.
    func problem(now date: Date) -> DayProblem? {
        let (day, zone) = current(at: date)
        let linksBad = expectsLinks && (linksFailed || !(currentLinks(day: day, zone: zone)?.failed.isEmpty ?? true))
        let googleBad = expectsGoogle && (googleFailed || !(currentGoogle(day: day, zone: zone)?.failed.isEmpty ?? true))
        switch (linksBad, googleBad) {
        case (true, true): return .both
        case (true, false): return .links
        case (false, true): return .google
        case (false, false): return nil
        }
    }

    /// A source that should answer has not answered for this day yet and
    /// has not failed: the screen says it is reading.
    func isWaiting(now date: Date) -> Bool {
        let (day, zone) = current(at: date)
        let links = expectsLinks && currentLinks(day: day, zone: zone) == nil && !linksFailed
        let google = expectsGoogle && currentGoogle(day: day, zone: zone) == nil && !googleFailed
        return links || google
    }

    /// Whether there is any calendar to read at all.
    var hasCalendars: Bool {
        expectsLinks || expectsGoogle
    }

    private var expectsLinks: Bool {
        !events.links.isEmpty
    }

    private var expectsGoogle: Bool {
        googleModel.connection == .connected && !googleModel.chosen.isEmpty
    }

    private func currentLinks(day: String, zone: TimeZone) -> DaySourceSnapshot? {
        guard expectsLinks, let links, links.isFor(day: day, timezone: zone.identifier) else { return nil }
        return links
    }

    /// Only the calendars that are on now, while connected.
    private func currentGoogle(day: String, zone: TimeZone) -> DaySourceSnapshot? {
        guard expectsGoogle, var google, google.isFor(day: day, timezone: zone.identifier) else { return nil }
        let on = Set(googleModel.chosen.map(\.id))
        google.events.removeAll { !on.contains($0.link) }
        google.failed.formIntersection(on)
        return google
    }

    // MARK: Asking

    /// While the screen is open and the app active: both sources at once,
    /// then Google every `DayRefresh.tick` and the links when due. Ends when
    /// the task is cancelled (the screen closed, the app left the foreground).
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loop(google: true) }
            group.addTask { await self.loop(google: false) }
        }
    }

    private func loop(google: Bool) async {
        var force = true
        while !Task.isCancelled {
            if google {
                await refreshGoogle(force: force)
            } else {
                await refreshLinks(force: force)
            }
            force = false
            await sleep(DayRefresh.tick)
        }
    }

    /// Both sources at once.
    func refresh(force: Bool = false) async {
        async let linksDone: Void = refreshLinks(force: force)
        async let googleDone: Void = refreshGoogle(force: force)
        _ = await (linksDone, googleDone)
    }

    /// Asks for the pasted links' events of the current day when due
    /// (`DayRefresh.isDue`). A refusal right after the date changed (the
    /// request crossed midnight) is asked again once for the new date.
    func refreshLinks(force: Bool = false) async {
        guard !linksInFlight else { return }
        #if DEBUG
        if events.isSample {
            showLinksSample()
            return
        }
        #endif
        guard expectsLinks else {
            links = nil
            linksFailed = false
            return
        }
        let held = [linksHold, events.retryNotBefore].compactMap { $0 }.max()
        let (day, zone) = current(at: now())
        guard DayRefresh.isDue(
            force: force, askedFor: linksAskedFor, current: key(day, zone), askedAt: linksAskedAt,
            interval: linksFailed ? DayRefresh.linksRetry : DayRefresh.linksInterval, hold: held, now: now()
        ) else { return }
        linksInFlight = true
        defer { linksInFlight = false }
        var askedDay = day
        var askedZone = zone
        for attempt in 0..<2 {
            let list = events.links
            let ids = list.map(\.id)
            linksAskedAt = now()
            linksAskedFor = key(askedDay, askedZone)
            let answer: CalendarAnswer
            do {
                answer = try await api.calendarEvents(links: list.map(\.url), timezone: askedZone.identifier, day: askedDay)
            } catch {
                // Cancelled: not a failure; the next start asks again.
                if Task.isCancelled {
                    linksAskedFor = nil
                    return
                }
                switch error as? SeasignAPI.CalendarFailure {
                case .rateLimited(let seconds)?:
                    linksHold = now().addingTimeInterval(TimeInterval(seconds))
                case .invalidRequest?:
                    let (newDay, newZone) = current(at: now())
                    if attempt == 0, key(newDay, newZone) != key(askedDay, askedZone) {
                        askedDay = newDay
                        askedZone = newZone
                        continue
                    }
                    linksHold = now().addingTimeInterval(DayRefresh.refusedHold)
                default:
                    break
                }
                linksFailed = true
                return
            }
            // The links, the day or the zone changed while it was out: the
            // next turn asks again.
            let (nowDay, nowZone) = current(at: now())
            guard ids == events.links.map(\.id), key(nowDay, nowZone) == key(askedDay, askedZone) else { return }
            let previous = links?.isFor(day: askedDay, timezone: askedZone.identifier) == true ? links : nil
            links = DaySchedule.links(answer, ids: ids, day: askedDay, timezone: askedZone.identifier, previous: previous, now: now())
            linksFailed = false
            linksHold = nil
            return
        }
    }

    /// Asks Google for the current day's events when due, through
    /// `GoogleCalendarModel.dayEvents` (its holds apply too). A refusal right
    /// after the date changed is asked again once for the new date.
    func refreshGoogle(force: Bool = false) async {
        guard !googleInFlight else { return }
        #if DEBUG
        if googleModel.isSample {
            showGoogleSample()
            return
        }
        #endif
        let (day, zone) = current(at: now())
        guard DayRefresh.isDue(
            force: force, askedFor: googleAskedFor, current: key(day, zone), askedAt: googleAskedAt,
            interval: DayRefresh.googleInterval, hold: googleHold, now: now()
        ) else { return }
        googleInFlight = true
        defer { googleInFlight = false }
        var askedDay = day
        var askedZone = zone
        for attempt in 0..<2 {
            googleAskedAt = now()
            googleAskedFor = key(askedDay, askedZone)
            switch await googleModel.dayEvents(day: askedDay, timezone: askedZone.identifier) {
            case .off:
                google = nil
                googleFailed = false
            case .skipped:
                // Held back, or the answer came too late to use; a
                // cancelled ask is asked again on the next start.
                if Task.isCancelled { googleAskedFor = nil }
            case .refused:
                let (newDay, newZone) = current(at: now())
                if attempt == 0, key(newDay, newZone) != key(askedDay, askedZone) {
                    askedDay = newDay
                    askedZone = newZone
                    continue
                }
                googleHold = now().addingTimeInterval(DayRefresh.refusedHold)
                googleFailed = true
            case .failed:
                googleFailed = true
            case .answer(let answer, let ids):
                let (nowDay, nowZone) = current(at: now())
                guard key(nowDay, nowZone) == key(askedDay, askedZone) else { return }
                let previous = google?.isFor(day: askedDay, timezone: askedZone.identifier) == true ? google : nil
                google = DaySchedule.google(answer, ids: ids, day: askedDay, timezone: askedZone.identifier, previous: previous, now: now())
                googleFailed = false
                googleHold = nil
            }
            return
        }
    }
}

#if DEBUG
extension DayModel {
    /// `-debugEvents YES`: the sample links' events that fall on the current
    /// day, from the frozen sample; nothing is sent.
    private func showLinksSample() {
        let (day, zone) = current(at: now())
        let today = events.upcoming(now: now()).filter { event in
            let date = event.allDay ? event.date : SkySnapshot.localDateString(for: event.start, in: zone)
            return date == day
        }
        links = DaySourceSnapshot(day: day, timezone: zone.identifier, events: DayOrder.ordered(today), failed: [], fetchedAt: now())
        linksFailed = false
    }

    /// `-debugGoogle YES`: sample events for the current day on the sample
    /// account's calendars that are on, made from the real time so one has
    /// always ended: an all-day event, one that ended, and two to come (as
    /// the Google sample on Today). The second calendar shows the sample's
    /// passing problem, so the status line shows. Nothing is sent.
    private func showGoogleSample() {
        let date = now()
        let (day, zone) = current(at: date)
        let on = googleModel.chosen.map(\.id)
        guard let first = on.first else {
            google = nil
            return
        }
        let second = on.dropFirst().first ?? first
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let startOfDay = calendar.startOfDay(for: date)
        let elapsed = date.timeIntervalSince(startOfDay)
        // Ended: an hour that ended an hour ago, or early in the day's first minutes.
        let endedStart = elapsed >= 2 * 3600 ? date.addingTimeInterval(-2 * 3600) : startOfDay
        let endedEnd = elapsed >= 2 * 3600 ? date.addingTimeInterval(-3600) : startOfDay.addingTimeInterval(elapsed / 2)
        let soon = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900 + 1800)
        var sample = [
            UpcomingEvent(
                link: first, title: "Farmers' market", start: startOfDay,
                end: calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400),
                allDay: true, date: day
            ),
            UpcomingEvent(link: first, title: "Morning run", start: endedStart, end: endedEnd, allDay: false),
            UpcomingEvent(link: first, title: "Coffee with Sam", start: soon, end: soon.addingTimeInterval(1800), allDay: false),
            UpcomingEvent(link: second, title: "Swim practice", start: soon.addingTimeInterval(7200), end: soon.addingTimeInterval(10_800), allDay: false),
        ]
        // Late in the day the two to come would fall on tomorrow.
        sample.removeAll { !$0.allDay && SkySnapshot.localDateString(for: $0.start, in: zone) != day }
        google = DaySourceSnapshot(
            day: day, timezone: zone.identifier, events: DayOrder.ordered(sample),
            failed: second == first ? [] : [second], fetchedAt: date
        )
        googleFailed = false
    }
}
#endif
