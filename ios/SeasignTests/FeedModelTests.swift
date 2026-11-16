import Foundation
import SwiftData
import Testing

@testable import Seasign

/// A clock the tests can move.
private final class FeedClock: @unchecked Sendable {
    private let lock = NSLock()
    /// 18:05 on Sunday 15 November 2026 in New York.
    private var value = instant("2026-11-15T23:05:00Z")
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private enum Pages {
    static let science = "https://news.example.com/science/"
    static let scienceFeed = "https://news.example.com/science/feed/"
    static let lakes = "https://lakes.example.org/"
    static let wire = "https://wire.example.net/world"
}

@Suite @MainActor struct FeedModelTests {
    private let clock = FeedClock()
    private let stub = FeedStub()
    private let newYork = TimeZone(identifier: "America/New_York")!

    private let telescope = StubItem(
        title: "A new telescope sees first light",
        link: "https://news.example.com/science/telescope/",
        published: "2026-11-15T21:42:55Z",
        excerpt: "The observatory released its first images."
    )
    private let crows = StubItem(
        title: "Crows make decisions faster than we can",
        link: "https://news.example.com/science/crows/",
        published: "2026-11-14T09:00:00Z"
    )
    private let lakesWinter = StubItem(
        title: "What the Great Lakes remember about last winter",
        link: "https://lakes.example.org/2026/11/15/winter",
        published: "2026-11-15T16:10:00Z",
        source: "The Lakes Review",
        dateSource: "first_seen",
        excerpt: nil
    )

    init() {
        stub.resolve(Pages.science, resolveJSONFeed)
        stub.resolve(Pages.lakes, resolveJSONLinks)
        stub.resolve("https://shop.example.com/", resolveJSONNoLinks)
        stub.resolve(
            Pages.wire,
            #"{"ok":true,"title":"Example Wire: World","url":"https://wire.example.net/world","mode":"links","linkCount":9}"#
        )
    }

    private func model(_ context: ModelContext) -> FeedModel {
        let clock = clock
        return FeedModel(api: stubbedFeedAPI(stub), context: context, now: { clock.now })
    }

    private func headlines(_ model: FeedModel) -> [String] {
        model.headlines(now: clock.now, timeZone: newYork).map(\.title)
    }

    // MARK: Adding

