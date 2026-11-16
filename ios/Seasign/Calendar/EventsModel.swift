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
            case .notSaved:
                "That calendar couldn't be saved on this phone. Try again."
            }
        }
    }

    /// The API takes at most this many links in one request.
    nonisolated static let maxLinks = 10

    /// Events younger than this are not fetched again. The API caches each
    /// calendar for 15 minutes, so asking more often returns the same data.
    static let refreshInterval: TimeInterval = 10 * 60

    /// The user's links, oldest first.
    private(set) var links: [CalendarLink] = []
    /// The latest events, from the cache or the network.
    private(set) var snapshot: EventsSnapshot?

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let store: EventsStore
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Set for the DEBUG sample: nothing is fetched and nothing is dropped.
    @ObservationIgnored private var isFrozen = false

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

    /// The next events for Today at `now`, in the events' time zone. Empty
    /// while the cached events belong to another time zone.
    func labels(now: Date, limit: Int = 3) -> [EventLabel] {
        let zone = timeZone()
        guard let snapshot, isFrozen || snapshot.timezone == zone.identifier else { return [] }
        return EventPicker.next(snapshot.events, now: now, limit: limit).map {
            EventLabel(event: $0, now: now, timeZone: zone)
        }
    }

    /// How the last read of `link` went; nil if it has not been read yet.
    func status(for link: CalendarLink) -> LinkStatus? {
        snapshot?.status(for: link.id)
    }

    /// Fetches the events of every link unless the current ones are fresh. If
    /// the request fails as a whole, what is on screen stays.
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
        guard let answer = try? await api.calendarEvents(links: links.map(\.url), timezone: zone) else {
            return
        }
        // The links or the zone may have changed while the request was in
        // flight; whatever changed them asks again.
        guard ids == links.map(\.id), zone == timeZone().identifier else { return }
        setSnapshot(.make(from: answer, links: ids, timezone: zone, previous: snapshot, now: now()))
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
            answer = try await api.calendarEvents(links: [url], timezone: zone)
        } catch {
            throw AddProblem.unavailable
        }
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

    private func checkRoom(for url: String) throws {
        guard links.count < Self.maxLinks else { throw AddProblem.limitReached }
        guard !links.contains(where: { $0.url == url }) else { throw AddProblem.alreadyAdded }
    }

    private func setSnapshot(_ value: EventsSnapshot?) {
        guard value != snapshot else { return }
        snapshot = value
        store.cache(value)
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
#endif
