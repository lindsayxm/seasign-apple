import Foundation
import SwiftData
import Testing

@testable import Seasign

/// A clock the tests can move.
private final class LimitClock: @unchecked Sendable {
    private let lock = NSLock()
    /// 18:05 on Sunday 15 November 2026 in New York.
    private var value = instant("2026-11-15T23:05:00Z")
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private let tooMany = "Too many requests from this network. Try again in a minute."

/// `Retry-After` as sent, and the delay the app keeps. The header is
/// required on these routes; a 429 without a readable one is still the
/// limit, with the API's usual 60 seconds.
private let rateLimitDelays: [(String?, Int)] = [
    ("60", 60), ("0", 1), ("-5", 1), ("99999", 3600), (nil, 60), ("soon", 60),
]

/// The API's own per-network limit (429 `rate_limited` with `Retry-After`)
/// on sky, calendar, sites/resolve and feed, through the generated client.
@Suite struct RateLimitAPITests {
    @Test(arguments: rateLimitDelays)
    func sky(header: String?, delay: Int) async {
        let transport = RateLimitTransport(SkyStubTransport())
        transport.limit(retryAfter: header)
        await #expect(throws: SeasignAPI.SkyFailure.rateLimited(retryAfter: delay)) {
            try await stubbedAPI(transport).sky(zip: "10001")
        }
    }

    @Test(arguments: rateLimitDelays)
    func calendar(header: String?, delay: Int) async {
        let transport = RateLimitTransport(CalendarStub())
        transport.limit(retryAfter: header)
        await #expect(throws: SeasignAPI.CalendarFailure.rateLimited(retryAfter: delay)) {
            try await stubbedAPI(transport).calendarEvents(links: [TestLinks.google], timezone: nil)
        }
    }

    @Test(arguments: rateLimitDelays)
    func sitesAndFeed(header: String?, delay: Int) async {
        let transport = RateLimitTransport(FeedStub())
        transport.limit(retryAfter: header)
        await #expect(throws: SeasignAPI.SitesFailure.rateLimited(retryAfter: delay)) {
            try await stubbedAPI(transport).resolveSite(url: "https://news.example.com/science/")
        }
        await #expect(throws: SeasignAPI.SitesFailure.rateLimited(retryAfter: delay)) {
            try await stubbedAPI(transport).feed(sites: [.init(url: "https://news.example.com/science/", mode: .feed, feedUrl: nil)])
        }
    }

    /// A calendar link is a credential: the failure carries the delay only.
    @Test func theCalendarFailureCarriesNothingOfTheRequest() async {
        let transport = RateLimitTransport(CalendarStub())
        transport.limit(retryAfter: "soon")
        do {
            _ = try await stubbedAPI(transport).calendarEvents(links: [TestLinks.google], timezone: nil)
            Issue.record("expected a failure")
        } catch {
            var dumped = ""
            dump(error, to: &dumped)
            #expect(!dumped.contains(TestLinks.google))
            #expect(!String(reflecting: error).contains(TestLinks.google))
        }
    }
}

@Suite @MainActor struct RateLimitModelTests {
    private let clock = LimitClock()

    // MARK: Sky

    private func today(_ context: ModelContext, _ transport: RateLimitTransport) -> TodayModel {
        let clock = clock
        return TodayModel(api: stubbedAPI(transport), context: context, now: { clock.now })
    }

    /// Today keeps the cached sky and shows nothing; the next refresh waits
    /// for the delay.
    @Test func skyKeepsTheCachedSkyAndWaitsOutTheDelay() async throws {
        let transport = RateLimitTransport(SkyStubTransport())
        let model = today(try inMemoryContext(), transport)
        try await model.saveZip("10001")
        let cached = try #require(model.snapshot)

        clock.advance(11 * 60)
        transport.limit(retryAfter: "60")
        await model.refresh()
        #expect(model.snapshot == cached)
        #expect(model.zip == "10001")
        #expect(transport.count("getSky") == 2)

        // Today's one-minute loop: not again before the delay has passed.
        clock.advance(59)
        await model.refresh()
        #expect(transport.count("getSky") == 2)

        transport.lift()
        clock.advance(1)
        await model.refresh()
        #expect(transport.count("getSky") == 3)
        #expect(model.snapshot?.fetchedAt == clock.now)
        #expect(model.retryNotBefore == nil)
    }

