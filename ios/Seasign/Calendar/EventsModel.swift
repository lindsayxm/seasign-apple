import Foundation
import Observation
import SwiftData

/// The calendar links and their upcoming events: shows the cached events at
/// once, then refreshes them from `POST /v1/calendar/events`.
///
/// A calendar link is a credential. This type hands views the `CalendarLink`
/// rows so they can show a name and a masked host; it never puts a link into
/// an error, a message or a log.
@MainActor
@Observable
final class EventsModel {
    /// Why a link typed in Settings was not added.
    enum AddProblem: Error, Equatable {
        case missingName
        case missingLink
        case alreadyAdded
        case limitReached
        /// The API could not read the link.
        case link(LinkProblem)
        /// The API could not be asked.
        case unavailable
        /// The API's per-network limit refused the check.
        case rateLimited
        /// The link was fine but could not be written to the phone.
        case notSaved

        var message: String {
            switch self {
            case .missingName:
                "Give this calendar a name."
            case .missingLink:
                "Paste the calendar's link."
            case .alreadyAdded:
                "That calendar is already in your list."
            case .limitReached:
                "You can have up to \(EventsModel.maxLinks) calendars. Remove one to add another."
            case .link(let problem):
                problem.message
            case .unavailable:
                "We couldn't check that link. Check your connection and try again."
            case .rateLimited:
                ServerRateLimit.message
            case .notSaved:
                "That calendar couldn't be saved on this phone. Try again."
            }
        }
    }

    /// The API takes at most this many links in one request.
    nonisolated static let maxLinks = 10

    /// Events younger than this are not fetched again by the scheduled
    /// checks. User decision 2026-11-21: pasted links are the slow fallback
    /// (Connect Google is the fast path). The API caches each calendar for 5
    /// minutes too, so with Today's minute loop an event added to a calendar
    /// shows within about 5 minutes, up to about 10 when another phone keeps
    /// the same link's cache entry warm. A pull, adding a link and a return to
    /// the foreground with stale events ask the API to read the links again
    /// (`fresh`). That is one scheduled request every 5 minutes, far under
    /// the API's calendar limit of 20 a minute per network.
    static let refreshInterval: TimeInterval = 5 * 60

    /// The user's links, oldest first.
    private(set) var links: [CalendarLink] = []
    /// The latest events, from the cache or the network.
    private(set) var snapshot: EventsSnapshot?
    /// The API's rate limit asked to wait until then: refreshes are not
    /// sent before it (adding a link in Settings still is).
    @ObservationIgnored private(set) var retryNotBefore: Date?

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let store: EventsStore
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Set for the DEBUG sample: nothing is fetched and nothing is dropped.
    @ObservationIgnored private var isFrozen = false
    /// Requests sent by `refresh` so far.
    @ObservationIgnored private var requestsSent = 0
    /// `requestsSent` when the snapshot last took a fresh answer; nil once
    /// the snapshot is cleared. A scheduled answer to a request sent by then
    /// is dropped: it may come from the API's cache and is never newer than
    /// that fresh answer (on a return to the foreground the minute loop and
    /// the return can both ask at once). Only a fresh answer that was shown
    /// counts, so a fresh request that fails (a 429, say) or whose answer
    /// was out of date never hides a scheduled answer. No links or zone
    /// need comparing: an answer for other links or another zone is dropped
    /// as out of date anyway, and a fresh answer for more links (one added,
    /// then removed) still holds newer events for the scheduled one's links,
    /// since a removed link never comes back with the same id.
    @ObservationIgnored private var freshShownAt: Int?

    /// `timeZone` is asked each time events are fetched or shown: the zip's
    /// zone when a zip is set, otherwise the phone's (see `EventZone`).
    init(
        api: SeasignAPI = SeasignAPI(),
        context: ModelContext,
        timeZone: @escaping @MainActor () -> TimeZone,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.store = EventsStore(context: context)
        self.timeZone = timeZone
        self.now = now
        links = store.links()
        if links.isEmpty {
            // Events without a link to belong to are never shown or kept.
            if store.cachedEvents() != nil { store.cache(nil) }
        } else {
            snapshot = store.cachedEvents()?.pruned(at: now())
        }
    }

    var canAddLink: Bool {
        links.count < Self.maxLinks
    }

    /// Whether this is the DEBUG sample (`-debugEvents YES`), whose links
    /// are made up and must never be sent. Always false in a Release build.
    var isSample: Bool {
        isFrozen
    }

    /// The next events for Today at `now`, in the events' time zone, with
    /// times in the phone's 12- or 24-hour form (`clock`). Empty while the
    /// cached events belong to another time zone.
    func labels(now: Date, clock: ClockStyle, limit: Int = 3) -> [EventLabel] {
        let zone = timeZone()
        return EventPicker.next(upcoming(now: now), now: now, limit: limit).map {
            EventLabel(event: $0, now: now, timeZone: zone, clock: clock)
        }
    }

