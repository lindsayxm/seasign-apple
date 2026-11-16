import Foundation
import SwiftData

/// The user's settings. There is one row; `SkyStore.settings()` creates it on
/// first use. Later tasks add fields (AI mode, interests, daily cap, provider).
@Model
final class Settings {
    /// The 5-digit US zip the Today scene follows; nil until the user sets one.
    var zip: String?

    init(zip: String? = nil) {
        self.zip = zip
    }
}

/// The last `GET /v1/sky` response for the user's zip, so Today can draw at
/// launch before the network answers. At most one row is kept.
@Model
final class CachedSky {
    var zip: String
    /// A JSON-encoded `SkySnapshot`.
    var payload: Data
    var fetchedAt: Date

    init(zip: String, payload: Data, fetchedAt: Date) {
        self.zip = zip
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

/// The last `POST /v1/calendar/events` response, so Today can show events at
/// launch before the network answers. At most one row is kept. It holds no
/// calendar link: events are tied to `CalendarLink.id`.
@Model
final class CachedEvents {
    /// A JSON-encoded `EventsSnapshot`.
    var payload: Data
    var fetchedAt: Date

    init(payload: Data, fetchedAt: Date) {
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

/// The SwiftData models of the app, in one place for the container and tests.
///
/// They are kept in two store files (see `LocalStore`), split by what losing
/// them would mean. A new model goes into `cacheModels` only if everything in
/// it can be fetched again; anything the user typed belongs in `userModels`.
enum SeasignSchema {
    /// What the user entered: settings, the Do/Get lists and the calendar
    /// links. Never deleted by the app.
    static let userModels: [any PersistentModel.Type] = [Settings.self, ListItem.self, CalendarLink.self]
    /// Copies of what the API returned. Safe to throw away.
    static let cacheModels: [any PersistentModel.Type] = [CachedSky.self, CachedEvents.self]
    static let models: [any PersistentModel.Type] = userModels + cacheModels

    /// A container that lives only in memory, for tests and previews.
    /// The stores on disk are opened by `LocalStore.open`.
    static func inMemoryContainer() throws -> ModelContainer {
        // Each in-memory store gets its own name so that containers never share one.
        let id = UUID().uuidString
        return try ModelContainer(
            for: Schema(models),
            configurations: [
                ModelConfiguration("user-\(id)", schema: Schema(userModels), isStoredInMemoryOnly: true),
                ModelConfiguration("cache-\(id)", schema: Schema(cacheModels), isStoredInMemoryOnly: true),
            ]
        )
    }
}