    /// The zip check in Settings says what happened, not "couldn't find
    /// that zip", and keeps the previous zip and sky.
    @Test func theZipCheckSaysTooManyRequests() async throws {
        let transport = RateLimitTransport(SkyStubTransport())
        let model = today(try inMemoryContext(), transport)
        try await model.saveZip("10001")
        let cached = model.snapshot
        transport.limit(retryAfter: "60")
        await #expect(throws: TodayModel.ZipProblem.rateLimited) {
            try await model.saveZip("60601")
        }
        #expect(TodayModel.ZipProblem.rateLimited.message == tooMany)
        #expect(model.zip == "10001")
        #expect(model.snapshot == cached)
        #expect(model.retryNotBefore == clock.now.addingTimeInterval(60))
    }

    // MARK: Calendar

    private let show = StubEvent(title: "Hanna's show", start: "2026-11-16T01:25:00Z", end: "2026-11-16T03:00:00Z")

    private func events(_ context: ModelContext, _ transport: RateLimitTransport) -> EventsModel {
        let clock = clock
        let zone = TimeZone(identifier: "America/New_York")!
        return EventsModel(api: stubbedAPI(transport), context: context, timeZone: { zone }, now: { clock.now })
    }

    @Test func calendarKeepsTheEventsAndWaitsOutTheDelay() async throws {
        let stub = CalendarStub([TestLinks.google: .events([show])])
        let transport = RateLimitTransport(stub)
        let model = events(try inMemoryContext(), transport)
        try await model.add(name: "Family", link: TestLinks.google)
        let cached = try #require(model.snapshot)
        let asked = transport.count("postCalendarEvents")

        clock.advance(11 * 60)
        transport.limit(retryAfter: "60")
        await model.refresh()
        #expect(model.snapshot?.events == cached.events)
        #expect(model.status(for: try #require(model.links.first))?.problem == nil)
        #expect(transport.count("postCalendarEvents") == asked + 1)

        clock.advance(30)
        await model.refresh()
        #expect(transport.count("postCalendarEvents") == asked + 1)

        transport.lift()
        clock.advance(30)
        await model.refresh()
        #expect(transport.count("postCalendarEvents") == asked + 2)
        #expect(model.retryNotBefore == nil)
    }

    /// The pull on Today forces a refresh, which still waits out a 429.
    @Test func aForcedCalendarRefreshWaitsOutTheDelay() async throws {
        let stub = CalendarStub([TestLinks.google: .events([show])])
        let transport = RateLimitTransport(stub)
        let model = events(try inMemoryContext(), transport)
        try await model.add(name: "Family", link: TestLinks.google)
        let asked = transport.count("postCalendarEvents")

        transport.limit(retryAfter: "60")
        await model.refresh(force: true)
        #expect(transport.count("postCalendarEvents") == asked + 1)
        #expect(model.retryNotBefore != nil)

        clock.advance(30)
        await model.refresh(force: true)
        await model.refresh(force: true)
        #expect(transport.count("postCalendarEvents") == asked + 1)

        transport.lift()
        clock.advance(30)
        await model.refresh(force: true)
        #expect(transport.count("postCalendarEvents") == asked + 2)
        #expect(model.retryNotBefore == nil)
    }

    @Test func addingACalendarSaysTooManyRequests() async throws {
        let context = try inMemoryContext()
        let transport = RateLimitTransport(CalendarStub([TestLinks.google: .events([show])]))
        transport.limit(retryAfter: "60")
        let model = events(context, transport)
        await #expect(throws: EventsModel.AddProblem.rateLimited) {
            try await model.add(name: "Family", link: TestLinks.google)
        }
        #expect(EventsModel.AddProblem.rateLimited.message == tooMany)
        #expect(model.links.isEmpty)
        #expect(try context.fetch(FetchDescriptor<CalendarLink>()).isEmpty)
    }

    // MARK: Sites and feed

    private let telescope = StubItem(
        title: "A new telescope sees first light",
        link: "https://news.example.com/science/telescope/",
        published: "2026-11-15T21:42:55Z"
    )

    private func feed(_ context: ModelContext, _ transport: RateLimitTransport) -> FeedModel {
        let clock = clock
        return FeedModel(api: stubbedAPI(transport), context: context, now: { clock.now })
    }

    private func followedScience(_ stub: FeedStub) {
        stub.resolve("https://news.example.com/science/", resolveJSONFeed)
        stub.site("https://news.example.com/science/", .items([telescope]))
    }

    @Test func feedKeepsTheHeadlinesAndWaitsOutTheDelay() async throws {
        let stub = FeedStub()
        followedScience(stub)
        let transport = RateLimitTransport(stub)
        let model = feed(try inMemoryContext(), transport)
        try await model.add(address: "news.example.com/science/", category: "Sci")
        let cached = model.entries
        #expect(cached.count == 1)
        let asked = transport.count("postFeed")

        clock.advance(16 * 60)
        transport.limit(retryAfter: "60")
        await model.refresh()
        #expect(model.entries == cached)
        #expect(model.status(for: try #require(model.sites.first))?.problem == nil)
        #expect(transport.count("postFeed") == asked + 1)

        // Return to the foreground within the delay: nothing is asked.
        clock.advance(30)
        await model.refresh()
        #expect(transport.count("postFeed") == asked + 1)
        // "Refresh headlines now" is the user's own tap: it is sent.
        await model.refresh(force: true)
        #expect(transport.count("postFeed") == asked + 2)
        #expect(model.entries == cached)

        transport.lift()
        clock.advance(61)
        await model.refresh()
        #expect(transport.count("postFeed") == asked + 3)
        #expect(model.retryNotBefore == nil)
    }

    /// Adding a site says what happened; resolve's limit holds nothing else back.
    @Test func addingASiteSaysTooManyRequests() async throws {
        let context = try inMemoryContext()
        let stub = FeedStub()
        followedScience(stub)
        let transport = RateLimitTransport(stub)
        transport.limit(["postSitesResolve"], retryAfter: "60")
        let model = feed(context, transport)
        await #expect(throws: FeedModel.AddProblem.rateLimited) {
            try await model.add(address: "news.example.com/science/", category: "Sci")
        }
        #expect(FeedModel.AddProblem.rateLimited.message == tooMany)
        #expect(model.sites.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Site>()).isEmpty)
        #expect(model.retryNotBefore == nil)
    }

    /// The Settings messages are fixed text and the same for each route.
    @Test func theSettingsMessagesAreFixed() {
        #expect(ServerRateLimit.message == tooMany)
        for message in [
            TodayModel.ZipProblem.rateLimited.message,
            EventsModel.AddProblem.rateLimited.message,
            FeedModel.AddProblem.rateLimited.message,
        ] {
            #expect(message == tooMany)
        }
    }
}
