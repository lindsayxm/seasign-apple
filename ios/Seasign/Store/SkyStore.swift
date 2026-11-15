import Foundation
import SwiftData

/// Reads and writes the zip setting and the cached sky in SwiftData.
@MainActor
struct SkyStore {
    let context: ModelContext

    /// The single settings row, created if it does not exist yet.
    func settings() -> Settings {
        if let existing = try? context.fetch(FetchDescriptor<Settings>()).first {
            return existing
        }
        let created = Settings()
        context.insert(created)
        try? context.save()
        return created
    }

    var zip: String? {
        settings().zip
    }

    /// Stores a new zip and drops any cached sky that belongs to another one.
    func setZip(_ zip: String?) {
        settings().zip = zip
        for cached in (try? context.fetch(FetchDescriptor<CachedSky>())) ?? [] where cached.zip != zip {
            context.delete(cached)
        }
        try? context.save()
    }

    /// The cached sky for `zip`, if there is one and it still decodes.
    func cachedSky(for zip: String) -> SkySnapshot? {
        let rows = (try? context.fetch(FetchDescriptor<CachedSky>())) ?? []
        guard let row = rows.first(where: { $0.zip == zip }) else { return nil }
        return try? JSONDecoder().decode(SkySnapshot.self, from: row.payload)
    }

    /// Replaces the cache with `snapshot`.
    func cache(_ snapshot: SkySnapshot) {
        guard let payload = try? JSONEncoder().encode(snapshot) else { return }
        for cached in (try? context.fetch(FetchDescriptor<CachedSky>())) ?? [] {
            context.delete(cached)
        }
        context.insert(CachedSky(zip: snapshot.zip, payload: payload, fetchedAt: snapshot.fetchedAt))
        try? context.save()
    }
}
