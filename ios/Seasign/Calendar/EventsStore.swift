import Foundation
import SwiftData

/// Reads and writes the calendar links (user store) and the cached events
/// (cache store) in SwiftData.
@MainActor
struct EventsStore {
    let context: ModelContext

    /// The links in the order they were added.
    func links() -> [CalendarLink] {
        let all = (try? context.fetch(FetchDescriptor<CalendarLink>())) ?? []
        return all.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }

    /// Saves a new link. Returns false, with nothing stored, if it could not be written.
    func insert(_ link: CalendarLink) -> Bool {
        context.insert(link)
        return save()
    }

    /// Deletes a link. Returns false, with the link still stored, if that could not be written.
    func delete(_ link: CalendarLink) -> Bool {
        context.delete(link)
        return save()
    }

    /// The cached events, if there are any and they still decode.
    func cachedEvents() -> EventsSnapshot? {
        guard let row = try? context.fetch(FetchDescriptor<CachedEvents>()).first else { return nil }
        return try? JSONDecoder().decode(EventsSnapshot.self, from: row.payload)
    }

    /// Replaces the cache with `snapshot`, or empties it when nil.
    func cache(_ snapshot: EventsSnapshot?) {
        for cached in (try? context.fetch(FetchDescriptor<CachedEvents>())) ?? [] {
            context.delete(cached)
        }
        if let snapshot, let payload = try? JSONEncoder().encode(snapshot) {
            context.insert(CachedEvents(payload: payload, fetchedAt: snapshot.fetchedAt))
        }
        _ = save()
    }

    private func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            // Keep memory and the store in step: drop what could not be written.
            context.rollback()
            return false
        }
    }
}