    /// The first acceptance criterion: a site added with a category shows its
    /// recent headlines on Today.
    @Test func addingASiteShowsItsHeadlines() async throws {
        let context = try inMemoryContext()
        stub.site(Pages.science, .items([telescope, crows]))
        let model = model(context)

        try await model.add(address: "news.example.com/science/", category: "  Sci ")
        #expect(stub.resolveRequests == [Pages.science])
        let site = try #require(model.sites.first)
        #expect(site.url == Pages.science)
        #expect(site.title == "Science | Example News")
        #expect(site.category == "Sci")
        #expect(site.mode == .feed)
        #expect(site.feedUrl == Pages.scienceFeed)
        // One feed request, for the new site alone.
        #expect(stub.feedRequests == [.init(urls: [Pages.science], modes: ["feed"], feedUrls: [Pages.scienceFeed])])
        #expect(headlines(model) == ["A new telescope sees first light", "Crows make decisions faster than we can"])
        #expect(model.status(for: site)?.problem == nil)
        #expect(model.itemCount(for: site) == 2)

        let stored = try context.fetch(FetchDescriptor<FeedItem>())
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.siteID == site.id && $0.category == "Sci" })
    }

    @Test func aPageTheAPICannotReadIsNotSaved() async throws {
        let context = try inMemoryContext()
        stub.resolve("https://down.example.com/", #"{"ok":false,"error":"timeout"}"#)
        let model = model(context)
        await #expect(throws: FeedModel.AddProblem.site(.timeout)) {
            try await model.add(address: "down.example.com/", category: "News")
        }
        #expect(model.sites.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Site>()).isEmpty)
        #expect(stub.feedRequests.isEmpty)
    }

    @Test func aPageWithNoArticleLinksIsNotSaved() async throws {
        let context = try inMemoryContext()
        let model = model(context)
        await #expect(throws: FeedModel.AddProblem.noArticles) {
            try await model.add(address: "https://shop.example.com/", category: "Stuff")
        }
        #expect(try context.fetch(FetchDescriptor<Site>()).isEmpty)
    }

    @Test func nothingIsSavedWhenTheAPICannotBeAsked() async throws {
        let context = try inMemoryContext()
        stub.setOffline(true)
        let model = model(context)
        await #expect(throws: FeedModel.AddProblem.unavailable) {
            try await model.add(address: Pages.science, category: "Sci")
        }
        #expect(try context.fetch(FetchDescriptor<Site>()).isEmpty)
    }

    @Test func checksWhatWasTypedBeforeAskingTheAPI() async throws {
        let model = model(try inMemoryContext())
        await #expect(throws: FeedModel.AddProblem.missingAddress) {
            try await model.add(address: "  ", category: "Sci")
        }
        await #expect(throws: FeedModel.AddProblem.missingCategory) {
            try await model.add(address: Pages.science, category: " \n ")
        }
        await #expect(throws: FeedModel.AddProblem.invalidAddress) {
            try await model.add(address: "ftp://example.com/", category: "Sci")
        }
        await #expect(throws: FeedModel.AddProblem.tooLong) {
            try await model.add(address: "example.com/" + String(repeating: "a", count: 600), category: "Sci")
        }
        #expect(stub.resolveRequests.isEmpty)
    }

    @Test func aSiteIsFollowedOnceByItsNormalAddress() async throws {
        stub.site(Pages.science, .items([telescope]))
        // A different spelling that the API turns into the same address.
        stub.resolve("https://news.example.com/science", resolveJSONFeed)
        let model = model(try inMemoryContext())
        try await model.add(address: Pages.science, category: "Sci")
        await #expect(throws: FeedModel.AddProblem.alreadyFollowed) {
            try await model.add(address: "news.example.com/science", category: "Sci")
        }
        #expect(model.sites.count == 1)
    }

    @Test func atMostFiftySites() async throws {
        let context = try inMemoryContext()
        for index in 0..<FeedModel.maxSites {
            context.insert(Site(
                url: "https://site\(index).example.com/", title: "Site \(index)", category: "News",
                mode: .links, feedUrl: nil, createdAt: clock.now.addingTimeInterval(Double(index))
            ))
        }
        try context.save()
        let model = model(context)
        #expect(!model.canAddSite)
        await #expect(throws: FeedModel.AddProblem.limitReached) {
            try await model.add(address: Pages.science, category: "Sci")
        }
        #expect(stub.resolveRequests.isEmpty)
    }

    @Test func categoriesAreReusedIgnoringCase() async throws {
        stub.site(Pages.science, .items([]))
        stub.site(Pages.lakes, .items([]))
        let model = model(try inMemoryContext())
        try await model.add(address: Pages.science, category: "Sci")
        try await model.add(address: Pages.lakes, category: "sci")
        #expect(model.sites.map(\.category) == ["Sci", "Sci"])
        #expect(model.categories == ["Sci"])
    }

    @Test func aSiteTitleIsCleanedBeforeItIsStored() async throws {
        stub.resolve(
            "https://odd.example.com/",
            #"{"ok":true,"title":"  Odd\n‮etis‬   News  ","url":"https://odd.example.com/","mode":"links","linkCount":3}"#
        )
        stub.site("https://odd.example.com/", .items([]))
        let model = model(try inMemoryContext())
        try await model.add(address: "odd.example.com/", category: "News")
        #expect(model.sites.first?.title == "Odd etis News")
    }

    // MARK: Refreshing

    private func followed(_ context: ModelContext) async throws -> FeedModel {
        stub.site(Pages.science, .items([telescope, crows]))
        stub.site(Pages.lakes, .items([lakesWinter]))
        stub.site(Pages.wire, .failure("timeout"))
        let model = model(context)
        // A second apart, so the sites keep the order they were added in.
        try await model.add(address: Pages.science, category: "Sci")
        clock.now = clock.now.addingTimeInterval(1)
        try await model.add(address: Pages.lakes, category: "Local")
        clock.now = clock.now.addingTimeInterval(1)
        try await model.add(address: Pages.wire, category: "News")
        return model
    }

    @Test func oneRequestForEverySiteAndAFailingSiteDoesNotBlankToday() async throws {
        let model = try await followed(try inMemoryContext())
        let before = stub.feedRequests.count
        await model.refresh(force: true)
        #expect(stub.feedRequests.count == before + 1)
        #expect(stub.feedRequests.last?.urls == [Pages.science, Pages.lakes, Pages.wire])
        #expect(headlines(model) == [
            "A new telescope sees first light",
            "What the Great Lakes remember about last winter",
            "Crows make decisions faster than we can",
        ])
        let wire = try #require(model.sites.last)
        #expect(model.status(for: wire)?.problem == .timeout)
        #expect(model.status(for: model.sites[0])?.problem == nil)
    }

    @Test func itemsAreMergedByLinkAndKeepWhenTheyWereFirstFetched() async throws {
        let context = try inMemoryContext()
        let model = try await followed(context)
        let firstFetched = try #require(try context.fetch(FetchDescriptor<FeedItem>()).first { $0.link == telescope.link }?.firstFetchedAt)

        // Later: the site renamed the story and dropped the crows piece.
        clock.now = clock.now.addingTimeInterval(20 * 60)
        var renamed = telescope
        renamed.title = "A new telescope sees first light (updated)"
        stub.site(Pages.science, .items([renamed]))
        await model.refresh()

        let rows = try context.fetch(FetchDescriptor<FeedItem>())
        #expect(rows.filter { $0.link == telescope.link }.count == 1)
        let row = try #require(rows.first { $0.link == telescope.link })
        #expect(row.title == "A new telescope sees first light (updated)")
        #expect(row.firstFetchedAt == firstFetched)
        // Missing from the answer is not gone: the history keeps it.
        #expect(rows.contains { $0.link == crows.link })
        #expect(model.entries.count == 3)
    }

    @Test func aSiteThatStartsFailingKeepsItsItems() async throws {
        let model = try await followed(try inMemoryContext())
        stub.site(Pages.lakes, .failure("fetch_failed"))
        await model.refresh(force: true)
        #expect(headlines(model).contains("What the Great Lakes remember about last winter"))
        #expect(model.status(for: model.sites[1])?.problem == .fetchFailed)
    }

    @Test func aWholeRequestFailureKeepsWhatIsCached() async throws {
        let model = try await followed(try inMemoryContext())
        let shown = headlines(model)
        let state = model.state
        stub.setOffline(true)
        await model.refresh(force: true)
        #expect(headlines(model) == shown)
        #expect(model.state == state)
    }

    @Test func refreshesAtMostEveryFifteenMinutes() async throws {
        let model = try await followed(try inMemoryContext())
        await model.refresh(force: true)
        let count = stub.feedRequests.count

        clock.now = clock.now.addingTimeInterval(14 * 60)
        await model.refresh()
        #expect(stub.feedRequests.count == count)

        clock.now = clock.now.addingTimeInterval(2 * 60)
        await model.refresh()
        #expect(stub.feedRequests.count == count + 1)

        await model.refresh(force: true)
        #expect(stub.feedRequests.count == count + 2)
    }

    @Test func aSiteNeverReadIsAskedForAtOnce() async throws {
        let context = try inMemoryContext()
        context.insert(Site(url: Pages.lakes, title: "The Lakes Review", category: "Local", mode: .links, feedUrl: nil, createdAt: clock.now))
        try context.save()
        stub.site(Pages.lakes, .items([lakesWinter]))
        let model = model(context)
        await model.refresh()
        #expect(stub.feedRequests.count == 1)
        #expect(headlines(model) == ["What the Great Lakes remember about last winter"])
    }

    @Test func theRefreshTimeSurvivesARelaunch() async throws {
        let context = try inMemoryContext()
        _ = try await followed(context)
        let first = model(context)
        await first.refresh(force: true)
        let count = stub.feedRequests.count

        clock.now = clock.now.addingTimeInterval(5 * 60)
        let relaunched = model(context)
        await relaunched.refresh()
        #expect(stub.feedRequests.count == count)
        #expect(headlines(relaunched).count == 3)
    }

    @Test func noSitesNoRequest() async throws {
        let model = model(try inMemoryContext())
        await model.refresh(force: true)
        #expect(stub.feedRequests.isEmpty)
        #expect(model.entries.isEmpty)
    }

    // MARK: Pruning and removing

    @Test func itemsOlderThanSevenDaysArePrunedOnLoadAndRefresh() async throws {
        let context = try inMemoryContext()
        let model = try await followed(context)
        #expect(model.entries.count == 3)

        // Crows was published on the 14th at 09:00Z; eight days later it is gone.
        clock.now = instant("2026-11-21T09:30:00Z")
        let relaunched = self.model(context)
        #expect(!relaunched.entries.contains { $0.link == crows.link })
        #expect(try context.fetch(FetchDescriptor<FeedItem>()).count == 2)

        clock.now = instant("2026-11-23T00:00:00Z")
        stub.setOffline(true)
        await relaunched.refresh(force: true)
        #expect(relaunched.entries.isEmpty)
        #expect(try context.fetch(FetchDescriptor<FeedItem>()).isEmpty)
    }

    @Test func anExpiredItemInAnAnswerIsNotStored() async throws {
        let old = StubItem(title: "Old news", link: "https://news.example.com/old", published: "2026-11-01T00:00:00Z")
        stub.site(Pages.science, .items([old, telescope]))
        let model = model(try inMemoryContext())
        try await model.add(address: Pages.science, category: "Sci")
        #expect(model.entries.map(\.title) == ["A new telescope sees first light"])
    }

    @Test func removingASiteDropsItsItemsAndStatus() async throws {
        let context = try inMemoryContext()
        let model = try await followed(context)
        let lakes = model.sites[1]
        let lakesID = lakes.id
        model.remove(lakes)
        #expect(model.sites.count == 2)
        #expect(!headlines(model).contains("What the Great Lakes remember about last winter"))
        #expect(try context.fetch(FetchDescriptor<FeedItem>()).allSatisfy { $0.siteID != lakesID })
        #expect(model.state.status(for: lakesID) == nil)

        for site in model.sites { model.remove(site) }
        #expect(model.entries.isEmpty)
        #expect(try context.fetch(FetchDescriptor<CachedFeedState>()).isEmpty)
    }

    // MARK: Untrusted content

    @Test func itemsAreCleanedAndUnsafeLinksDropped() async throws {
        stub.site(Pages.science, .items([
            StubItem(title: "Plain", link: "http://news.example.com/plain", published: "2026-11-15T20:00:00Z"),
            StubItem(title: "Script", link: "javascript:alert(1)", published: "2026-11-15T20:00:00Z"),
            StubItem(title: "  \n ", link: "https://news.example.com/untitled", published: "2026-11-15T20:00:00Z"),
            StubItem(
                title: "Line one\nLine\u{0007} two",
                link: "https://news.example.com/kept",
                published: "2026-11-15T20:00:00Z",
                source: "",
                excerpt: "  \n "
            ),
        ]))
        let model = model(try inMemoryContext())
        try await model.add(address: Pages.science, category: "Sci")
        let entry = try #require(model.entries.first)
        #expect(model.entries.count == 1)
        #expect(entry.title == "Line one Line two")
        #expect(entry.source == "Science | Example News")
        #expect(entry.excerpt == nil)
    }

    @Test func aStoredItemCanBeFoundByItsLink() async throws {
        let context = try inMemoryContext()
        _ = try await followed(context)
        let store = FeedStore(context: context)
        #expect(store.item(link: lakesWinter.link)?.dateSource == .firstSeen)
        #expect(store.item(link: lakesWinter.link)?.excerpt == nil)
        #expect(store.item(link: "https://nowhere.example/") == nil)
    }
}

