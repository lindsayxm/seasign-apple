import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftData
import Testing

@testable import Seasign

// MARK: - Pure rules

@Suite struct DayScheduleTests {
    private let link = UUID()
    private let other = UUID()

    private func event(_ title: String, _ start: String, _ end: String, allDay: Bool = false, date: String? = nil, link: UUID? = nil) -> UpcomingEvent {
        UpcomingEvent(link: link ?? self.link, title: title, start: instant(start), end: instant(end), allDay: allDay, date: date)
    }

    @Test func allDayEventsComeFirstThenByStartEvenBeforeAnEventFromTheNightBefore() {
        let ordered = DayOrder.ordered([
            event("Lunch", "2026-11-19T18:30:00Z", "2026-11-19T19:30:00Z"),
            event("Late show", "2026-11-19T04:00:00Z", "2026-11-19T07:00:00Z"),
            event("Market", "2026-11-19T06:00:00Z", "2026-11-20T06:00:00Z", allDay: true, date: "2026-11-19"),
            event("B", "2026-11-19T14:00:00Z", "2026-11-19T15:00:00Z"),
            event("A", "2026-11-19T14:00:00Z", "2026-11-19T15:00:00Z"),
            event("Trip", "2026-11-18T06:00:00Z", "2026-11-21T06:00:00Z", allDay: true, date: "2026-11-18"),
        ])
        #expect(ordered.map(\.title) == ["Trip", "Market", "Late show", "A", "B", "Lunch"])
    }

    @Test func anEndBeforeTheStartIsKeptAsAnEventWithoutALength() throws {
        let answer = CalendarAnswer(
            events: [.init(calendar: 0, title: "Floating", start: instant("2026-11-19T20:00:00Z"), end: instant("2026-11-19T19:30:00Z"), allDay: false)],
            calendars: [.init(index: 0, ok: true, partial: false)]
        )
        let day = DaySchedule.links(answer, ids: [link], day: "2026-11-19", timezone: "America/Chicago", previous: nil, now: instant("2026-11-19T18:00:00Z"))
        let floating = try #require(day.events.first)
        #expect(floating.end == floating.start)
        // Not over before it starts (the raw end would say it was), over once it has.
        #expect(!floating.hasEnded(at: instant("2026-11-19T19:45:00Z")))
        #expect(floating.hasEnded(at: instant("2026-11-19T20:00:01Z")))
    }

    @Test func endedEventsAreKept() {
        let answer = CalendarAnswer(
            events: [.init(calendar: 0, title: "Breakfast", start: instant("2026-11-19T14:00:00Z"), end: instant("2026-11-19T15:00:00Z"), allDay: false)],
            calendars: [.init(index: 0, ok: true, partial: false)]
        )
        let day = DaySchedule.links(answer, ids: [link], day: "2026-11-19", timezone: "UTC", previous: nil, now: instant("2026-11-19T23:00:00Z"))
        #expect(day.events.map(\.title) == ["Breakfast"])
        #expect(day.failed.isEmpty)
    }

    @Test func passingFailuresCarryTheSameDaysEventsOthersDropThem() {
        let previous = DaySourceSnapshot(
            day: "2026-11-19", timezone: "UTC",
            events: [
                event("Kept", "2026-11-19T10:00:00Z", "2026-11-19T11:00:00Z"),
                event("Dropped", "2026-11-19T10:00:00Z", "2026-11-19T11:00:00Z", link: other),
            ],
            failed: [], fetchedAt: instant("2026-11-19T09:00:00Z")
        )
        let answer = CalendarAnswer(events: [], calendars: [
            .init(index: 0, ok: false, partial: false, error: .timeout),
            .init(index: 1, ok: false, partial: false, error: .notCalendar),
        ])
        let now = instant("2026-11-19T12:00:00Z")
        let same = DaySchedule.links(answer, ids: [link, other], day: "2026-11-19", timezone: "UTC", previous: previous, now: now)
        #expect(same.events.map(\.title) == ["Kept"])
        #expect(same.failed == [link, other])
        // Nothing is carried into another day or zone.
        let nextDay = DaySchedule.links(answer, ids: [link, other], day: "2026-11-20", timezone: "UTC", previous: previous, now: now)
        #expect(nextDay.events.isEmpty)
        let otherZone = DaySchedule.links(answer, ids: [link, other], day: "2026-11-19", timezone: "America/Chicago", previous: previous, now: now)
        #expect(otherZone.events.isEmpty)
        // A source the answer says nothing about counts as a passing failure.
        let silent = DaySchedule.google(
            GoogleEventsAnswer(events: [], calendars: []), ids: [link], day: "2026-11-19", timezone: "UTC", previous: previous, now: now
        )
        #expect(silent.events.map(\.title) == ["Kept"])
        #expect(silent.failed == [link])
    }

