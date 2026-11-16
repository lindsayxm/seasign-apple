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
    /// "10:15AM", "ALL DAY", or with the day when it is not today: "TUE 9:00AM",
    /// "TUE ALL DAY".
    var time: String
    /// The title as written; the view shows it in caps.
    var title: String
    /// For VoiceOver: "Hanna's show, 10:15 AM", "Tuesday, all day".
    var spoken: String

    static let untitled = "No title"

    private static let shortDays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    private static let longDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// `now` and `timeZone` decide what "today" is. A timed event is placed by
    /// its start in `timeZone`; an all-day event by its `date`, whatever the
    /// zone. The day is named only for events that start after today: one
    /// that began earlier and is still running reads as it would today.
    init(event: UpcomingEvent, now: Date, timeZone: TimeZone) {
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
        if event.allDay {
            clock = "ALL DAY"
            spokenClock = "all day"
        } else {
            let parts = calendar.dateComponents([.hour, .minute], from: event.start)
            let hour = parts.hour ?? 0
            let minute = String(format: "%02d", parts.minute ?? 0)
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let half = hour < 12 ? "AM" : "PM"
            clock = "\(hour12):\(minute)\(half)"
            spokenClock = "\(hour12):\(minute) \(half)"
        }

        if eventDay > today, let weekday, Self.shortDays.indices.contains(weekday) {
            time = "\(Self.shortDays[weekday]) \(clock)"
            spoken = "\(Self.longDays[weekday]), \(spokenClock)"
        } else {
            time = clock
            spoken = spokenClock
        }

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
