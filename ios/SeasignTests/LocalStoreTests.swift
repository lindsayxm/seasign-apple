import Foundation
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
