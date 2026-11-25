import Foundation
import SwiftData
import Testing

@testable import Seasign

/// Task 218: what a fresh install starts with. The three starter sites and
/// the two list items are written once, when the user store is first
/// created on disk (`LocalStore.Opened.userStoreIsNew`), and never again: not
/// after the person removes them, and never into a store that already exists
/// (an install from before this build, even with no sites and empty lists).
/// Each test works on real SQLite files in its own temporary directory.
@Suite(.serialized) @MainActor struct StarterContentTests {
    private let directory: URL
    private let files: LocalStore.Files
    private let seededAt = instant("2026-11-24T12:00:00Z")

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "StarterContentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = LocalStore.Files(
            user: directory.appending(path: "Library/Application Support/default.store"),
            cache: directory.appending(path: "Library/Application Support/SkyCache.store")
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One launch: open the stores the way the app does.
    private func launch() throws -> ModelContext {
        ModelContext(try StarterContent.open(files, now: seededAt).container)
    }

    private func sites(_ context: ModelContext) -> [Site] {
        FeedStore(context: context).sites()
    }

    private func listItems(_ context: ModelContext) throws -> [(String, String, Bool)] {
        try context.fetch(FetchDescriptor<ListItem>())
            .sorted { $0.createdAt < $1.createdAt }
            .map { ($0.kindRaw, $0.title, $0.isDone) }
    }

    // MARK: Fresh install

