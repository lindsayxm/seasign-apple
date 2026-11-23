import Foundation

/// One event from `POST /v1/calendar/events`, as the app keeps it: tied to the
/// `CalendarLink` it came from by that link's id, never by its URL.
struct UpcomingEvent: Codable, Sendable, Equatable {
    /// `CalendarLink.id` of the calendar this came from.
    var link: UUID
    /// The event's summary; empty when it has none.
    var title: String
    var start: Date
    /// Equal to `start` for an event without a length.
    var end: Date
    var allDay: Bool
    /// Only for all-day events: the local date the event starts on, `YYYY-MM-DD`.
    var date: String?

    /// The API's own rule: an event without a length is over the moment it
    /// has started; any other is over at its end.
    func hasEnded(at now: Date) -> Bool {
        end == start ? start < now : end <= now
    }
}

/// Why a calendar link could not be read; the API's per-link error codes.
enum LinkProblem: String, Codable, CaseIterable, Sendable {
    case invalidLink = "invalid_link"
    case blockedHost = "blocked_host"
    case fetchFailed = "fetch_failed"
    case timeout
    case tooLarge = "too_large"
    case notCalendar = "not_calendar"

    /// Shown in Settings. Never mentions the link itself.
    var message: String {
        switch self {
        case .invalidLink:
            "That doesn't look like a calendar link. It should start with https:// or webcal://."
        case .blockedHost:
            "That link points to a private address, so it can't be read."
        case .fetchFailed:
            "We couldn't reach that calendar. Check the link and try again."
        case .timeout:
            "That calendar took too long to answer. Try again in a moment."
        case .tooLarge:
            "That calendar is too large to read."
        case .notCalendar:
            "That link didn't return a calendar."
        }
    }

    /// A failure that may pass by itself, so events read earlier stay on Today.
    var isTransient: Bool {
        self == .fetchFailed || self == .timeout
    }
}

/// How the last read of one calendar link went.
struct LinkStatus: Codable, Sendable, Equatable {
    /// Nil when the calendar was read.
    var problem: LinkProblem?
    /// The calendar was read but something in it was left out.
    var partial: Bool

    static let partialMessage = "Some events in this calendar couldn't be read."

    /// The line under a link in Settings; nil when all is well.
    var message: String? {
        if let problem { return problem.message }
        return partial ? Self.partialMessage : nil
    }
}

/// The app's copy of the last events response, which is also what the cache
/// store holds. It carries no link, only link ids.
struct EventsSnapshot: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var link: UUID
        var status: LinkStatus
    }

    var events: [UpcomingEvent]
    /// One entry per link that was asked for.
    var statuses: [Entry]
    /// IANA identifier of the time zone the request was made for. All-day
    /// events were placed in it, so the snapshot is only good for that zone.
    var timezone: String
    /// When the app received the response.
    var fetchedAt: Date

    func status(for link: UUID) -> LinkStatus? {
        statuses.first { $0.link == link }?.status
    }

    /// A response turned into a snapshot. `links` are the ids of the links in
    /// the order they were sent. Events of a link that failed in a passing way
    /// (unreachable, timed out) are carried over from `previous`, so one bad
    /// moment does not take a calendar off Today; they drop out as they end.
    static func make(
        from answer: CalendarAnswer,
        links: [UUID],
        timezone: String,
        previous: EventsSnapshot?,
        now: Date
    ) -> EventsSnapshot {
        var events: [UpcomingEvent] = answer.events.compactMap { event in
            guard links.indices.contains(event.calendar) else { return nil }
            return UpcomingEvent(
                link: links[event.calendar],
                title: event.title,
                start: event.start,
                end: event.end,
                allDay: event.allDay,
                date: event.date
            )
        }
        var statuses: [Entry] = []
        for (index, link) in links.enumerated() {
            guard let status = answer.calendars.first(where: { $0.index == index }) else {
                // The API answers for every link; one without an answer was not read.
                statuses.append(Entry(link: link, status: LinkStatus(problem: .fetchFailed, partial: false)))
                continue
            }
            let problem = status.ok ? nil : (status.error ?? .fetchFailed)
            statuses.append(Entry(link: link, status: LinkStatus(problem: problem, partial: status.ok && status.partial)))
        }
        if let previous, previous.timezone == timezone {
            let carried = Set(statuses.filter { $0.status.problem?.isTransient == true }.map(\.link))
            events += previous.events.filter { carried.contains($0.link) }
        }
        return EventsSnapshot(
            events: EventPicker.upcoming(events, now: now),
            statuses: statuses,
            timezone: timezone,
            fetchedAt: now
        )
    }

    /// Without what belongs to a link that was removed.
    func removing(link: UUID) -> EventsSnapshot {
        var copy = self
        copy.events.removeAll { $0.link == link }
        copy.statuses.removeAll { $0.link == link }
        return copy
    }

    /// Without the events that have ended.
    func pruned(at now: Date) -> EventsSnapshot {
        var copy = self
        copy.events = EventPicker.upcoming(events, now: now)
        return copy
    }
}