    @Test func refreshGating() {
        let now = instant("2026-11-19T12:00:00Z")
        let key = "2026-11-19 UTC"
        func due(force: Bool = false, askedFor: String? = key, askedAt: Date? = now, interval: TimeInterval = 300, hold: Date? = nil, at: Date = now) -> Bool {
            DayRefresh.isDue(force: force, askedFor: askedFor, current: key, askedAt: askedAt, interval: interval, hold: hold, now: at)
        }
        #expect(due(askedFor: nil, askedAt: nil))
        #expect(!due(at: now.addingTimeInterval(299)))
        #expect(due(at: now.addingTimeInterval(300)))
        #expect(due(force: true))
        // A new day or zone asks at once.
        #expect(due(askedFor: "2026-11-18 UTC"))
        // A hold holds back even a forced ask, until it ends.
        #expect(!due(force: true, hold: now.addingTimeInterval(10)))
        #expect(!due(askedFor: nil, hold: now.addingTimeInterval(10)))
        #expect(due(force: true, hold: now.addingTimeInterval(10), at: now.addingTimeInterval(10)))
    }
}

// MARK: - The model

/// Answers each request from `answer`, which gets the request's number
/// (from 0) and may move the clock (a request that crosses midnight).
private final class ScriptedCalendarTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private(set) var days: [String?] = []
    private let answer: @Sendable (Int) -> (HTTPResponse.Status, String)

    init(answer: @escaping @Sendable (Int) -> (HTTPResponse.Status, String)) {
        self.answer = answer
    }

    var requests: Int { lock.withLock { count } }
    var askedDays: [String?] { lock.withLock { days } }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var day: String?
        if let body {
            let data = try await Data(collecting: body, upTo: 1 << 20)
            day = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["day"] as? String
        }
        let number = lock.withLock { () -> Int in
            days.append(day)
            defer { count += 1 }
            return count
        }
        let (status, json) = answer(number)
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

/// The time zone the events are asked in, as a test changes it.
@MainActor
private final class Zone {
    var value = TimeZone(identifier: "America/Chicago")!
}

@Suite @MainActor struct DayModelTests {
    private let endpoint = FakeGoogleEndpoint()
    private let googleStub = GoogleAPIStub()
    private let linkStub = CalendarStub()
    /// Noon on Thursday 19 November 2026 in Chicago.
    private let clock = TestClock(instant("2026-11-19T18:00:00Z"))
    private let zone = Zone()

    private let lateShow = StubEvent(title: "Late show", start: "2026-11-19T04:00:00Z", end: "2026-11-19T07:00:00Z")
    private let lunch = StubEvent(title: "Lunch", start: "2026-11-19T18:30:00Z", end: "2026-11-19T19:30:00Z")
    private let floating = StubEvent(title: "Floating", start: "2026-11-19T20:00:00Z", end: "2026-11-19T19:30:00Z")

    // MARK: Set-up