#if DEBUG
@Suite @MainActor struct FeedSampleTests {
    @Test func theSampleShowsHeadlinesWithoutTheNetwork() throws {
        let now = instant("2026-11-15T23:05:00Z")
        let sample = try FeedModel.sample(now: now)
        #expect(sample.sites.count == 3)
        #expect(sample.headlines(now: now, timeZone: TimeZone(identifier: "America/New_York")!).count == 5)
    }

    /// Today through the model: with AI-found items hidden it is exactly the
    /// old newest-first list; shown, they alternate with the sites' items,
    /// starting with a site's. History (`entries`) stays newest first.
    @Test func todayBlendsAIFoundItemsEveryOtherOnlyWhileTheyAreShown() throws {
        let now = instant("2026-11-15T23:05:00Z")
        let newYork = TimeZone(identifier: "America/New_York")!
        let sample = try FeedModel.sample(now: now)
        sample.addSampleAIItems(now: now)

        sample.showsAI = false
        let hidden = sample.headlines(now: now, timeZone: newYork)
        #expect(hidden == HeadlinePicker.sinceYesterday(sample.entries, now: now, timeZone: newYork))
        #expect(hidden.map(\.title) == PlaceholderHeadlines.all)

        sample.showsAI = true
        let shown = sample.headlines(now: now, timeZone: newYork)
        #expect(shown.map(\.isAI) == [false, true, false, true, false, false, false])
        #expect(shown.filter { !$0.isAI }.map(\.title) == PlaceholderHeadlines.all)
        #expect(shown.filter(\.isAI).map(\.title) == [
            "Tide pools are filling with warm-water visitors this fall",
            "A small telescope on a dark ridge caught a comet's tail splitting",
        ])
        // History is not blended.
        #expect(sample.entries == sample.entries.sorted(by: FeedEntry.newestFirst))
        #expect(sample.entries.first?.isAI == true)
    }
}
#endif
