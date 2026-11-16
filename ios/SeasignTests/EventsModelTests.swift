import Foundation
import SwiftData
import Testing

@testable import Seasign

/// A clock and a time zone the tests can move.
@MainActor
private final class World {
    var zone = TimeZone(identifier: "America/New_York")!
    let clock = Clock()

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        /// 18:05 on Sunday 15 November 2026 in New York.
        private var value = instant("2026-11-15T23:05:00Z")
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

@Suite @MainActor struct EventsModelTests {
    private let world = World()
    private let stub = CalendarStub()

    private let show = StubEvent(title: "Hanna's show", start: "2026-11-16T01:25:00Z", end: "2026-11-16T03:00:00Z")
    private let dentist = StubEvent(title: "Dentist", start: "2026-11-16T14:00:00Z", end: "2026-11-16T15:00:00Z")
    private let lunch = StubEvent(title: "Lunch", start: "2026-11-17T17:00:00Z", end: "2026-11-17T18:00:00Z")
    private let trip = StubEvent(title: "Trip", start: "2026-11-18T05:00:00Z", end: "2026-11-19T05:00:00Z", allDay: true, date: "2026-11-18")

    private func model(_ context: ModelContext) -> EventsModel {
        let world = world
        let clock = world.clock
        return EventsModel(api: stubbedCalendarAPI(stub), context: context, timeZone: { world.zone }, now: { clock.now })
    }

    private func times(_ model: EventsModel) -> [String] {
        model.labels(now: world.clock.now).map { "\($0.time) \($0.title)" }
    }

    // MARK: Adding and removing

    @Test func startsEmptyAndAsksNothing() async throws {
        let model = model(try inMemoryContext())
        await model.refresh(force: true)
        #expect(model.links.isEmpty)
        #expect(times(model).isEmpty)
        #expect(stub.requests.isEmpty)
    }

    /// The first acceptance criterion: a link added in Settings shows its
    /// next three events on Today, and removing it clears them.
    @Test func addingALinkShowsItsNextThreeEventsAndRemovingClearsThem() async throws {
        let context = try inMemoryContext()
        stub.set(TestLinks.google, .events([show, dentist, lunch, trip]))
        let model = model(context)

        try await model.add(name: "  Family ", link: " \(TestLinks.google)\n")
        #expect(model.links.map(\.name) == ["Family"])
        #expect(model.links.map(\.url) == [TestLinks.google])
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist", "TUE 12:00PM Lunch"])
        // One request did both the check and the fetch, for that link alone.
        #expect(stub.requests == [.init(links: [TestLinks.google], timezone: "America/New_York")])
        #expect(model.status(for: model.links[0]) == LinkStatus(problem: nil, partial: false))

        await model.remove(model.links[0])
        #expect(model.links.isEmpty)
        #expect(times(model).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CalendarLink>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CachedEvents>()).isEmpty)
        // With no links left there is nothing to ask.
        #expect(stub.requests.count == 1)
    }

    @Test func eventsOfSeveralCalendarsAreMergedSoonestFirst() async throws {
        stub.set(TestLinks.google, .events([show, lunch]))
        stub.set(TestLinks.icloud, .events([dentist, trip]))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        // Links are listed in the order they were added, by time.
        world.clock.now += 1
        try await model.add(name: "Work", link: TestLinks.icloud)
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist", "TUE 12:00PM Lunch"])
        #expect(model.labels(now: world.clock.now, limit: 4).last?.time == "WED ALL DAY")

        // Removing one leaves the other's events, at once.
        stub.setOffline(true)
        await model.remove(model.links[0])
        #expect(times(model) == ["MON 9:00AM Dentist", "WED ALL DAY Trip"])
    }