    private func googleModel(_ context: ModelContext) -> GoogleCalendarModel {
        let clock = clock
        let zone = zone
        return GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: googleStub),
            context: context,
            config: FakeGoogle.config,
            tokens: InMemoryGoogleTokenStore(),
            http: endpoint.http,
            timeZone: { zone.value },
            now: { clock.now }
        )
    }

    /// Connected, with the primary calendar on; Today's first poll shows Coffee.
    private func connectedGoogle(_ context: ModelContext) async -> GoogleCalendarModel {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens())
        // The access token runs out after an hour of test time; renewing it works.
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil))
        googleStub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars([("me@example.test", "Me", true)]))
        googleStub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events(
            [(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil]
        ))
        let model = googleModel(context)
        await model.connect { url, scheme in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?state=\(state)&code=\(FakeGoogle.code)&scope=x")!
        }
        #expect(model.connection == .connected)
        return model
    }

    private func eventsModel(_ context: ModelContext, links: [String], api: SeasignAPI? = nil) throws -> EventsModel {
        for (index, link) in links.enumerated() {
            context.insert(CalendarLink(name: "Link \(index)", url: link, createdAt: clock.now.addingTimeInterval(TimeInterval(index))))
        }
        try context.save()
        let clock = clock
        let zone = zone
        return EventsModel(api: api ?? stubbedCalendarAPI(linkStub), context: context, timeZone: { zone.value }, now: { clock.now })
    }

    private func dayModel(
        events: EventsModel, google: GoogleCalendarModel, api: SeasignAPI? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> DayModel {
        let clock = clock
        let zone = zone
        return DayModel(
            api: api ?? stubbedCalendarAPI(linkStub), events: events, google: google,
            timeZone: { zone.value }, now: { clock.now }, sleep: sleep
        )
    }

    /// The Google day answer for the primary calendar: an all-day event, one
    /// that has ended by noon and one to come.
    private func answerGoogleDay(failing: String? = nil) {
        let events: [[String: Any]] = [
            ["calendar": 0, "title": "Farmers' market", "start": "2026-11-19T06:00:00Z", "end": "2026-11-20T06:00:00Z", "allDay": true, "date": "2026-11-19"],
            ["calendar": 0, "title": "Breakfast", "start": "2026-11-19T14:00:00Z", "end": "2026-11-19T15:00:00Z", "allDay": false],
            ["calendar": 0, "title": "Coffee", "start": "2026-11-19T19:00:00Z", "end": "2026-11-19T19:30:00Z", "allDay": false],
        ]
        var status: [String: Any] = ["index": 0, "ok": failing == nil, "partial": false]
        status["error"] = failing
        let data = try! JSONSerialization.data(withJSONObject: ["events": failing == nil ? events : [], "calendars": [status]])
        googleStub.answer(GoogleAPIStub.postEvents, .init(status: .ok, json: String(decoding: data, as: UTF8.self)))
    }

    private func titles(_ day: DayModel) -> [String] {
        day.rows(now: clock.now, clock: .twelveHour).map(\.event.title)
    }

    private func dayRequests() -> [GoogleAPIStub.Seen] {
        googleStub.seen.filter { $0.operationID == GoogleAPIStub.postEvents && $0.day != nil }
    }

    // MARK: Tests

    @Test func mergesBothSourcesAllDayFirstWithEndedEventsInTheEventsZone() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        linkStub.set(TestLinks.google, .events([lunch, lateShow, floating]))
        let events = try eventsModel(context, links: [TestLinks.google])
        answerGoogleDay()
        let day = dayModel(events: events, google: google)

        await day.refresh(force: true)

        #expect(titles(day) == ["Farmers' market", "Late show", "Breakfast", "Lunch", "Coffee", "Floating"])
        let rows = day.rows(now: clock.now, clock: .twelveHour)
        #expect(rows.filter(\.hasEnded).map(\.event.title) == ["Late show", "Breakfast"])
        // Times as Today words them, in Chicago.
        #expect(rows.map(\.label.time) == ["ALL DAY", "10:00PM", "8:00AM", "12:30PM", "1:00PM", "2:00PM"])
        #expect(day.problem(now: clock.now) == nil)
        #expect(!day.isWaiting(now: clock.now))
        // Both asked for the day in the events' zone.
        #expect(linkStub.requests.last == CalendarStub.Request(links: [TestLinks.google], timezone: "America/Chicago", day: "2026-11-19"))
        #expect(dayRequests().map(\.day) == ["2026-11-19"])
        #expect(dayRequests().first?.timezone == "America/Chicago")
        #expect(dayRequests().first?.token == FakeGoogle.access)
    }

    @Test func theDayIsTheEventsZonesDayAndAZoneChangeAsksAgain() async throws {
        // 21:00 on the 19th in Chicago, already the 20th in UTC.
        clock.now = instant("2026-11-20T03:00:00Z")
        let context = try inMemoryContext()
        let google = googleModel(context)
        linkStub.set(TestLinks.google, .events([]))
        let events = try eventsModel(context, links: [TestLinks.google])
        let day = dayModel(events: events, google: google)

        await day.refresh()
        #expect(linkStub.requests.map(\.day) == ["2026-11-19"])
        #expect(day.links?.day == "2026-11-19")

        zone.value = .gmt
        // What was read for Chicago is not shown for UTC.
        #expect(day.isWaiting(now: clock.now))
        await day.refresh()
        #expect(linkStub.requests.map(\.day) == ["2026-11-19", "2026-11-20"])
        #expect(linkStub.requests.last?.timezone == "GMT")
    }

    @Test func todaysModelsSnapshotsAndRequestsAreUntouched() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        linkStub.set(TestLinks.google, .events([lunch, lateShow]))
        let events = try eventsModel(context, links: [TestLinks.google])
        await events.refresh()
        // Today's own requests still send no day.
        #expect(linkStub.requests.map(\.day) == [nil])
        #expect(googleStub.seen.filter { $0.operationID == GoogleAPIStub.postEvents }.map(\.day) == [nil])

        let googleSnapshot = google.snapshot
        let linksSnapshot = events.snapshot
        let cached = try context.fetch(FetchDescriptor<CachedGoogleEvents>()).map(\.payload)
        let labels = TodayEvents.labels(
            links: events.upcoming(now: clock.now), google: google.upcoming(now: clock.now),
            now: clock.now, timeZone: zone.value, clock: .twelveHour
        )

        answerGoogleDay()
        let day = dayModel(events: events, google: google)
        await day.refresh(force: true)
        #expect(titles(day).contains("Breakfast"))

        #expect(google.snapshot == googleSnapshot)
        #expect(events.snapshot == linksSnapshot)
        #expect(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).map(\.payload) == cached)
        // Today's next three: still only what has not ended, soonest first.
        let after = TodayEvents.labels(
            links: events.upcoming(now: clock.now), google: google.upcoming(now: clock.now),
            now: clock.now, timeZone: zone.value, clock: .twelveHour
        )
        #expect(after == labels)
        #expect(after.map(\.title) == ["Lunch", "Coffee"])
    }

    @Test func aFailedSourceKeepsWhatIsShownAndSaysSo() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        linkStub.set(TestLinks.google, .events([lunch]))
        let events = try eventsModel(context, links: [TestLinks.google])
        answerGoogleDay()
        let day = dayModel(events: events, google: google)
        await day.refresh(force: true)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Lunch", "Coffee"])

        // The links' request fails as a whole.
        linkStub.setOffline(true)
        await day.refreshLinks(force: true)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Lunch", "Coffee"])
        #expect(day.problem(now: clock.now) == .links)

        // Google's request fails as a whole too: handled as Today's poll
        // would (a back-off), and what is shown stays.
        googleStub.setOffline(true)
        await day.refreshGoogle(force: true)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Lunch", "Coffee"])
        #expect(day.problem(now: clock.now) == .both)
        #expect(google.statusProblem == .unavailable)

        // Both answer again.
        linkStub.setOffline(false)
        googleStub.setOffline(false)
        clock.advance(GooglePoll.backoff(failures: 1))
        await day.refresh(force: true)
        #expect(day.problem(now: clock.now) == nil)

        // One link read in a passing way keeps its events; one that is not
        // a calendar any more loses them. Both show the line.
        linkStub.set(TestLinks.google, .failure("timeout"))
        await day.refreshLinks(force: true)
        #expect(titles(day).contains("Lunch"))
        #expect(day.problem(now: clock.now) == .links)
        linkStub.set(TestLinks.google, .failure("not_calendar"))
        await day.refreshLinks(force: true)
        #expect(!titles(day).contains("Lunch"))
        #expect(day.problem(now: clock.now) == .links)

        // A Google calendar that could not be read shows the line too.
        answerGoogleDay(failing: "forbidden")
        await day.refreshGoogle(force: true)
        #expect(day.problem(now: clock.now) == .both)
        #expect(!titles(day).contains("Coffee"))
    }

    @Test func refreshGatingGoogleEachTurnLinksEveryFiveMinutes() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        linkStub.set(TestLinks.google, .events([lunch]))
        let events = try eventsModel(context, links: [TestLinks.google])
        answerGoogleDay()
        let day = dayModel(events: events, google: google)

        await day.refresh(force: true)
        #expect(linkStub.requests.count == 1)
        #expect(dayRequests().count == 1)

        // Too soon for either.
        clock.advance(2)
        await day.refresh()
        #expect(linkStub.requests.count == 1)
        #expect(dayRequests().count == 1)

        // A turn later Google is asked, the links are not.
        clock.advance(3)
        await day.refresh()
        #expect(dayRequests().count == 2)
        #expect(linkStub.requests.count == 1)

        // Five minutes after the links were read, they are.
        clock.advance(DayRefresh.linksInterval - 5)
        await day.refresh()
        #expect(linkStub.requests.count == 2)
        #expect(dayRequests().count == 3)

        // Opening again (or coming back) asks both at once.
        await day.refresh(force: true)
        #expect(linkStub.requests.count == 3)
        #expect(dayRequests().count == 4)

        // The date turns over: both are asked for the new day, and what was
        // read for yesterday is not shown.
        clock.now = instant("2026-11-20T06:00:01Z")
        #expect(titles(day).isEmpty)
        await day.refresh()
        #expect(linkStub.requests.last?.day == "2026-11-20")
        #expect(dayRequests().last?.day == "2026-11-20")
    }

    @Test func aGoogleHoldHoldsTheDayScreenBack() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        // Our API's 429 on the day request: Today's hold applies to both.
        googleStub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"))
        let day = dayModel(events: events, google: google)
        await day.refreshGoogle(force: true)
        #expect(dayRequests().count == 1)
        #expect(google.statusProblem == .rateLimited)
        answerGoogleDay()
        clock.advance(10)
        await day.refreshGoogle(force: true)
        #expect(dayRequests().count == 1)
        clock.advance(21)
        await day.refreshGoogle(force: true)
        #expect(dayRequests().count == 2)
        #expect(titles(day).contains("Coffee"))
    }

    @Test func aRefusalJustAfterMidnightAsksAgainForTheNewDay() async throws {
        // 23:59:59 on the 19th in Chicago; the request arrives after midnight.
        let clock = clock
        clock.now = instant("2026-11-20T05:59:59Z")
        let refused = #"{"error":"invalid_request","message":"Made-up message."}"#
        let answer = #"{"events":[{"calendar":0,"title":"Early","start":"2026-11-20T07:00:00Z","end":"2026-11-20T08:00:00Z","allDay":false}],"calendars":[{"index":0,"ok":true,"partial":false}]}"#
        let transport = ScriptedCalendarTransport { number in
            if number == 0 {
                clock.advance(2)
                return (.badRequest, refused)
            }
            return (.ok, answer)
        }
        let context = try inMemoryContext()
        let api = SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: transport)
        let events = try eventsModel(context, links: [TestLinks.google], api: api)
        let day = dayModel(events: events, google: googleModel(context), api: api)

        await day.refreshLinks(force: true)
        #expect(transport.askedDays == ["2026-11-19", "2026-11-20"])
        #expect(day.links?.day == "2026-11-20")
        #expect(titles(day) == ["Early"])
        #expect(day.problem(now: clock.now) == nil)
    }

    @Test func aRefusalForTheSameDayIsAFailureAndWaits() async throws {
        let refused = #"{"error":"invalid_request","message":"Made-up message."}"#
        let transport = ScriptedCalendarTransport { _ in (.badRequest, refused) }
        let context = try inMemoryContext()
        let api = SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: transport)
        let events = try eventsModel(context, links: [TestLinks.google], api: api)
        let google = await connectedGoogle(context)
        googleStub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.error(.badRequest, "invalid_request"))
        let day = dayModel(events: events, google: google, api: api)

        await day.refresh(force: true)
        // Asked once each: the date did not change, so not again.
        #expect(transport.requests == 1)
        #expect(dayRequests().count == 1)
        #expect(day.problem(now: clock.now) == .both)
        // Today's poll is not put into back-off by the day's refusal.
        #expect(google.statusProblem == nil)
        #expect(google.retryNotBefore == nil)

        clock.advance(DayRefresh.refusedHold - 1)
        await day.refresh(force: true)
        #expect(transport.requests == 1)
        #expect(dayRequests().count == 1)
        clock.advance(1)
        await day.refresh(force: true)
        #expect(transport.requests == 2)
        #expect(dayRequests().count == 2)
    }

    @Test func nothingIsAskedWithoutCalendarsAndTheScreenSaysSo() async throws {
        let context = try inMemoryContext()
        let events = try eventsModel(context, links: [])
        let day = dayModel(events: events, google: googleModel(context))
        await day.refresh(force: true)
        #expect(linkStub.requests.isEmpty)
        #expect(googleStub.seen.isEmpty)
        #expect(!day.hasCalendars)
        #expect(!day.isWaiting(now: clock.now))
        #expect(day.problem(now: clock.now) == nil)
        #expect(titles(day).isEmpty)
    }

    @Test func theLoopAsksOnStartThenEachTurnAndStopsWhenCancelled() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        linkStub.set(TestLinks.google, .events([lunch]))
        let events = try eventsModel(context, links: [TestLinks.google])
        answerGoogleDay()
        let clock = clock
        // Each turn's wait moves the clock on by the real tick.
        let day = dayModel(events: events, google: google) { _ in
            try? await Task.sleep(for: .milliseconds(5))
            clock.advance(5)
        }

        let running = Task { await day.run() }
        for _ in 0..<400 where dayRequests().count < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(dayRequests().count >= 4)
        running.cancel()
        await running.value
        let google0 = dayRequests().count
        let links0 = linkStub.requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(dayRequests().count == google0)
        #expect(linkStub.requests.count == links0)
        // The links were asked when it started, not on each turn.
        #expect(links0 == 1)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Lunch", "Coffee"])
    }
}
