import Foundation
import SwiftData

/// Opens the app's stores on disk and recovers when one of them will not open.
///
/// There are two SQLite files in one `ModelContainer`:
///
/// - the **user store** (`default.store`): `SeasignSchema.userModels`
///   (`Settings`, `ListItem`, `CalendarLink`, `Site`, `SavedItem`). It holds
///   things the user typed and nothing can bring them back, so the app never
///   deletes or moves this file and never opens it with anything but the full
///   schema, which would change its tables. If it will not open, `open` throws
///   and the app shows `StoreErrorView`.
/// - the **cache store** (`SkyCache.store`): `SeasignSchema.cacheModels`
///   (`CachedSky`, `CachedEvents`, `FeedItem`, `CachedFeedState`), copies of
///   API responses. If the container will not open and the user store is
///   healthy, this file is deleted and made again; the next refresh refills it.
///
/// The two are separate files because a store that will not open cannot be
/// cleaned up one model at a time: the only thing left to do with it is delete
/// the file, and that is acceptable for the cache alone.
enum LocalStore {
    struct Files: Equatable, Sendable {
        var user: URL
        var cache: URL

        /// In Application Support. `default.store` is where SwiftData put the
        /// single store this app had before the split, so lists made with an
        /// earlier build are still there.
        static var standard: Files {
            let directory = URL.applicationSupportDirectory
            return Files(
                user: directory.appending(path: "default.store"),
                cache: directory.appending(path: "SkyCache.store")
            )
        }
    }

    /// What happened to the cache store while opening.
    enum CacheState: Equatable, Sendable {
        /// Opened as it was.
        case kept
        /// Would not open; deleted and created empty.
        case recreated
        /// Could not be created on disk either; the cache lives in memory for this launch.
        case inMemory
    }

    struct Opened {
        var container: ModelContainer
        var cache: CacheState
    }

    /// The user store would not open. Nothing was deleted.
    struct UserStoreUnreadable: Error {
        var underlying: any Error
    }

    static func open(_ files: Files = .standard) throws(UserStoreUnreadable) -> Opened {
        let manager = FileManager.default
        for url in [files.user, files.cache] {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        if let container = try? container(files, cacheInMemory: false) {
            return Opened(container: container, cache: .kept)
        }

        // Something will not open. Find out whether it is the user store by
        // opening it with the cache kept in memory. The schema is the same full
        // one as always: opening the user file with fewer models would make
        // Core Data migrate it (it would drop the tables of the missing models).
        let withoutCacheFile: ModelContainer
        do {
            withoutCacheFile = try container(files, cacheInMemory: true)
        } catch {
            // The user store is the only file this attempt touched. Stop here
            // and change nothing.
            throw UserStoreUnreadable(underlying: error)
        }

        // The user store is fine, so the cache file is the problem.
        removeCache(files)
        if let container = try? container(files, cacheInMemory: false) {
            return Opened(container: container, cache: .recreated)
        }
        // No cache file can be made (a full disk, say). The container that
        // already opened serves for this launch.
        return Opened(container: withoutCacheFile, cache: .inMemory)
    }

    private static func userConfiguration(_ files: Files) -> ModelConfiguration {
        ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)
    }

    private static func container(_ files: Files, cacheInMemory: Bool) throws -> ModelContainer {
        let cacheSchema = Schema(SeasignSchema.cacheModels)
        let cache = cacheInMemory
            ? ModelConfiguration("cache", schema: cacheSchema, isStoredInMemoryOnly: true)
            : ModelConfiguration("cache", schema: cacheSchema, url: files.cache)
        return try ModelContainer(
            for: Schema(SeasignSchema.models),
            configurations: [userConfiguration(files), cache]
        )
    }

    /// Deletes the cache store and SQLite's two side files. Only ever called
    /// with the cache store's URL.
    private static func removeCache(_ files: Files) {
        let path = files.cache.path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