    @Test func aLinkThatCannotBeReadIsNotSaved() async throws {
        let context = try inMemoryContext()
        let model = model(context)
        for problem in LinkProblem.allCases {
            stub.set(TestLinks.outlook, .failure(problem.rawValue))
            await #expect(throws: EventsModel.AddProblem.link(problem)) {
                try await model.add(name: "Work", link: TestLinks.outlook)
            }
        }
        #expect(EventsModel.AddProblem.link(.notCalendar).message == "That link didn't return a calendar.")
        stub.setOffline(true)
        await #expect(throws: EventsModel.AddProblem.unavailable) {
            try await model.add(name: "Work", link: TestLinks.outlook)
        }
        #expect(model.links.isEmpty)
        #expect(try context.fetch(FetchDescriptor<CalendarLink>()).isEmpty)
    }

    @Test func nameAndLinkAreNeededAndALinkIsAddedOnce() async throws {
        stub.set(TestLinks.google, .events([show]))
        let model = model(try inMemoryContext())
        await #expect(throws: EventsModel.AddProblem.missingName) {
            try await model.add(name: "  ", link: TestLinks.google)
        }
        await #expect(throws: EventsModel.AddProblem.missingLink) {
            try await model.add(name: "Family", link: " \n")
        }
        #expect(stub.requests.isEmpty)
        try await model.add(name: "Family", link: TestLinks.google)
        await #expect(throws: EventsModel.AddProblem.alreadyAdded) {
            try await model.add(name: "Again", link: "  \(TestLinks.google) ")
        }
        #expect(model.links.count == 1)
        #expect(stub.requests.count == 1)
    }

    @Test func tenLinksAreTheLimit() async throws {
        let model = model(try inMemoryContext())
        for number in 1...10 {
            let link = "https://cal.example.com/\(number).ics"
            stub.set(link, .events([]))
            world.clock.now += 1
            try await model.add(name: "Calendar \(number)", link: link)
        }
        #expect(model.links.map(\.name).first == "Calendar 1")
        #expect(model.links.count == 10)
        #expect(!model.canAddLink)
        stub.set(TestLinks.google, .events([show]))
        let before = stub.requests.count
        await #expect(throws: EventsModel.AddProblem.limitReached) {
            try await model.add(name: "Eleventh", link: TestLinks.google)
        }
        #expect(stub.requests.count == before)
        // A refresh sends all ten in the order they were added.
        await model.refresh(force: true)
        #expect(stub.requests.last?.links == (1...10).map { "https://cal.example.com/\($0).ics" })
    }

    /// No message a person can be shown holds any part of a link.
    @Test func noMessageMentionsTheLink() async throws {
        var problems: [EventsModel.AddProblem] = [.missingName, .missingLink, .alreadyAdded, .limitReached, .unavailable, .notSaved]
        problems += LinkProblem.allCases.map { .link($0) }
        stub.set(TestLinks.google, .failure("fetch_failed"))
        let model = model(try inMemoryContext())
        do {
            try await model.add(name: "Family", link: TestLinks.google)
            Issue.record("expected a problem")
        } catch {
            for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                #expect(!text.contains("SECRETTOKEN"))
                #expect(!text.contains("google"))
            }
        }
        for problem in problems {
            #expect(!problem.message.isEmpty)
            #expect(!problem.message.contains("SECRETTOKEN"))
        }
    }

    // MARK: Failures

    /// The third acceptance criterion: a failing link is reported for
    /// Settings and the other calendars' events stay on Today.
    @Test func aFailingLinkDoesNotBlankToday() async throws {
        stub.set(TestLinks.google, .events([show, lunch]))
        stub.set(TestLinks.icloud, .events([dentist], partial: true))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        // Links are listed in the order they were added, by time.
        world.clock.now += 1
        try await model.add(name: "Work", link: TestLinks.icloud)
        #expect(model.status(for: model.links[1])?.message == "Some events in this calendar couldn't be read.")

        // The second link stops being a calendar (its secret address was reset, say).
        stub.set(TestLinks.icloud, .failure("not_calendar"))
        await model.refresh(force: true)
        #expect(times(model) == ["8:25PM Hanna's show", "TUE 12:00PM Lunch"])
        #expect(model.status(for: model.links[0])?.message == nil)
        #expect(model.status(for: model.links[1]) == LinkStatus(problem: .notCalendar, partial: false))
        #expect(model.status(for: model.links[1])?.message == "That link didn't return a calendar.")
    }

    @Test func aCalendarThatTimesOutKeepsTheEventsReadBefore() async throws {
        stub.set(TestLinks.google, .events([show]))
        stub.set(TestLinks.icloud, .events([dentist]))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        // Links are listed in the order they were added, by time.
        world.clock.now += 1
        try await model.add(name: "Work", link: TestLinks.icloud)

        stub.set(TestLinks.icloud, .failure("timeout"))
        await model.refresh(force: true)
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
        #expect(model.status(for: model.links[1])?.problem == .timeout)
    }

    @Test func aFailedRequestKeepsWhatIsOnScreen() async throws {
        stub.set(TestLinks.google, .events([show, dentist]))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        let before = model.snapshot

        stub.setOffline(true)
        await model.refresh(force: true)
        #expect(model.snapshot == before)
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
    }

    // MARK: Cache

    @Test func aNewLaunchShowsCachedEventsBeforeAnyRequest() async throws {
        let context = try inMemoryContext()
        stub.set(TestLinks.google, .events([show, dentist]))
        let first = model(context)
        try await first.add(name: "Family", link: TestLinks.google)

        stub.setOffline(true)
        let requests = stub.requests.count
        let relaunched = model(context)
        #expect(stub.requests.count == requests)
        #expect(times(relaunched) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
        await relaunched.refresh(force: true)
        #expect(times(relaunched) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
        #expect(relaunched.status(for: relaunched.links[0]) == LinkStatus(problem: nil, partial: false))
    }

    @Test func theCacheHoldsNoLink() async throws {
        let context = try inMemoryContext()
        stub.set(TestLinks.google, .events([show]))
        let model = model(context)
        try await model.add(name: "Family", link: TestLinks.google)
        let rows = try context.fetch(FetchDescriptor<CachedEvents>())
        #expect(rows.count == 1)
        let text = String(decoding: try #require(rows.first).payload, as: UTF8.self)
        #expect(text.contains("Hanna"))
        #expect(!text.contains("SECRETTOKEN"))
        #expect(!text.contains("google"))
    }

    @Test func endedEventsLeaveTodayAndTheCache() async throws {
        let context = try inMemoryContext()
        stub.set(TestLinks.google, .events([show, dentist]))
        let model = model(context)
        try await model.add(name: "Family", link: TestLinks.google)

        // 22:01 in New York: the show ended at 22:00. Today drops it with the
        // clock alone, before anything is fetched.
        stub.setOffline(true)
        world.clock.now = instant("2026-11-16T03:01:00Z")
        #expect(times(model) == ["MON 9:00AM Dentist"])
        await model.refresh()
        #expect(model.snapshot?.events.map(\.title) == ["Dentist"])
        let cached = try #require(EventsStore(context: context).cachedEvents())
        #expect(cached.events.map(\.title) == ["Dentist"])

        // A launch on Monday afternoon starts without the dentist.
        world.clock.now = instant("2026-11-16T20:00:00Z")
        #expect(self.model(context).snapshot?.events.isEmpty == true)
    }

    @Test func refreshSkipsFreshEventsAndFetchesStaleOnes() async throws {
        stub.set(TestLinks.google, .events([show]))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        #expect(stub.requests.count == 1)

        world.clock.now += 9 * 60
        await model.refresh()
        #expect(stub.requests.count == 1)

        stub.set(TestLinks.google, .events([show, dentist]))
        world.clock.now += 2 * 60
        await model.refresh()
        #expect(stub.requests.count == 2)
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
        #expect(model.snapshot?.fetchedAt == world.clock.now)
    }

    @Test func aLinkWithoutCachedEventsIsFetchedAtLaunch() async throws {
        let context = try inMemoryContext()
        context.insert(CalendarLink(name: "Family", url: TestLinks.google, createdAt: world.clock.now))
        try context.save()
        stub.set(TestLinks.google, .events([show]))
        let model = model(context)
        #expect(times(model).isEmpty)
        await model.refresh()
        #expect(times(model) == ["8:25PM Hanna's show"])
    }

    // MARK: Time zone

    /// The zip is in New York and the phone is in Tokyo: the zip's zone is
    /// sent and times are shown in it.
    @Test func theZipsZoneIsSentAndShownWhenThePhoneIsElsewhere() async throws {
        let context = try inMemoryContext()
        let now = world.clock.now
        let today = TodayModel(api: stubbedSkyAPI(), context: context, now: { now })
        try await today.saveZip("10001")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        world.zone = EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: tokyo)

        stub.set(TestLinks.google, .events([show, trip]))
        let model = model(context)
        try await model.add(name: "Family", link: TestLinks.google)
        #expect(stub.requests.last?.timezone == "America/New_York")
        #expect(times(model) == ["8:25PM Hanna's show", "WED ALL DAY Trip"])

        // Without the zip the phone's zone takes over: the cached events were
        // placed for New York, so they are hidden and asked for again.
        today.clearZip()
        world.zone = EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: tokyo)
        #expect(times(model).isEmpty)
        stub.set(TestLinks.google, .events([
            show,
            StubEvent(title: "Trip", start: "2026-11-17T15:00:00Z", end: "2026-11-18T15:00:00Z", allDay: true, date: "2026-11-18"),
        ]))
        await model.refresh()
        #expect(stub.requests.last == .init(links: [TestLinks.google], timezone: "Asia/Tokyo"))
        // 08:05 on Monday in Tokyo: the show is today at 10:25.
        #expect(times(model) == ["10:25AM Hanna's show", "WED ALL DAY Trip"])
    }

    @Test func cachedEventsOfAnotherZoneAreNotShownAtLaunch() async throws {
        let context = try inMemoryContext()
        stub.set(TestLinks.google, .events([show]))
        let first = model(context)
        try await first.add(name: "Family", link: TestLinks.google)

        world.zone = TimeZone(identifier: "America/Los_Angeles")!
        stub.setOffline(true)
        let relaunched = model(context)
        #expect(times(relaunched).isEmpty)
        await relaunched.refresh()
        #expect(relaunched.snapshot == nil)
        stub.setOffline(false)
        await relaunched.refresh()
        #expect(times(relaunched) == ["5:25PM Hanna's show"])
    }
}

/// The second acceptance criterion: the app declares no calendar access.
@Suite struct NoCalendarPermissionTests {
    @Test func infoPlistHasNoCalendarUsageString() {
        let keys = (Bundle.main.infoDictionary ?? [:]).keys
        #expect(!keys.isEmpty)
        #expect(!keys.contains { $0.hasPrefix("NSCalendars") || $0.hasPrefix("NSReminders") })
    }
}
