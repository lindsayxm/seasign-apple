import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Seasign

/// Task 17, item 5: what happens when a store on disk will not open. Each test
/// works on real SQLite files in its own temporary directory.
@Suite(.serialized) @MainActor struct LocalStoreTests {
    private let directory: URL
    private let files: LocalStore.Files

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "LocalStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = LocalStore.Files(
            user: directory.appending(path: "default.store"),
            cache: directory.appending(path: "SkyCache.store")
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes one list item, a zip and a cached sky, then closes the stores.
    private func seed() throws {
        let opened = try LocalStore.open(files)
        #expect(opened.cache == .kept)
        let context = ModelContext(opened.container)
        context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
        context.insert(Settings(zip: "10001"))
        context.insert(CachedSky(zip: "10001", payload: Data("{}".utf8), fetchedAt: instant("2026-11-15T12:00:00Z")))
        try context.save()
    }

    private func titles(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<ListItem>()).map(\.title)
    }

    private func overwriteWithJunk(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        try Data(repeating: 0x5A, count: 8192).write(to: url)
    }

    @Test func opensAndKeepsDataAcrossLaunches() throws {
        defer { cleanUp() }
        try seed()
        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        let context = ModelContext(again.container)
        #expect(try titles(again.container) == ["Oat milk"])
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
    }

    /// A new install: not even the folder exists yet.
    @Test func firstLaunchCreatesTheFolderAndBothStores() throws {
        defer { cleanUp() }
        let folder = directory.appending(path: "Library/Application Support")
        let fresh = LocalStore.Files(
            user: folder.appending(path: "default.store"),
            cache: folder.appending(path: "SkyCache.store")
        )
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        let opened = try LocalStore.open(fresh)
        #expect(opened.cache == .kept)
        let context = ModelContext(opened.container)
        context.insert(ListItem(kind: .todo, title: "First", createdAt: .now))
        context.insert(CachedSky(zip: "10001", payload: Data(), fetchedAt: .now))
        try context.save()
        #expect(FileManager.default.fileExists(atPath: fresh.user.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fresh.cache.path(percentEncoded: false)))
    }

    /// Opening again the moment the last container is let go is what a quick
    /// relaunch, "Try again" and the recovery path itself do. A store that is
    /// still closing must never be taken for a broken one: that would delete
    /// the cache or show the error screen for nothing.
    @Test func reopeningStraightAfterClosingAlwaysWorks() throws {
        defer { cleanUp() }
        try seed()
        for round in 1...30 {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept, "round \(round)")
            let context = ModelContext(opened.container)
            context.insert(ListItem(kind: .todo, title: "Item \(round)", createdAt: .now))
            context.insert(CachedSky(zip: "\(round)", payload: Data(), fetchedAt: .now))
            try context.save()
        }
        let last = try LocalStore.open(files)
        #expect(last.cache == .kept)
        #expect(try titles(last.container).count == 31)
        #expect(try ModelContext(last.container).fetch(FetchDescriptor<CachedSky>()).count == 31)
    }

    /// Each model is in the file it is meant to be in: opening one file alone
    /// finds its own rows, and the cache file can go without the lists going too.
    @Test func modelsLandInTheirOwnFiles() throws {
        defer { cleanUp() }
        try seed()
        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try titles(userOnly) == ["Oat milk"])
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<Settings>()).count == 1)

        let cacheOnly = try ModelContainer(
            for: Schema(SeasignSchema.cacheModels),
            configurations: [ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache)]
        )
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<CachedSky>()).count == 1)
    }

    @Test func aBrokenCacheIsReplacedAndTheListsSurvive() throws {
        defer { cleanUp() }
        try seed()
        try overwriteWithJunk(files.cache)

        let opened = try LocalStore.open(files)
        #expect(opened.cache == .recreated)
        #expect(try titles(opened.container) == ["Oat milk"])
        let context = ModelContext(opened.container)
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).isEmpty)
        // The new cache works.
        context.insert(CachedSky(zip: "10001", payload: Data(), fetchedAt: .now))
        try context.save()
    }

    /// Every table, index and trigger of a store file with its SQL, the
    /// store's Core Data metadata row, and SQLite's schema counter, read with
    /// SQLite directly. The counter goes up on every schema change, so it also
    /// shows a table that was dropped and then created again.
    private func schemaDump(_ url: URL) throws -> [String] {
        var db: OpaquePointer?
        let opening = sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opening == SQLITE_OK else { throw SQLiteFailure(db, opening, "open") }
        // A container that has just been let go may still be closing its
        // connection, and SQLite's last close folds the write-ahead log in
        // under a lock. Core Data's own connections wait for such locks; a
        // plain connection does not unless told to, and fails at once with
        // SQLITE_BUSY (seen in half the runs on iOS 27.2, never on 18.3).
        sqlite3_busy_timeout(db, 10_000)
        var rows: [String] = []
        for query in [
            "SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master ORDER BY type, name",
            "SELECT 'schema_version ' || schema_version FROM pragma_schema_version",
            "SELECT 'metadata ' || Z_VERSION || ' ' || Z_UUID || ' ' || hex(Z_PLIST) FROM Z_METADATA",
        ] {
            var statement: OpaquePointer?
            let preparing = sqlite3_prepare_v2(db, query, -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            guard preparing == SQLITE_OK else { throw SQLiteFailure(db, preparing, "prepare \(query.prefix(30))") }
            var stepping = sqlite3_step(statement)
            while stepping == SQLITE_ROW {
                rows.append(String(cString: sqlite3_column_text(statement, 0)))
                stepping = sqlite3_step(statement)
            }
            guard stepping == SQLITE_DONE else { throw SQLiteFailure(db, stepping, "step \(query.prefix(30))") }
        }
        return rows
    }

    /// What SQLite said, so a failure of the helper is not mistaken for one of the store.
    private struct SQLiteFailure: Error, CustomStringConvertible {
        var description: String
        init(_ db: OpaquePointer?, _ code: Int32, _ stage: String) {
            description = "SQLite \(stage): code \(code), extended \(sqlite3_extended_errcode(db)), \(String(cString: sqlite3_errmsg(db)))"
        }
    }

    /// Review of task 17: recovering the cache must not migrate the user
    /// store. Opening it with a schema that lacks `CachedSky` would make Core
    /// Data treat the model as removed and rewrite the file's schema.
    @Test func cacheRecoveryDoesNotChangeTheUserStoreSchema() throws {
        defer { cleanUp() }
        try seed()
        let before = try schemaDump(files.user)
        #expect(before.contains { $0.contains("ZLISTITEM") })
        try overwriteWithJunk(files.cache)

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .recreated)
            #expect(try titles(opened.container) == ["Oat milk"])
        }
        #expect(try schemaDump(files.user) == before)
    }

    /// The same for a store written by a build from before the split, which
    /// still has the old cache table in `default.store`.
    @Test func cacheRecoveryLeavesAnEarlierSingleStoreAsItWas() throws {
        defer { cleanUp() }
        do {
            let schema = Schema(SeasignSchema.models)
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: files.user)])
            let context = ModelContext(old)
            context.insert(ListItem(kind: .todo, title: "Call the vet", createdAt: instant("2026-11-14T12:00:00Z")))
            try context.save()
        }
        // First launch of the split build, which may bring the file up to date.
        do { _ = try LocalStore.open(files) }
        let before = try schemaDump(files.user)
        try overwriteWithJunk(files.cache)

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .recreated)
            #expect(try titles(opened.container) == ["Call the vet"])
        }
        #expect(try schemaDump(files.user) == before)
    }

    /// When no cache file can be made at all, the app still starts: the user
    /// store is healthy, so this is not the error screen's case.
    @Test func aCacheThatCannotBeCreatedLivesInMemory() throws {
        defer { cleanUp() }
        try seed()
        // A plain file where the cache's folder should be.
        let blocker = directory.appending(path: "blocker")
        try Data("x".utf8).write(to: blocker)
        let blocked = LocalStore.Files(user: files.user, cache: blocker.appending(path: "SkyCache.store"))

        let opened = try LocalStore.open(blocked)
        #expect(opened.cache == .inMemory)
        #expect(try titles(opened.container) == ["Oat milk"])
        let context = ModelContext(opened.container)
        context.insert(CachedSky(zip: "10001", payload: Data(), fetchedAt: .now))
        context.insert(ListItem(kind: .get, title: "Bread", createdAt: .now))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).count == 1)
        // The list item went to disk, not into the in-memory store.
        #expect(try titles(try LocalStore.open(files).container).sorted() == ["Bread", "Oat milk"])
    }

    @Test func aBrokenUserStoreIsReportedAndLeftAlone() throws {
        defer { cleanUp() }
        try seed()
        try overwriteWithJunk(files.user)
        let before = try Data(contentsOf: files.user)

        #expect(throws: LocalStore.UserStoreUnreadable.self) {
            _ = try LocalStore.open(files)
        }
        // Not deleted, not rewritten.
        #expect(try Data(contentsOf: files.user) == before)
        // The cache is not thrown away either. (Its bytes are not compared:
        // merely opening a healthy SQLite file may fold its write-ahead log in.)
        let cacheOnly = try ModelContainer(
            for: Schema(SeasignSchema.cacheModels),
            configurations: [ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache)]
        )
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
    }

    /// Builds made before the split kept all three models in `default.store`.
    @Test func aSingleStoreFromAnEarlierBuildKeepsItsLists() throws {
        defer { cleanUp() }
        do {
            let schema = Schema(SeasignSchema.models)
            let old = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: files.user)]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .todo, title: "Call the vet", createdAt: instant("2026-11-14T12:00:00Z")))
            context.insert(Settings(zip: "94103"))
            context.insert(CachedSky(zip: "94103", payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        let opened = try LocalStore.open(files)
        #expect(opened.cache == .kept)
        #expect(try titles(opened.container) == ["Call the vet"])
        let context = ModelContext(opened.container)
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["94103"])
        // The old cached sky is not carried over; the next refresh fetches one.
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).isEmpty)
    }
}