/// Which events Today shows.
enum EventPicker {
    /// The events that have not ended, soonest first. Events starting at the
    /// same instant keep a fixed order: all-day first, then by title.
    static func upcoming(_ events: [UpcomingEvent], now: Date) -> [UpcomingEvent] {
        events
            .filter { !$0.hasEnded(at: now) }
            .sorted { first, second in
                if first.start != second.start { return first.start < second.start }
                if first.allDay != second.allDay { return first.allDay }
                return first.title < second.title
            }
    }

    /// The next `limit` events that have not ended.
    static func next(_ events: [UpcomingEvent], now: Date, limit: Int = 3) -> [UpcomingEvent] {
        Array(upcoming(events, now: now).prefix(max(0, limit)))
    }
}

/// The time zone events are asked for and shown in: the zip's when a zip is
/// set and its sky is known, otherwise the phone's.
enum EventZone {
    static func resolve(zip: String?, snapshot: SkySnapshot?, device: TimeZone) -> TimeZone {
        guard let zip, let snapshot, snapshot.zip == zip,
              let zone = TimeZone(identifier: snapshot.timezone)
        else { return device }
        return zone
    }
}

/// One event as Today words it.
struct EventLabel: Equatable, Sendable {
    /// "10:15AM" (or "10:15" with the phone on 24-hour time), "ALL DAY", or
    /// with the day when it is not today: "TUE 9:00AM" / "TUE 09:00",
    /// "TUE ALL DAY".
    var time: String
    /// Today's first time column: the clock (`6:45`, `18:45`), with the day
    /// in front when the event is on a later day (`TUE 6:45`); for an
    /// all-day event the day (`TUE`), or `ALL` when it is today. On a
    /// 24-hour phone all of the time is in this one column (`TUE 18:45`,
    /// `TUE ALL`, `ALL DAY`).
    var timeLead: String
    /// Today's second time column on a 12-hour phone: `AM` or `PM`, or for
    /// an all-day event `ALL` (`DAY` when it is today). Nil on a 24-hour phone.
    var timeTail: String?
    /// The time column of a row in Today's v12 events box (`EventRowText`):
    /// the clock without its half (`11:00`, `18:45`), `ALL` for an all-day
    /// event today, or the weekday (`TUE`) for any event on a later day.
    var rowTime: String
    /// The letter after `rowTime` on a 12-hour phone: `A` or `P`. Nil for
    /// `ALL`, a weekday, and every time on a 24-hour phone.
    var rowLetter: Character?
    /// The title as written; the view shows it in caps.
    var title: String
    /// For VoiceOver: "Hanna's show, 10:15 AM" (or "10:15"), "Tuesday, all day".
    var spoken: String

    static let untitled = "No title"

    private static let shortDays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    private static let longDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// `now` and `timeZone` decide what "today" is. A timed event is placed by
    /// its start in `timeZone`; an all-day event by its `date`, whatever the
    /// zone. The day is named only for events that start after today: one
    /// that began earlier and is still running reads as it would today.
    /// `clock` is the phone's 12- or 24-hour setting (`ClockStyle.system`).
    init(event: UpcomingEvent, now: Date, timeZone: TimeZone, clock style: ClockStyle) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let today = SkySnapshot.localDateString(for: now, in: timeZone)
        let eventDay: String
        let weekday: Int?
        if event.allDay, let date = event.date, let index = Self.weekday(ofDate: date) {
            eventDay = date
            weekday = index
        } else {
            eventDay = SkySnapshot.localDateString(for: event.start, in: timeZone)
            weekday = calendar.dateComponents([.weekday], from: event.start).weekday.map { $0 - 1 }
        }

        let clock: String
        let spokenClock: String
        // The two columns before the day is put in front.
        var lead: String
        var tail: String?
        if event.allDay {
            clock = "ALL DAY"
            spokenClock = "all day"
            (lead, tail) = style == .twelveHour ? ("ALL", "DAY") : ("ALL DAY", nil)
        } else {
            let parts = calendar.dateComponents([.hour, .minute], from: event.start)
            (clock, spokenClock) = style.clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            (lead, tail) = style.columns(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }

        // The v12 row's time column, before the day is decided.
        if event.allDay {
            rowTime = "ALL"
            rowLetter = nil
        } else {
            rowTime = lead
            rowLetter = tail?.first
        }

        if eventDay > today, let weekday, Self.shortDays.indices.contains(weekday) {
            let day = Self.shortDays[weekday]
            rowTime = day
            rowLetter = nil
            time = "\(day) \(clock)"
            spoken = "\(Self.longDays[weekday]), \(spokenClock)"
            if event.allDay {
                // The mockup's `TUE  ALL`.
                (lead, tail) = style == .twelveHour ? (day, "ALL") : ("\(day) ALL", nil)
            } else {
                lead = "\(day) \(lead)"
            }
        } else {
            time = clock
            spoken = spokenClock
        }
        timeLead = lead
        timeTail = tail

        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? Self.untitled : trimmed
        spoken = "\(title), \(spoken)"
    }

    /// 0 for Sunday … 6 for Saturday, for a `YYYY-MM-DD` date; nil if it is not one.
    static func weekday(ofDate text: String) -> Int? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.utf8.count == 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
            calendar.component(.month, from: date) == parts[1],
            calendar.component(.day, from: date) == parts[2]
        else { return nil }
        return calendar.component(.weekday, from: date) - 1
    }
}
