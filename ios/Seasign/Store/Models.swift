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

/// The SwiftData models of the app, in one place for the container and tests.
enum SeasignSchema {
    static let models: [any PersistentModel.Type] = [Settings.self, CachedSky.self]

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
