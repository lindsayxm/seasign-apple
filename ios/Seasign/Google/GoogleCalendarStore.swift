import Foundation
import SwiftData

/// Whether a Google account is connected, kept in the user store so that
/// "Connect again" survives a relaunch after the refresh token was dropped.
/// One row at most; no row means never connected. It holds no token and no
/// account detail: the refresh token lives in the Keychain only.
@Model
final class GoogleAccount {
    /// A `GoogleConnection` raw value.
    var stateRaw: String

    init(stateRaw: String) {
        self.stateRaw = stateRaw
    }
}

/// One calendar on the connected Google account's calendar list, and
/// whether its events are shown on Today. `id` is the app's own, and is what
/// events point to (`UpcomingEvent.link`), as with `CalendarLink.id`.
@Model
final class GoogleCalendarChoice {
    var id: UUID
    /// Google's calendar id ("primary" calendars use the account's address).
    var calendarID: String
    /// The user's name for the calendar in Google Calendar; may be empty.
    var name: String
    var isPrimary: Bool
    var isOn: Bool
    /// Position in Google's list (primary first).
    var order: Int

    init(id: UUID = UUID(), calendarID: String, name: String, isPrimary: Bool, isOn: Bool, order: Int) {
        self.id = id
        self.calendarID = calendarID
        self.name = name
        self.isPrimary = isPrimary
        self.isOn = isOn
        self.order = order
    }

    /// The name to show: the calendar's own, else its id.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? calendarID : trimmed
    }
}

/// The last `POST /v1/google/events` answer, so Today can show Google events
/// at launch before the network answers. At most one row. It holds no token.
@Model
final class CachedGoogleEvents {
    /// A JSON-encoded `GoogleEventsSnapshot`.
    var payload: Data
    var fetchedAt: Date

    init(payload: Data, fetchedAt: Date) {
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

/// The state of the Google connection.
enum GoogleConnection: String, Sendable, Equatable {
    case notConnected = "not_connected"
    case connected
    /// Google no longer takes the sign-in (`invalid_grant`: revoked, or the
    /// 7-day limit of an app in test mode) or it is gone from the Keychain.
    case expired
    /// Google refused the calendar list: the sign-in lacks a scope.
    case missingScope = "missing_scope"
}

/// Why one Google calendar could not be read; the API's per-calendar codes.
enum GoogleCalendarProblem: String, Codable, CaseIterable, Sendable {
    case forbidden
    case notFound = "not_found"
    case rateLimited = "rate_limited"
    case fetchFailed = "fetch_failed"
    case timeout
    case tooLarge = "too_large"

    /// Shown in Settings under the calendar.
    var message: String {
        switch self {
        case .forbidden:
            "Google didn't let Seasign read this calendar."
        case .notFound:
            "Google can't find this calendar any more."
        case .rateLimited:
            "Google is busy. Seasign will try again shortly."
        case .fetchFailed:
            "This calendar couldn't be read just now."
        case .timeout:
            "This calendar took too long to answer."
        case .tooLarge:
            "This calendar has too many events to read."
        }
    }

    /// A failure that may pass by itself, so events read earlier stay.
    var isTransient: Bool {
        self == .rateLimited || self == .fetchFailed || self == .timeout
    }
}

/// The app's copy of the last Google events answer, which the cache holds.
/// Events point to `GoogleCalendarChoice.id`, never to Google's ids.
struct GoogleEventsSnapshot: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var calendar: UUID
        var problem: GoogleCalendarProblem?
        var partial: Bool
    }

    var events: [UpcomingEvent]
    var statuses: [Entry]
    /// The time zone the request was made for.
    var timezone: String
    var fetchedAt: Date

    func status(for calendar: UUID) -> Entry? {
        statuses.first { $0.calendar == calendar }
    }

    /// Equal apart from when it was fetched: a poll that changes nothing
    /// neither writes the cache nor redraws Today.
    func sameContent(as other: GoogleEventsSnapshot?) -> Bool {
        guard let other else { return false }
        return events == other.events && statuses == other.statuses && timezone == other.timezone
    }

    /// An answer as a snapshot. `calendars` are the choices' ids in the
    /// order their Google ids were sent. Events of a calendar that failed in
    /// a passing way (rate limited, unreachable, timed out) are carried over
    /// from `previous`; a calendar that is forbidden or gone loses them.
    static func make(
        from answer: GoogleEventsAnswer,
        calendars: [UUID],
        timezone: String,
        previous: GoogleEventsSnapshot?,
        now: Date
    ) -> GoogleEventsSnapshot {
        var events: [UpcomingEvent] = answer.events.compactMap { event in
            guard calendars.indices.contains(event.calendar) else { return nil }
            return UpcomingEvent(
                link: calendars[event.calendar],
                title: event.title,
                start: event.start,
                end: event.end,
                allDay: event.allDay,
                date: event.date
            )
        }
        var statuses: [Entry] = []
        for (index, calendar) in calendars.enumerated() {
            guard let status = answer.calendars.first(where: { $0.index == index }) else {
                statuses.append(Entry(calendar: calendar, problem: .fetchFailed, partial: false))
                continue
            }
            let problem = status.ok ? nil : (status.error ?? .fetchFailed)
            statuses.append(Entry(calendar: calendar, problem: problem, partial: status.ok && status.partial))
        }
        if let previous, previous.timezone == timezone {
            let carried = Set(statuses.filter { $0.problem?.isTransient == true }.map(\.calendar))
            events += previous.events.filter { carried.contains($0.link) }
        }
        return GoogleEventsSnapshot(
            events: EventPicker.upcoming(events, now: now),
            statuses: statuses,
            timezone: timezone,
            fetchedAt: now
        )
    }