    @Test func aFreshStoreStartsWithTheThreeSitesAndTwoItems() throws {
        defer { cleanUp() }
        let context = try launch()

        let followed = sites(context)
        #expect(followed.map(\.url) == [
            "https://news.ycombinator.com/",
            "https://www.wired.com/category/science/",
            "https://arstechnica.com/space/",
        ])
        #expect(followed.map(\.mode) == [.feed, .feed, .feed])
        #expect(followed.map(\.feedUrl) == [
            "https://news.ycombinator.com/rss",
            "https://www.wired.com/feed/category/science/latest/rss",
            "https://arstechnica.com/space/feed/",
        ])
        // The user's names for the three sites.
        #expect(followed.map(\.title) == ["Hacker News", "Wired Science", "Ars Technica Space"])
        #expect(followed.map(\.category) == ["Tech", "Science", "Space"])
        #expect(Set(followed.map(\.id)).count == 3)

        let items = try listItems(context)
        #expect(items.map(\.0) == ["do", "get"])
        #expect(items.map(\.1) == ["Go outside", "Concert tickets"])
        #expect(items.map(\.2) == [false, false])
    }

    /// The models the app builds at launch see the seeds straight away.
    @Test func theFeedAndListsSeeTheSeedsAtLaunch() throws {
        defer { cleanUp() }
        let context = try launch()
        let feed = FeedModel(context: context)
        #expect(feed.sites.count == 3)
        let lists = ListsModel(context: context)
        #expect(lists.items(.todo).map(\.title) == ["Go outside"])
        #expect(lists.items(.get).map(\.title) == ["Concert tickets"])
    }

    @Test func aSecondLaunchAddsNothing() throws {
        defer { cleanUp() }
        _ = try launch()
        let again = try launch()
        #expect(sites(again).count == 3)
        #expect(try listItems(again).count == 2)
    }

    /// Removed through the app's own paths, they stay removed.
    @Test func removedSeedsAreNeverPutBack() throws {
        defer { cleanUp() }
        do {
            let context = try launch()
            let feed = FeedModel(context: context)
            for site in feed.sites { feed.remove(site) }
            let lists = ListsModel(context: context)
            for item in lists.items { lists.delete(item) }
            #expect(feed.sites.isEmpty)
            #expect(lists.items.isEmpty)
        }
        let again = try launch()
        #expect(sites(again).isEmpty)
        #expect(try listItems(again).isEmpty)
        let third = try launch()
        #expect(sites(third).isEmpty)
        #expect(try listItems(third).isEmpty)
    }

    /// One seed removed, the others kept: only what is left comes back.
    @Test func removingOneSeedLeavesTheOthers() throws {
        defer { cleanUp() }
        do {
            let context = try launch()
            let feed = FeedModel(context: context)
            feed.remove(try #require(feed.sites.first))
            let lists = ListsModel(context: context)
            lists.delete(try #require(lists.items(.get).first))
        }
        let again = try launch()
        #expect(sites(again).map(\.title) == ["Wired Science", "Ars Technica Space"])
        #expect(try listItems(again).map(\.1) == ["Go outside"])
    }

    // MARK: Existing installs

    /// A store an earlier build created, with no sites and empty lists, is
    /// an existing install: nothing is added to it.
    @Test func anExistingEmptyStoreIsNotSeeded() throws {
        defer { cleanUp() }
        do {
            let opened = try LocalStore.open(files)
            #expect(opened.userStoreIsNew)
            let context = ModelContext(opened.container)
            context.insert(Settings(zip: "10001"))
            try context.save()
        }
        let context = try launch()
        #expect(sites(context).isEmpty)
        #expect(try listItems(context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
    }

    /// Even a store file with nothing in it at all.
    @Test func anExistingStoreWithNothingInItIsNotSeeded() throws {
        defer { cleanUp() }
        _ = try LocalStore.open(files)
        let context = try launch()
        #expect(sites(context).isEmpty)
        #expect(try listItems(context).isEmpty)
    }

    /// An existing install keeps exactly what it had: its own sites and items,
    /// nothing added beside them.
    @Test func anExistingStoreWithItsOwnContentIsLeftAsItWas() throws {
        defer { cleanUp() }
        do {
            let context = ModelContext(try LocalStore.open(files).container)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: seededAt))
            context.insert(Site(
                url: "https://example.com/", title: "Example", category: "News",
                mode: .links, feedUrl: nil, createdAt: seededAt
            ))
            try context.save()
        }
        let context = try launch()
        #expect(sites(context).map(\.url) == ["https://example.com/"])
        #expect(try listItems(context).map(\.1) == ["Oat milk"])
    }

    /// A single store from before the user and cache split (the oldest
    /// installs) is not new either.
    @Test func aSingleStoreFromAnEarlierBuildIsNotSeeded() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: files.user.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            let schema = Schema(SeasignSchema.models)
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: files.user)])
            let context = ModelContext(old)
            context.insert(Settings(zip: "94103"))
            try context.save()
        }
        let context = try launch()
        #expect(sites(context).isEmpty)
        #expect(try listItems(context).isEmpty)
    }

    @Test func onlyAStoreFileThatDidNotExistCountsAsNew() throws {
        defer { cleanUp() }
        #expect(try LocalStore.open(files).userStoreIsNew)
        #expect(try !LocalStore.open(files).userStoreIsNew)
    }

    // MARK: The seeds themselves

    /// Each seed would pass the checks `FeedModel.add` makes on a resolved
    /// site, so it is stored exactly as following it in Settings would.
    @Test func theSeedsPassTheChecksOfAddingASite() {
        for site in StarterContent.sites {
            #expect(ArticleLink.url(site.url) != nil, "\(site.url)")
            #expect(ArticleLink.url(site.feedUrl) != nil, "\(site.feedUrl)")
            #expect(SiteAddress.normalize(site.url) == site.url)
            #expect(SiteAddress.fits(url: site.url, feedUrl: site.feedUrl))
            #expect(SiteText.clean(site.title, limit: FeedModel.siteTitleLimit) == site.title)
            #expect(CategoryName.clean(site.category) == site.category)
            #expect(!site.category.isEmpty)
        }
        #expect(StarterContent.sites.count <= FeedModel.maxSites)
    }

    /// The hard rule: the seeds are plain followed sites. Nothing about AI
    /// search or the subscription is written; Use My List stays.
    @Test func seedingTurnsNothingOnForAI() throws {
        defer { cleanUp() }
        let context = try launch()
        // Seeding writes no settings row; the one the app makes on first
        // read is Use My List with no interests.
        #expect(try context.fetch(FetchDescriptor<Settings>()).isEmpty)
        let settings = SkyStore(context: context).settings()
        #expect(settings.aiModeRaw == nil)
        #expect(settings.aiInterestsText == nil)
        #expect(settings.zip == SkyStore.defaultZip)
        #expect(try context.fetch(FetchDescriptor<SearchCount>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<FeedItem>()).isEmpty)
    }

}