    /// The events that have not ended, soonest first, in the events' time
    /// zone; empty while the cached events belong to another zone. Today
    /// merges these with the Google events (`TodayEvents`).
    func upcoming(now: Date) -> [UpcomingEvent] {
        guard let snapshot, isFrozen || snapshot.timezone == timeZone().identifier else { return [] }
        return EventPicker.upcoming(snapshot.events, now: now)
    }

    /// How the last read of `link` went; nil if it has not been read yet.
    func status(for link: CalendarLink) -> LinkStatus? {
        snapshot?.status(for: link.id)
    }

    /// Whether a scheduled check would ask now: there are links and the
    /// events are missing, lack a link, belong to another zone or are at
    /// least `refreshInterval` old. Today reads it as the app comes back to
    /// the foreground, to decide whether that return asks with `force`.
    var isDue: Bool {
        guard !isFrozen, !links.isEmpty else { return false }
        guard let snapshot, snapshot.timezone == timeZone().identifier else { return true }
        let coversEveryLink = Set(snapshot.statuses.map(\.link)) == Set(links.map(\.id))
        return !coversEveryLink || now().timeIntervalSince(snapshot.fetchedAt) >= Self.refreshInterval
    }

    /// Fetches the events of every link unless the current ones are fresh. If
    /// the request fails as a whole, what is on screen stays.
    ///
    /// `force` (the pull, a return to the foreground with stale events) asks
    /// even when the events are fresh, and asks the API to read the links
    /// again instead of answering from its cache. A 429's delay still holds
    /// it back.
    func refresh(force: Bool = false) async {
        guard !isFrozen else { return }
        let zone = timeZone().identifier
        guard !links.isEmpty else {
            setSnapshot(nil)
            return
        }
        // All-day events were placed in the zone they were asked for.
        if let snapshot, snapshot.timezone != zone {
            setSnapshot(nil)
        }
        let ids = links.map(\.id)
        if let snapshot {
            let pruned = snapshot.pruned(at: now())
            if pruned != snapshot { setSnapshot(pruned) }
            let coversEveryLink = Set(pruned.statuses.map(\.link)) == Set(ids)
            if !force, coversEveryLink, now().timeIntervalSince(pruned.fetchedAt) < Self.refreshInterval {
                return
            }
        }
        if let retryNotBefore, now() < retryNotBefore { return }
        let fresh = force
        requestsSent += 1
        let number = requestsSent
        let answer: CalendarAnswer
        do {
            answer = try await api.calendarEvents(links: links.map(\.url), timezone: zone, fresh: fresh)
        } catch {
            // What is on screen stays; after a 429 nothing is asked again
            // until the delay has passed.
            if case .rateLimited(let seconds)? = error as? SeasignAPI.CalendarFailure { hold(seconds) }
            return
        }
        retryNotBefore = nil
        // A fresh answer shown since this scheduled request went out is
        // newer than this one.
        if !fresh, let freshShownAt, freshShownAt >= number { return }
        // The links or the zone may have changed while the request was in
        // flight; whatever changed them asks again.
        guard ids == links.map(\.id), zone == timeZone().identifier else { return }
        setSnapshot(.make(from: answer, links: ids, timezone: zone, previous: snapshot, now: now()))
        if fresh { freshShownAt = requestsSent }
    }

    /// Checks a link typed in Settings by asking the API to read it, and
    /// saves it. Throws an `AddProblem`, storing nothing.
    func add(name: String, link: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AddProblem.missingName }
        guard !url.isEmpty else { throw AddProblem.missingLink }
        try checkRoom(for: url)

        let zone = timeZone().identifier
        let answer: CalendarAnswer
        do {
            // Fresh: the link may have been cached by an earlier try.
            answer = try await api.calendarEvents(links: [url], timezone: zone, fresh: true)
        } catch SeasignAPI.CalendarFailure.rateLimited(let seconds) {
            hold(seconds)
            throw AddProblem.rateLimited
        } catch {
            throw AddProblem.unavailable
        }
        retryNotBefore = nil
        guard let status = answer.calendars.first(where: { $0.index == 0 }) else {
            throw AddProblem.unavailable
        }
        guard status.ok else {
            throw AddProblem.link(status.error ?? .fetchFailed)
        }
        // The list may have changed while the request was in flight.
        try checkRoom(for: url)

        let added = CalendarLink(name: name, url: url, createdAt: now())
        guard store.insert(added) else { throw AddProblem.notSaved }
        links = store.links()