    /// Only what belongs to `calendars`.
    func keeping(_ calendars: Set<UUID>) -> GoogleEventsSnapshot {
        var copy = self
        copy.events.removeAll { !calendars.contains($0.link) }
        copy.statuses.removeAll { !calendars.contains($0.calendar) }
        return copy
    }

    /// Without the events that have ended.
    func pruned(at now: Date) -> GoogleEventsSnapshot {
        var copy = self
        copy.events = EventPicker.upcoming(events, now: now)
        return copy
    }
}

/// How a fresh calendar list is folded into the stored choices: calendars
/// already known keep their id and their on/off; new ones start off, except
/// the primary calendar when nothing was chosen before; calendars no longer
/// on the list are dropped. At most `limit` stay on.
enum GoogleCalendarMerge {
    struct Row: Equatable, Sendable {
        var id: UUID
        var entry: GoogleCalendarEntry
        var isOn: Bool
    }

    static func merge(
        existing: [(id: UUID, calendarID: String, isOn: Bool)],
        fetched: [GoogleCalendarEntry],
        limit: Int = GoogleCalendarModel.maxCalendars,
        newID: () -> UUID = { UUID() }
    ) -> [Row] {
        let known = Dictionary(existing.map { ($0.calendarID, ($0.id, $0.isOn)) }, uniquingKeysWith: { first, _ in first })
        let nothingChosen = !existing.contains { $0.isOn }
        var onCount = 0
        var seen = Set<String>()
        var rows: [Row] = []
        for entry in fetched where seen.insert(entry.id).inserted {
            let previous = known[entry.id]
            var isOn = previous?.1 ?? (nothingChosen && entry.primary)
            if isOn {
                if onCount >= limit { isOn = false } else { onCount += 1 }
            }
            rows.append(Row(id: previous?.0 ?? newID(), entry: entry, isOn: isOn))
        }
        return rows
    }
}

/// Reads and writes the Google connection state and calendar choices (user
/// store) and the cached Google events (cache store) in SwiftData.
@MainActor
struct GoogleCalendarStore {
    let context: ModelContext

    var connection: GoogleConnection {
        guard let row = try? context.fetch(FetchDescriptor<GoogleAccount>()).first else { return .notConnected }
        return GoogleConnection(rawValue: row.stateRaw) ?? .notConnected
    }

    func setConnection(_ state: GoogleConnection) {
        let rows = (try? context.fetch(FetchDescriptor<GoogleAccount>())) ?? []
        for row in rows { context.delete(row) }
        if state != .notConnected {
            context.insert(GoogleAccount(stateRaw: state.rawValue))
        }
        save()
    }

    /// The calendars in Google's order.
    func choices() -> [GoogleCalendarChoice] {
        let all = (try? context.fetch(FetchDescriptor<GoogleCalendarChoice>())) ?? []
        return all.sorted { ($0.order, $0.calendarID) < ($1.order, $1.calendarID) }
    }

    /// Replaces the stored calendars with `rows`, keeping the rows of
    /// calendars that are still there.
    func replaceChoices(with rows: [GoogleCalendarMerge.Row]) {
        let current = choices()
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keep = Set(rows.map(\.id))
        for choice in current where !keep.contains(choice.id) {
            context.delete(choice)
        }
        for (order, row) in rows.enumerated() {
            if let choice = byID[row.id] {
                choice.calendarID = row.entry.id
                choice.name = row.entry.name
                choice.isPrimary = row.entry.primary
                choice.isOn = row.isOn
                choice.order = order
            } else {
                context.insert(GoogleCalendarChoice(
                    id: row.id, calendarID: row.entry.id, name: row.entry.name,
                    isPrimary: row.entry.primary, isOn: row.isOn, order: order
                ))
            }
        }
        save()
    }

    @discardableResult
    func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    func deleteChoices() {
        for choice in (try? context.fetch(FetchDescriptor<GoogleCalendarChoice>())) ?? [] {
            context.delete(choice)
        }
        save()
    }

    func cachedEvents() -> GoogleEventsSnapshot? {
        guard let row = try? context.fetch(FetchDescriptor<CachedGoogleEvents>()).first else { return nil }
        return try? JSONDecoder().decode(GoogleEventsSnapshot.self, from: row.payload)
    }

    func cache(_ snapshot: GoogleEventsSnapshot?) {
        for cached in (try? context.fetch(FetchDescriptor<CachedGoogleEvents>())) ?? [] {
            context.delete(cached)
        }
        if let snapshot, let payload = try? JSONEncoder().encode(snapshot) {
            context.insert(CachedGoogleEvents(payload: payload, fetchedAt: snapshot.fetchedAt))
        }
        save()
    }
}
