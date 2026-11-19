import Foundation
import SwiftData

/// The user's settings. There is one row; `SkyStore.settings()` creates it on
/// first use.
///
/// Every field added after the first release is optional, with nil meaning
/// the default, so a store written by an earlier build opens by lightweight
/// migration with nothing lost (`LocalStoreTests`). The AI search key is not
/// here: it lives only in the Keychain (`APIKeyStore`).
@Model
final class Settings {
    /// The 5-digit US zip the Today scene follows. A fresh install starts with
    /// `SkyStore.defaultZip`; nil only after the user removes it.
    var zip: String?
    /// An `AIMode` raw value; nil is Use My List.
    var aiModeRaw: String?
    /// An `AIProvider` raw value; nil is `AIProvider.default`.
    var aiProviderRaw: String?
    /// The interests exactly as typed; `InterestList.parse` reads them.
    var aiInterestsText: String?
    /// Searches allowed per day; nil is `DailyCap.default`.
    var aiDailyCap: Int?
    /// When the last search was sent, for spacing automatic searches.
    var aiLastSentAt: Date?
    /// True after the provider refused the key: automatic searches stop
    /// until the key or provider changes.
    var aiKeyRefused: Bool?
    /// An `AISearchProblem` raw value: how the last search went wrong.
    var aiLastProblemRaw: String?

    init(zip: String? = nil) {
        self.zip = zip
    }
}

/// How many AI searches were sent on one local calendar day (`SearchDay.key`,
/// in the zip's time zone when known, else the phone's). Lives in the user
/// store: losing it would let the day's cap be spent again.
@Model
final class SearchCount {
    /// "2026-11-16".
    var day: String
    var count: Int

    init(day: String, count: Int) {
        self.day = day
        self.count = count
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
    /// What the user entered: settings, the Do/Get lists, the calendar links,
    /// the followed sites, the saved articles with their notes, the day's AI
    /// search count, and the Google connection state with the chosen Google
    /// calendars (deleted only when the user disconnects Google). Never
    /// deleted by the app otherwise.
    static let userModels: [any PersistentModel.Type] = [
        Settings.self, ListItem.self, CalendarLink.self, Site.self, SavedItem.self, SearchCount.self,
        GoogleAccount.self, GoogleCalendarChoice.self,
    ]
    /// Copies of what the API returned. Safe to throw away.
    static let cacheModels: [any PersistentModel.Type] = [
        CachedSky.self, CachedEvents.self, FeedItem.self, CachedFeedState.self, CachedGoogleEvents.self,
    ]
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