        // Show the new calendar's events without asking a second time.
        let fresh = EventsSnapshot.make(from: answer, links: [added.id], timezone: zone, previous: nil, now: now())
        if zone == timeZone().identifier {
            if var merged = snapshot, merged.timezone == zone {
                merged.events = EventPicker.upcoming(merged.events + fresh.events, now: now())
                merged.statuses += fresh.statuses
                setSnapshot(merged)
            } else {
                setSnapshot(fresh)
            }
        }
        // A snapshot that lacks another link's status is refetched here.
        await refresh()
    }

    /// Removes a link and its events from Today at once, then refreshes.
    func remove(_ link: CalendarLink) async {
        let id = link.id
        guard store.delete(link) else { return }
        links = store.links()
        setSnapshot(links.isEmpty ? nil : snapshot?.removing(link: id))
        await refresh()
    }

    /// Our API's 429 asked to wait `seconds`: no refresh is sent before then.
    /// The day screen (`DayModel`) records its own 429s here too, so the
    /// delay holds for Today and for the day screen opened again.
    func hold(_ seconds: Int) {
        retryNotBefore = now().addingTimeInterval(TimeInterval(seconds))
    }

    private func checkRoom(for url: String) throws {
        guard links.count < Self.maxLinks else { throw AddProblem.limitReached }
        guard !links.contains(where: { $0.url == url }) else { throw AddProblem.alreadyAdded }
    }

    private func setSnapshot(_ value: EventsSnapshot?) {
        // Nothing is shown, so no fresh answer is newer than a scheduled one.
        if value == nil { freshShownAt = nil }
        guard value != snapshot else { return }
        snapshot = value
        store.cache(value)
    }
}

/// What on Today asks for the pasted-link events, and whether it asks with
/// `force` (`EventsModel.refresh(force:)`: sent even when the events are
/// fresh, and read again by the API instead of from its 5-minute cache).
/// Today passes each of its calls through here, so the choice is tested.
enum EventsRefreshTrigger: Equatable {
    /// The minute loop shared with the sky: a scheduled check, never forced.
    case minuteLoop
    /// The app came back to the foreground; `isDue` is `EventsModel.isDue`
    /// read as it did, before anything else is asked.
    case returnToForeground(isDue: Bool)
    /// The pull above the horizon.
    case pull
    /// The events' time zone changed (a zip saved or removed).
    case zoneChange

    var force: Bool {
        switch self {
        case .minuteLoop, .zoneChange: false
        case .returnToForeground(let isDue): isDue
        case .pull: true
        }
    }
}

#if DEBUG
extension EventsModel {
    /// Debug-only (`-debugEvents YES`): two sample links and three sample
    /// events for screenshots, held in a store that lives in memory. Nothing
    /// is fetched and the user's own store is not touched.
    static func sample(now: Date = Date(), timeZone: TimeZone = .current) throws -> EventsModel {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let family = CalendarLink(name: "Family", url: "https://calendar.example.com/sample/family.ics", createdAt: now)
        let work = CalendarLink(name: "Work", url: "webcal://cal.example.org/sample/work", createdAt: now.addingTimeInterval(1))
        context.insert(family)
        context.insert(work)
        try context.save()

        let model = EventsModel(context: context, timeZone: { timeZone }, now: { now })
        model.isFrozen = true

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // The next quarter hour, so the first event is never already over.
        let soon = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900 + 900)
        let tomorrow = calendar.startOfDay(for: now).addingTimeInterval(26 * 3600)
        let tomorrowStart = calendar.startOfDay(for: tomorrow)
        model.snapshot = EventsSnapshot(
            events: [
                UpcomingEvent(link: family.id, title: "Hanna's show", start: soon, end: soon.addingTimeInterval(3600), allDay: false),
                UpcomingEvent(link: work.id, title: "Submit work hours for stage", start: soon.addingTimeInterval(5400), end: soon.addingTimeInterval(7200), allDay: false),
                UpcomingEvent(
                    link: family.id,
                    title: "Brush pets teeth",
                    start: tomorrowStart,
                    end: tomorrowStart.addingTimeInterval(86400),
                    allDay: true,
                    date: SkySnapshot.localDateString(for: tomorrowStart, in: timeZone)
                ),
            ],
            statuses: [
                .init(link: family.id, status: LinkStatus(problem: nil, partial: true)),
                .init(link: work.id, status: LinkStatus(problem: .fetchFailed, partial: false)),
            ],
            timezone: timeZone.identifier,
            fetchedAt: now
        )
        return model
    }
}
extension EventLabel {
    /// The v12 mockup's four event titles (`design-ideas/v12-imago/`).
    static let mockupTitles = [
        "Hanna\u{2019}s Show", "Wearables and sensing demo", "Submit hours for studio payroll", "Night Workout",
    ]

    /// Debug-only (`-debugMockupEvents YES`): the four events of the v12
    /// mockup, 11:00 AM, 1:00 PM, 6:45 PM and 8:15 PM on the screen's day,
    /// worded for `now`, so Today can be set beside the mockup's stills at
    /// any debug time. `titles` replaces the titles and sets how many there
    /// are (up to four, in the same slots), for checking real-text cases.
    static func mockupSamples(
        now: Date, timeZone: TimeZone, clock: ClockStyle, titles: [String] = mockupTitles
    ) -> [EventLabel] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let link = UUID()
        let starts: [TimeInterval] = [11 * 3600, 13 * 3600, 18 * 3600 + 45 * 60, 20 * 3600 + 15 * 60]
        return zip(starts, titles).map { offset, title in
            let start = today.addingTimeInterval(offset)
            let event = UpcomingEvent(link: link, title: title, start: start, end: start.addingTimeInterval(3600), allDay: false)
            return EventLabel(event: event, now: now, timeZone: timeZone, clock: clock)
        }
    }
}
#endif
