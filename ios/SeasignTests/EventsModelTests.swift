import Foundation
import OpenAPIRuntime
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

    private func model(_ context: ModelContext, transport: (any ClientTransport)? = nil) -> EventsModel {
        let world = world
        let clock = world.clock
        let api = transport.map { SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: $0) } ?? stubbedCalendarAPI(stub)
        return EventsModel(api: api, context: context, timeZone: { world.zone }, now: { clock.now })
    }

    private func times(_ model: EventsModel, clock: ClockStyle = .twelveHour) -> [String] {
        model.labels(now: world.clock.now, clock: clock).map { "\($0.time) \($0.title)" }
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
        // One request did both the check and the fetch, for that link alone,
        // read again by the API rather than from its cache.
        #expect(stub.requests == [.init(links: [TestLinks.google], timezone: "America/New_York", fresh: true)])
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
        #expect(model.labels(now: world.clock.now, clock: .twelveHour, limit: 4).last?.time == "WED ALL DAY")

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

        // Pasted links are the slow fallback (user decision 2026-11-21).
        #expect(EventsModel.refreshInterval == 5 * 60)
        world.clock.now += 299
        await model.refresh()
        #expect(stub.requests.count == 1)

        stub.set(TestLinks.google, .events([show, dentist]))
        world.clock.now += 1
        await model.refresh()
        #expect(stub.requests.count == 2)
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
        #expect(model.snapshot?.fetchedAt == world.clock.now)
        // A scheduled check may be answered from the API's cache.
        #expect(stub.requests.last?.fresh == nil)
    }

    /// Today asks on its one-minute loop and again on every return to the
    /// foreground. However often it asks, scheduled checks go out at most
    /// every 5 minutes, and none asks the API to skip its cache.
    @Test func anOpenAppAsksEveryFiveMinutes() async throws {
        stub.set(TestLinks.google, .events([show]))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        let before = stub.requests.count

        // Ten minutes of asking every ten seconds.
        for _ in 0..<60 {
            world.clock.now += 10
            await model.refresh()
        }
        #expect(stub.requests.count - before == 2)
        #expect(stub.requests.dropFirst(before).allSatisfy { $0.fresh == nil })
    }

    /// The pull on Today: sent even when the events are fresh, and read
    /// again by the API instead of from its cache.
    @Test func aForcedRefreshAsksAgainAtOnce() async throws {
        stub.set(TestLinks.google, .events([show]))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        let before = stub.requests.count

        world.clock.now += 5
        stub.set(TestLinks.google, .events([show, dentist]))
        await model.refresh(force: true)
        #expect(stub.requests.count == before + 1)
        #expect(stub.requests.last?.fresh == true)
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
    }

    /// What Today reads on a return to the foreground: due (so the return
    /// asks with `force`, fresh) once the events are 5 minutes old.
    @Test func isDueOnceTheEventsAreFiveMinutesOldOrMissing() async throws {
        let context = try inMemoryContext()
        let model = model(context)
        // Nothing to ask for without a link.
        #expect(!model.isDue)

        stub.set(TestLinks.google, .events([show]))
        try await model.add(name: "Family", link: TestLinks.google)
        #expect(!model.isDue)
        world.clock.now += 299
        #expect(!model.isDue)
        world.clock.now += 1
        #expect(model.isDue)
        await model.refresh()
        #expect(!model.isDue)

        // Events placed for another zone are due at once.
        world.zone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(model.isDue)
        world.zone = TimeZone(identifier: "America/New_York")!

        // A link without events yet is due at once.
        stub.setOffline(true)
        context.insert(CalendarLink(name: "Work", url: TestLinks.icloud, createdAt: world.clock.now))
        try context.save()
        #expect(self.model(context).isDue)
    }

    /// Today's minute loop (`EventsRefreshTrigger.minuteLoop`) never asks
    /// with `force`, whatever state the events are in: its checks are
    /// scheduled, may be answered from the API's cache and go out only when
    /// the events are due.
    @Test func theMinuteLoopNeverForces() async throws {
        #expect(!EventsRefreshTrigger.minuteLoop.force)
        #expect(!EventsRefreshTrigger.zoneChange.force)
        #expect(EventsRefreshTrigger.pull.force)

        let context = try inMemoryContext()
        stub.set(TestLinks.google, .events([show]))
        let model = model(context)
        try await model.add(name: "Family", link: TestLinks.google)
        let before = stub.requests.count
        func turn() async { await model.refresh(force: EventsRefreshTrigger.minuteLoop.force) }

        // Fresh events: nothing is sent.
        await turn()
        #expect(stub.requests.count == before)
        // Stale events, events for another zone, a link without events: each
        // is asked for once, none with `fresh`.
        world.clock.now += EventsModel.refreshInterval
        await turn()
        world.zone = TimeZone(identifier: "America/Los_Angeles")!
        await turn()
        context.insert(CalendarLink(name: "Work", url: TestLinks.icloud, createdAt: world.clock.now))
        try context.save()
        let relaunched = self.model(context)
        await relaunched.refresh(force: EventsRefreshTrigger.minuteLoop.force)
        #expect(stub.requests.count == before + 3)
        #expect(stub.requests.dropFirst(before).allSatisfy { $0.fresh == nil })
    }

    /// A return to the foreground (`EventsRefreshTrigger.returnToForeground`
    /// with `isDue` read as Today does) sends nothing while the events are
    /// fresh, and one fresh request once they are due.
    @Test func aReturnToTheForegroundSendsFreshOnlyWhenDue() async throws {
        #expect(!EventsRefreshTrigger.returnToForeground(isDue: false).force)
        #expect(EventsRefreshTrigger.returnToForeground(isDue: true).force)

        stub.set(TestLinks.google, .events([show]))
        let model = model(try inMemoryContext())
        try await model.add(name: "Family", link: TestLinks.google)
        let before = stub.requests.count
        func comeBack() async {
            let force = EventsRefreshTrigger.returnToForeground(isDue: model.isDue).force
            await model.refresh(force: force)
        }

        world.clock.now += EventsModel.refreshInterval - 1
        await comeBack()
        #expect(stub.requests.count == before)

        world.clock.now += 1
        await comeBack()
        #expect(stub.requests.count == before + 1)
        #expect(stub.requests.last?.fresh == true)

        // Just answered: not due again.
        await comeBack()
        #expect(stub.requests.count == before + 1)
    }

    /// How many calendar requests a launch and a return to the foreground
    /// send with one pasted link, played the way Today makes its calls: the
    /// minute loop's turn and the return's (`isDue` read first), both in
    /// flight at once. Not due: none. Due: two, the loop's scheduled check
    /// and the return's fresh one. Whether iOS also calls the scene-phase
    /// change at launch is the view's business; if it does not, a due
    /// launch sends one (the loop's).
    @Test func requestsSentByALaunchAndAReturnWithOneLink() async throws {
        let context = try inMemoryContext()
        stub.set(TestLinks.google, .events([show]))
        try await model(context).add(name: "Family", link: TestLinks.google)
        let held = HeldCalendarTransport(stub)

        func launchOrReturn(_ model: EventsModel) async -> [Bool?] {
            let before = stub.requests.count
            let force = EventsRefreshTrigger.returnToForeground(isDue: model.isDue).force
            held.setHolding(true)
            let loop = Task { await model.refresh(force: EventsRefreshTrigger.minuteLoop.force) }
            let comeBack = Task { await model.refresh(force: force) }
            let sent = force ? 2 : 0
            if sent > 0 { await held.waitUntilHeld(sent) }
            stub.set(TestLinks.google, .events([show, dentist]))
            held.setHolding(false)
            held.releaseAll()
            await loop.value
            await comeBack.value
            return stub.requests.dropFirst(before).map(\.fresh)
        }

        // A launch 4 minutes after the last answer: nothing.
        world.clock.now += 4 * 60
        let launched = model(context, transport: held)
        #expect(await launchOrReturn(launched).isEmpty)
        // A return 5 minutes after it: two, one of them fresh.
        world.clock.now += 60
        var sent = await launchOrReturn(launched)
        #expect(sent.count == 2)
        #expect(sent.filter { $0 == true }.count == 1)
        // A return a minute later: nothing.
        world.clock.now += 60
        #expect(await launchOrReturn(launched).isEmpty)
        // A launch 5 minutes after the last answer: two, one of them fresh.
        world.clock.now += 4 * 60
        let relaunched = model(context, transport: held)
        sent = await launchOrReturn(relaunched)
        #expect(sent.count == 2)
        #expect(sent.filter { $0 == true }.count == 1)
    }

    /// On a return to the foreground the minute loop's own check and the
    /// return's fresh one can both be in flight. The scheduled answer, which
    /// may come from the API's cache, never replaces the fresh one, whichever
    /// lands first.
    @Test func aScheduledAnswerThatLandsAfterAFreshOneIsDropped() async throws {
        stub.set(TestLinks.google, .events([show]))
        let held = HeldCalendarTransport(stub)
        let model = model(try inMemoryContext(), transport: held)
        try await model.add(name: "Family", link: TestLinks.google)
        world.clock.now += EventsModel.refreshInterval

        // The scheduled check goes out and is held with the old events...
        held.setHolding(true)
        let scheduled = Task { await model.refresh() }
        await held.waitUntilHeld(1)
        // ...the fresh one goes out after it and lands first.
        held.setHolding(false)
        stub.set(TestLinks.google, .events([show, dentist]))
        await model.refresh(force: true)
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])

        held.releaseAll()
        await scheduled.value
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
        #expect(stub.requests.suffix(2).map(\.fresh) == [nil, true])
    }

    /// A scheduled answer that lands while the fresh request is still in
    /// flight is shown (that request may yet fail), and the fresh answer
    /// replaces it when it lands.
    @Test func aScheduledAnswerThatLandsWhileAFreshOneIsInFlightIsShownUntilTheFreshOneLands() async throws {
        stub.set(TestLinks.google, .events([show]))
        let held = HeldCalendarTransport(stub)
        let model = model(try inMemoryContext(), transport: held)
        try await model.add(name: "Family", link: TestLinks.google)
        world.clock.now += EventsModel.refreshInterval

        // The pull's fresh request is held with the new events...
        held.setHolding(true)
        stub.set(TestLinks.google, .events([show, dentist]))
        let pull = Task { await model.refresh(force: true) }
        await held.waitUntilHeld(1)
        // ...while a scheduled check goes out and lands at once with another
        // copy: it is shown for now.
        held.setHolding(false)
        stub.set(TestLinks.google, .events([show, lunch]))
        await model.refresh()
        #expect(stub.requests.count == 3)
        #expect(times(model) == ["8:25PM Hanna's show", "TUE 12:00PM Lunch"])

        held.releaseAll()
        await pull.value
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])

        // With nothing fresh in flight a scheduled answer is shown as usual.
        world.clock.now += EventsModel.refreshInterval
        await model.refresh()
        #expect(times(model) == ["8:25PM Hanna's show", "TUE 12:00PM Lunch"])
    }

    /// The return's fresh request is refused (the API's 429): the minute
    /// loop's scheduled answer, which overlapped it, is still shown.
    @Test func aScheduledAnswerIsKeptWhenTheFreshRequestFails() async throws {
        stub.set(TestLinks.google, .events([show]))
        let held = HeldCalendarTransport(stub)
        let limiter = RateLimitTransport(held)
        let model = model(try inMemoryContext(), transport: limiter)
        try await model.add(name: "Family", link: TestLinks.google)
        world.clock.now += EventsModel.refreshInterval

        // The scheduled check goes out and is held with the new events...
        held.setHolding(true)
        stub.set(TestLinks.google, .events([show, dentist]))
        let scheduled = Task { await model.refresh() }
        await held.waitUntilHeld(1)
        // ...the fresh one goes out after it and is refused.
        limiter.limit(retryAfter: "60")
        await model.refresh(force: true)
        #expect(limiter.count("postCalendarEvents") == 3)
        #expect(model.retryNotBefore != nil)
        #expect(times(model) == ["8:25PM Hanna's show"])

        limiter.lift()
        held.releaseAll()
        await scheduled.value
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
    }

    /// A fresh answer for more links than a scheduled request asked for (a
    /// link added since, then removed) holds newer events for the scheduled
    /// request's links: the late scheduled answer does not replace them.
    @Test func aFreshAnswerForMoreLinksOvertakesAnOlderScheduledOne() async throws {
        stub.set(TestLinks.google, .events([show]))
        let held = HeldCalendarTransport(stub)
        let model = model(try inMemoryContext(), transport: held)
        try await model.add(name: "Family", link: TestLinks.google)
        world.clock.now += EventsModel.refreshInterval

        // A scheduled check for Family alone is held with the old events.
        held.setHolding(true)
        let scheduled = Task { await model.refresh() }
        await held.waitUntilHeld(1)
        held.setHolding(false)

        // Work is added, a pull reads both again, and Work is removed.
        world.clock.now += 1
        stub.set(TestLinks.icloud, .events([lunch]))
        try await model.add(name: "Work", link: TestLinks.icloud)
        stub.set(TestLinks.google, .events([show, dentist]))
        await model.refresh(force: true)
        #expect(stub.requests.last?.fresh == true)
        await model.remove(model.links[1])
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])

        held.releaseAll()
        await scheduled.value
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
    }

    /// A fresh answer that was not shown (a link was removed while it was in
    /// flight) does not hold back the scheduled answer for the links left.
    @Test func aFreshAnswerThatWasNotShownDoesNotHideAScheduledOne() async throws {
        stub.set(TestLinks.google, .events([show]))
        stub.set(TestLinks.icloud, .events([lunch]))
        let held = HeldCalendarTransport(stub)
        let model = model(try inMemoryContext(), transport: held)
        try await model.add(name: "Family", link: TestLinks.google)
        world.clock.now += 1
        try await model.add(name: "Work", link: TestLinks.icloud)
        world.clock.now += EventsModel.refreshInterval

        // The pull for both is held...
        held.setHolding(true)
        stub.set(TestLinks.google, .events([show, dentist]))
        let pull = Task { await model.refresh(force: true) }
        await held.waitUntilHeld(1)
        // ...Work is removed and the scheduled check for Family is held too.
        let removal = Task { await model.remove(model.links[1]) }
        await held.waitUntilHeld(2)
        #expect(times(model) == ["8:25PM Hanna's show"])

        // The pull lands first, for links no longer listed, and is not shown.
        held.releaseFirst()
        await pull.value
        #expect(times(model) == ["8:25PM Hanna's show"])
        held.releaseAll()
        await removal.value
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
        #expect(stub.requests.suffix(2).map(\.fresh) == [true, nil])
    }

    /// A fresh request for another zone does not hold back the answer for
    /// the new one: the zone changes during a pull, the pull's answer lands
    /// first and is out of date, and the new zone's events show.
    @Test func aFreshRequestForAnotherZoneDoesNotHideTheNewZonesAnswer() async throws {
        stub.set(TestLinks.google, .events([show]))
        let held = HeldCalendarTransport(stub)
        let model = model(try inMemoryContext(), transport: held)
        try await model.add(name: "Family", link: TestLinks.google)

        held.setHolding(true)
        let pull = Task { await model.refresh(force: true) }
        await held.waitUntilHeld(1)
        world.zone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduled = Task { await model.refresh() }
        await held.waitUntilHeld(2)
        #expect(stub.requests.last == .init(links: [TestLinks.google], timezone: "America/Los_Angeles"))

        // The pull's answer, for New York, lands first and is not shown.
        held.releaseFirst()
        await pull.value
        #expect(times(model).isEmpty)
        held.releaseAll()
        await scheduled.value
        #expect(model.snapshot?.timezone == "America/Los_Angeles")
        #expect(times(model) == ["5:25PM Hanna's show"])
    }

    /// New York, then Los Angeles (with a pull), then New York again, whose
    /// request fails: Today is empty, and the scheduled New York answer sent
    /// before all this is shown when it lands.
    @Test func aScheduledAnswerFillsAnEmptyTodayAfterTheZoneComesBack() async throws {
        stub.set(TestLinks.google, .events([show]))
        let held = HeldCalendarTransport(stub)
        let model = model(try inMemoryContext(), transport: held)
        try await model.add(name: "Family", link: TestLinks.google)
        world.clock.now += EventsModel.refreshInterval

        held.setHolding(true)
        stub.set(TestLinks.google, .events([show, dentist]))
        let scheduled = Task { await model.refresh() }
        await held.waitUntilHeld(1)
        held.setHolding(false)

        world.zone = TimeZone(identifier: "America/Los_Angeles")!
        await model.refresh(force: true)
        #expect(model.snapshot?.timezone == "America/Los_Angeles")

        world.zone = TimeZone(identifier: "America/New_York")!
        stub.setOffline(true)
        await model.refresh()
        #expect(times(model).isEmpty)

        held.releaseAll()
        await scheduled.value
        #expect(times(model) == ["8:25PM Hanna's show", "MON 9:00AM Dentist"])
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

    /// The zip is in New York and the phone in Tokyo, set to 24-hour time:
    /// the times are New York's, written the phone's way.
    @Test func theZipsZoneInTheTwentyFourHourForm() async throws {
        let context = try inMemoryContext()
        let now = world.clock.now
        let today = TodayModel(api: stubbedSkyAPI(), context: context, now: { now })
        try await today.saveZip("10001")
        world.zone = EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: TimeZone(identifier: "Asia/Tokyo")!)

        stub.set(TestLinks.google, .events([show, dentist, trip]))
        let model = model(context)
        try await model.add(name: "Family", link: TestLinks.google)
        #expect(times(model, clock: .twentyFourHour) == ["20:25 Hanna's show", "MON 09:00 Dentist", "WED ALL DAY Trip"])
        #expect(times(model, clock: .twelveHour) == ["8:25PM Hanna's show", "MON 9:00AM Dentist", "WED ALL DAY Trip"])
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

    /// Task 172: the mic and speech recognition are the only permissions the
    /// app declares, worded truthfully; still no calendar, reminders,
    /// contacts or location key.
    @Test func infoPlistDeclaresOnlyTheMicAndSpeechRecognition() {
        let info = Bundle.main.infoDictionary ?? [:]
        let usage = info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
        #expect(usage == ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"])
        #expect(info["NSMicrophoneUsageDescription"] as? String == "Seasign listens when you tap the mic to add a calendar event.")
        #expect(info["NSSpeechRecognitionUsageDescription"] as? String == "Seasign turns what you say into a calendar event. It only uses on-device recognition, so your speech stays on this iPhone.")
        #expect(!info.keys.contains { key in
            ["NSCalendars", "NSReminders", "NSLocation", "NSContacts"].contains { key.hasPrefix($0) }
        })
    }
}
