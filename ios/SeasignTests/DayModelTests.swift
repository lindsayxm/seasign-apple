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
        googleStub.answer(GoogleAPIStub.postEvents, googleDay(failing: failing))
    }

    private func googleDay(failing: String? = nil) -> GoogleAPIStub.Answer {
        let events: [[String: Any]] = [
            ["calendar": 0, "title": "Farmers' market", "start": "2026-11-19T06:00:00Z", "end": "2026-11-20T06:00:00Z", "allDay": true, "date": "2026-11-19"],
            ["calendar": 0, "title": "Breakfast", "start": "2026-11-19T14:00:00Z", "end": "2026-11-19T15:00:00Z", "allDay": false],
            ["calendar": 0, "title": "Coffee", "start": "2026-11-19T19:00:00Z", "end": "2026-11-19T19:30:00Z", "allDay": false],
        ]
        var status: [String: Any] = ["index": 0, "ok": failing == nil, "partial": false]
        status["error"] = failing
        let data = try! JSONSerialization.data(withJSONObject: ["events": failing == nil ? events : [], "calendars": [status]])
        return .init(status: .ok, json: String(decoding: data, as: UTF8.self))
    }

    /// Our API's 429 on the Google events route, asking to wait `seconds`.
    private func googleLimited(_ seconds: Int) -> GoogleAPIStub.Answer {
        GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: String(seconds))
    }

    /// Whether `task` ends within `seconds` of real time; it is never awaited unbounded.
    private func finishes(_ task: Task<Void, Never>, within seconds: Int = 5) async -> Bool {
        let done = Task { await task.value; return true }
        return await PushDeadline.race(done, deadline: .seconds(seconds), fallback: false)
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
        // A forced ask (the screen opened) has the links read again (`fresh`).
        #expect(linkStub.requests.last == CalendarStub.Request(links: [TestLinks.google], timezone: "America/Chicago", fresh: true, day: "2026-11-19"))
        #expect(dayRequests().map(\.day) == ["2026-11-19"])
        #expect(dayRequests().first?.timezone == "America/Chicago")
        #expect(dayRequests().first?.token == FakeGoogle.access)
    }

    // MARK: The empty-day line (#170 review, done in task 171)

    @Test func theDayIsCalledEmptyOnlyWhenEverySourceHasAnswered() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [TestLinks.google])
        let day = dayModel(events: events, google: google)
        // Google answers an empty day; the links fail with nothing read.
        googleStub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        linkStub.setOffline(true)
        await day.refresh(force: true)
        #expect(titles(day).isEmpty)
        #expect(day.problem(now: clock.now) == .links)
        #expect(!day.everySourceAnswered(now: clock.now))
        #expect(day.emptyLine(now: clock.now) == nil)

        // Google fails too, with nothing read from the links either.
        googleStub.setOffline(true)
        let fresh = dayModel(events: events, google: google)
        clock.advance(GooglePoll.backoff(failures: 1))
        await fresh.refreshLinks(force: true)
        await fresh.refreshGoogle(force: true)
        #expect(fresh.problem(now: clock.now) == .both)
        #expect(fresh.emptyLine(now: clock.now) == nil)

        // Once both have answered, an empty day is said to be empty.
        linkStub.setOffline(false)
        googleStub.setOffline(false)
        linkStub.set(TestLinks.google, .events([]))
        clock.advance(GooglePoll.backoff(failures: 2))
        await day.refresh(force: true)
        #expect(day.problem(now: clock.now) == nil)
        #expect(day.emptyLine(now: clock.now) == "Nothing on your calendar today.")

        // Both answer, but a calendar in each could not be read: not empty either.
        googleStub.answer(GoogleAPIStub.postEvents, googleDay(failing: "timeout"))
        linkStub.set(TestLinks.google, .failure("timeout"))
        clock.advance(10)
        await day.refresh(force: true)
        #expect(day.everySourceAnswered(now: clock.now))
        #expect(titles(day).isEmpty)
        #expect(day.problem(now: clock.now) == .both)
        #expect(day.emptyLine(now: clock.now) == nil)
    }

    // MARK: An event added from the screen (task 171)

    @Test func anAddedEventShowsAtOnceUntilGoogleAnswersForIt() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        answerGoogleDay()
        let day = dayModel(events: events, google: google)
        await day.refreshGoogle(force: true)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Coffee"])
        let calendar = try #require(google.chosen.first)

        // Added for 3 pm today: shown at once, in order.
        let meeting = UpcomingEvent(
            link: calendar.id, title: "Meeting with Rahaf",
            start: instant("2026-11-19T21:00:00Z"), end: instant("2026-11-19T22:00:00Z"), allDay: false
        )
        day.showAdded(meeting)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Coffee", "Meeting with Rahaf"])
        // An event for tomorrow is not on today's screen.
        day.showAdded(UpcomingEvent(
            link: calendar.id, title: "Tomorrow's call",
            start: instant("2026-11-20T21:00:00Z"), end: instant("2026-11-20T22:00:00Z"), allDay: false
        ))
        #expect(!titles(day).contains("Tomorrow's call"))

        // Google's next answer has it: shown once.
        var withMeeting = googleDay()
        withMeeting.json = withMeeting.json.replacingOccurrences(
            of: #""events":["#,
            with: #""events":[{"calendar":0,"title":"Meeting with Rahaf","start":"2026-11-19T21:00:00Z","end":"2026-11-19T22:00:00Z","allDay":false},"#
        )
        googleStub.answer(GoogleAPIStub.postEvents, withMeeting)
        clock.advance(10)
        await day.refreshGoogle(force: true)
        #expect(titles(day).filter { $0 == "Meeting with Rahaf" }.count == 1)
        #expect(day.added.isEmpty)

        // An answer asked for after an add speaks for it (the event was
        // deleted elsewhere, say): it goes.
        day.showAdded(meeting)
        answerGoogleDay()
        clock.advance(10)
        await day.refreshGoogle(force: true)
        #expect(!titles(day).contains("Meeting with Rahaf"))
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
        #expect(await finishes(running))
        let google0 = dayRequests().count
        let links0 = linkStub.requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(dayRequests().count == google0)
        #expect(linkStub.requests.count == links0)
        // The links were asked when it started, not on each turn.
        #expect(links0 == 1)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Lunch", "Coffee"])
    }

    // MARK: Review fixes (M1, L1, L2, L3, L5)

    /// M1: our API's 429 on the day request for the links is Today's hold
    /// too, so neither a reopened day screen nor Today asks before Retry-After.
    @Test func aLinks429OnTheDayHoldsTodayAndAReopenedDayScreen() async throws {
        let context = try inMemoryContext()
        linkStub.set(TestLinks.google, .events([lunch]))
        let limiter = RateLimitTransport(linkStub)
        let api = stubbedAPI(limiter)
        let events = try eventsModel(context, links: [TestLinks.google], api: api)
        let google = googleModel(context)
        limiter.limit(["postCalendarEvents"], retryAfter: "30")
        let first = dayModel(events: events, google: google, api: api)
        await first.refreshLinks(force: true)
        #expect(limiter.count("postCalendarEvents") == 1)
        #expect(first.problem(now: clock.now) == .links)
        #expect(events.retryNotBefore == clock.now.addingTimeInterval(30))
        // From here on anything sent would be answered.
        limiter.lift()

        // The screen is closed and opened again inside the delay.
        clock.advance(10)
        let reopened = dayModel(events: events, google: google, api: api)
        await reopened.refreshLinks(force: true)
        #expect(limiter.count("postCalendarEvents") == 1)
        // Today's own forced ask (a pull) is held back too.
        await events.refresh(force: true)
        #expect(limiter.count("postCalendarEvents") == 1)

        // Once the delay has passed, the day screen asks.
        clock.advance(20)
        await reopened.refreshLinks(force: true)
        #expect(limiter.count("postCalendarEvents") == 2)
        #expect(titles(reopened) == ["Lunch"])
    }

    /// L1: Today's poll gets our 429 while a day request is out; the day's
    /// later answer does not clear that hold.
    @Test func aDayAnswerKeepsAHoldSetWhileItWasOut() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        let day = dayModel(events: events, google: google)
        // Answers go in the order requests are let through: Today's poll first.
        googleStub.answer(GoogleAPIStub.postEvents, googleLimited(30), googleDay())
        googleStub.hold(GoogleAPIStub.postEvents)
        let poll = Task { await google.refresh(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)
        let read = Task { await day.refreshGoogle(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 2)

        googleStub.releaseOldest(GoogleAPIStub.postEvents)
        #expect(await finishes(poll))
        let hold = clock.now.addingTimeInterval(30)
        #expect(google.retryNotBefore == hold)
        googleStub.release(GoogleAPIStub.postEvents)
        #expect(await finishes(read))

        // The day's answer is shown, and the hold stands.
        #expect(titles(day).contains("Breakfast"))
        #expect(google.retryNotBefore == hold)
        #expect(google.statusProblem == .rateLimited)
        let sent = googleStub.count(GoogleAPIStub.postEvents)
        clock.advance(5)
        await day.refreshGoogle()
        await google.refresh(force: true)
        #expect(googleStub.count(GoogleAPIStub.postEvents) == sent)

        // An answer to a request sent after the hold passed clears it.
        clock.advance(26)
        await day.refreshGoogle(force: true)
        #expect(googleStub.count(GoogleAPIStub.postEvents) == sent + 1)
        #expect(google.retryNotBefore == nil)
        #expect(google.statusProblem == nil)
    }

    /// L1, the other way: the day request gets our 429 while Today's poll is
    /// out; the poll's later answer does not clear that hold.
    @Test func todaysAnswerKeepsAHoldTheDaySetWhileItWasOut() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        let day = dayModel(events: events, google: google)
        let todays = GoogleAPIStub.events([(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil])
        // The day request goes first, so it gets the 429.
        googleStub.answer(GoogleAPIStub.postEvents, googleLimited(30), todays)
        googleStub.hold(GoogleAPIStub.postEvents)
        let read = Task { await day.refreshGoogle(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)
        let poll = Task { await google.refresh(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 2)

        googleStub.releaseOldest(GoogleAPIStub.postEvents)
        #expect(await finishes(read))
        let hold = clock.now.addingTimeInterval(30)
        #expect(google.retryNotBefore == hold)
        googleStub.release(GoogleAPIStub.postEvents)
        #expect(await finishes(poll))

        #expect(google.retryNotBefore == hold)
        let sent = googleStub.count(GoogleAPIStub.postEvents)
        clock.advance(5)
        await google.refresh(force: true)
        await day.refreshGoogle(force: true)
        #expect(googleStub.count(GoogleAPIStub.postEvents) == sent)
    }

    /// Task 164: the day request gets our 429 with a long delay while
    /// Today's poll is out, and the poll's answer says Google limited the
    /// calendar. The answer keeps the long hold (`answered`), and Google's
    /// 60-second hold does not shorten it (`holdAtLeast`).
    @Test func googlesShortHoldDoesNotShortenALongerKeptHold() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        let day = dayModel(events: events, google: google)
        let limited = GoogleAPIStub.events([(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: ["rate_limited"])
        googleStub.answer(GoogleAPIStub.postEvents, googleLimited(600), limited)
        googleStub.hold(GoogleAPIStub.postEvents)
        let read = Task { await day.refreshGoogle(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)
        let poll = Task { await google.refresh(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 2)

        googleStub.releaseOldest(GoogleAPIStub.postEvents)
        #expect(await finishes(read))
        let hold = clock.now.addingTimeInterval(600)
        #expect(google.retryNotBefore == hold)
        googleStub.release(GoogleAPIStub.postEvents)
        #expect(await finishes(poll))
        #expect(google.retryNotBefore == hold)
        #expect(google.statusProblem == .rateLimited)
    }

    /// Task 164, the other way round: a kept hold shorter than Google's 60
    /// seconds is lengthened to 60 by the poll's answer.
    @Test func googlesHoldLengthensAShorterKeptHold() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        let day = dayModel(events: events, google: google)
        let limited = GoogleAPIStub.events([(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: ["rate_limited"])
        googleStub.answer(GoogleAPIStub.postEvents, googleLimited(30), limited)
        googleStub.hold(GoogleAPIStub.postEvents)
        let read = Task { await day.refreshGoogle(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)
        let poll = Task { await google.refresh(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 2)

        googleStub.releaseOldest(GoogleAPIStub.postEvents)
        #expect(await finishes(read))
        #expect(google.retryNotBefore == clock.now.addingTimeInterval(30))
        googleStub.release(GoogleAPIStub.postEvents)
        #expect(await finishes(poll))
        #expect(google.retryNotBefore == clock.now.addingTimeInterval(GoogleCalendarModel.googleRateLimitHold))
    }

    /// Task 164: an answer that keeps a back-off set while it was out keeps
    /// its failure count too, so the next failure backs off twice as long
    /// (10 seconds, not the first failure's 5).
    @Test func aKeptBackOffKeepsItsFailureCount() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        let day = dayModel(events: events, google: google)
        let failed = GoogleAPIStub.error(.internalServerError, "unavailable")
        let todays = GoogleAPIStub.events([(0, "Coffee", "2026-11-19T19:00:00Z", "2026-11-19T19:30:00Z")], statuses: [nil])
        // The day request fails first; Today's poll, out meanwhile, is answered.
        googleStub.answer(GoogleAPIStub.postEvents, failed, todays, failed)
        googleStub.hold(GoogleAPIStub.postEvents)
        let read = Task { await day.refreshGoogle(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)
        let poll = Task { await google.refresh(force: true) }
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 2)

        googleStub.releaseOldest(GoogleAPIStub.postEvents)
        #expect(await finishes(read))
        #expect(google.retryNotBefore == clock.now.addingTimeInterval(GooglePoll.backoff(failures: 1)))
        googleStub.release(GoogleAPIStub.postEvents)
        #expect(await finishes(poll))
        #expect(google.retryNotBefore == clock.now.addingTimeInterval(5))
        #expect(google.statusProblem == .unavailable)

        // The back-off passes and the next poll fails: the second in a row.
        clock.advance(5)
        await google.refresh(force: true)
        #expect(google.retryNotBefore == clock.now.addingTimeInterval(10))
        #expect(google.statusProblem == .unavailable)
    }

    /// L2: opened while a hold is on, the screen does not sit on "Reading
    /// your calendars…": it shows what it has and says when it will read.
    @Test func openedDuringAHoldTheScreenSaysItWillReadAgainShortly() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        // Today's poll and Today's links request both got our 429.
        googleStub.answer(GoogleAPIStub.postEvents, googleLimited(600))
        await google.refresh(force: true)
        #expect(google.retryNotBefore != nil)
        linkStub.set(TestLinks.google, .events([lunch]))
        let limiter = RateLimitTransport(linkStub)
        let api = stubbedAPI(limiter)
        let events = try eventsModel(context, links: [TestLinks.google], api: api)
        limiter.limit(["postCalendarEvents"], retryAfter: "600")
        await events.refresh(force: true)
        #expect(events.retryNotBefore != nil)
        limiter.lift()
        answerGoogleDay()

        let day = dayModel(events: events, google: google, api: api)
        await day.refresh(force: true)
        #expect(dayRequests().isEmpty)
        #expect(limiter.count("postCalendarEvents") == 1)
        #expect(!day.isWaiting(now: clock.now))
        #expect(day.isHeld(now: clock.now))
        #expect(day.problem(now: clock.now) == .bothHeld)

        // Both holds pass: both are read and the line goes.
        clock.advance(600)
        await day.refresh()
        #expect(day.problem(now: clock.now) == nil)
        #expect(!day.isHeld(now: clock.now))
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Lunch", "Coffee"])

        // Only Google held: the links' events show, with Google's line.
        googleStub.answer(GoogleAPIStub.postEvents, googleLimited(60))
        await google.refresh(force: true)
        let reopened = dayModel(events: events, google: google, api: api)
        await reopened.refresh(force: true)
        #expect(titles(reopened) == ["Lunch"])
        #expect(!reopened.isWaiting(now: clock.now))
        #expect(reopened.problem(now: clock.now) == .googleHeld)
        #expect(DayProblem.googleHeld.message.contains("again shortly"))
    }

    /// L3: the forced ask (the screen opened, the app came back) has the API
    /// read the links again; the timer's asks may be answered from its cache.
    @Test func onlyTheForcedLinksAskIsFresh() async throws {
        let context = try inMemoryContext()
        linkStub.set(TestLinks.google, .events([lunch]))
        let events = try eventsModel(context, links: [TestLinks.google])
        let day = dayModel(events: events, google: googleModel(context))
        await day.refreshLinks(force: true)
        #expect(linkStub.requests.map(\.fresh) == [true])
        clock.advance(DayRefresh.linksInterval)
        await day.refreshLinks()
        #expect(linkStub.requests.map(\.fresh) == [true, nil])
        // A new date asks unforced, so not fresh either.
        clock.now = instant("2026-11-20T06:00:01Z")
        await day.refreshLinks()
        #expect(linkStub.requests.map(\.fresh) == [true, nil, nil])
        #expect(linkStub.requests.last?.day == "2026-11-20")
    }

    /// L5: a links answer that arrives after the zone, the date or the links
    /// changed is not kept (checked on what is stored, not on the rows,
    /// which filter by day and zone anyway).
    @Test func aLateLinksAnswerIsDropped() async throws {
        linkStub.set(TestLinks.google, .events([lunch]))
        linkStub.set(TestLinks.icloud, .events([lateShow]))
        let start = clock.now
        for change in ["zone", "date", "links"] {
            clock.now = start
            zone.value = TimeZone(identifier: "America/Chicago")!
            let context = try inMemoryContext()
            // Today's model asks the plain stub; only the day's request is held.
            let events = try eventsModel(context, links: [TestLinks.google, TestLinks.icloud])
            let held = HeldCalendarTransport(linkStub)
            held.setHolding(true)
            let day = dayModel(
                events: events, google: googleModel(context),
                api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: held)
            )
            let read = Task { await day.refreshLinks(force: true) }
            await held.waitUntilHeld(1)
            switch change {
            case "zone": zone.value = .gmt
            case "date": clock.now = instant("2026-11-20T06:00:01Z")
            default: await events.remove(try #require(events.links.last))
            }
            held.releaseAll()
            #expect(await finishes(read), "\(change)")
            #expect(day.links == nil, "\(change)")
            #expect(day.problem(now: clock.now) == nil, "\(change)")
        }
    }

    /// L5: the same for a Google answer after the zone or the date changed.
    @Test func aLateGoogleAnswerIsDropped() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        let events = try eventsModel(context, links: [])
        let start = clock.now
        for change in ["zone", "date"] {
            clock.now = start
            zone.value = TimeZone(identifier: "America/Chicago")!
            answerGoogleDay()
            let day = dayModel(events: events, google: google)
            googleStub.hold(GoogleAPIStub.postEvents)
            let read = Task { await day.refreshGoogle(force: true) }
            await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)
            switch change {
            case "zone": zone.value = .gmt
            default: clock.now = instant("2026-11-20T06:00:01Z")
            }
            googleStub.release(GoogleAPIStub.postEvents)
            #expect(await finishes(read), "\(change)")
            #expect(day.google == nil, "\(change)")
            #expect(day.problem(now: clock.now) == nil, "\(change)")
        }
    }

    /// L5: a day request cancelled while out (the screen closed, the app
    /// left) leaves no status line and no hold, and the next start asks.
    @Test func aCancelledDayRequestLeavesNoStatusAndNoHold() async throws {
        let context = try inMemoryContext()
        let google = await connectedGoogle(context)
        linkStub.set(TestLinks.google, .events([lunch]))
        let events = try eventsModel(context, links: [TestLinks.google])
        answerGoogleDay()
        let parking = CancelOnlyTransport(linkStub)
        let day = dayModel(
            events: events, google: google,
            api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: parking)
        )
        googleStub.hold(GoogleAPIStub.postEvents)
        let read = Task { await day.refresh(force: true) }
        await parking.waitUntilParked()
        await googleStub.waitUntilParked(GoogleAPIStub.postEvents, count: 1)
        read.cancel()
        #expect(await finishes(read))

        #expect(day.problem(now: clock.now) == nil)
        #expect(!day.isHeld(now: clock.now))
        #expect(events.retryNotBefore == nil)
        #expect(google.retryNotBefore == nil)
        #expect(google.statusProblem == nil)

        // The next start asks both at once, unforced even.
        googleStub.release(GoogleAPIStub.postEvents)
        parking.stopParking()
        let linksBefore = linkStub.requests.count
        let googleBefore = dayRequests().count
        await day.refresh()
        #expect(linkStub.requests.count == linksBefore + 1)
        #expect(dayRequests().count == googleBefore + 1)
        #expect(titles(day) == ["Farmers' market", "Breakfast", "Lunch", "Coffee"])
    }
}

/// While parking, keeps each request until its task is cancelled, then
/// fails it as URLSession does; otherwise passes it to the stub.
private final class CancelOnlyTransport: ClientTransport, @unchecked Sendable {
    private let stub: CalendarStub
    private let lock = NSLock()
    private var parking = true
    private var parked = 0

    init(_ stub: CalendarStub) {
        self.stub = stub
    }

    func stopParking() {
        lock.withLock { parking = false }
    }

    /// Waits up to five seconds until a request is parked.
    func waitUntilParked() async {
        for _ in 0..<1000 {
            if lock.withLock({ parked }) >= 1 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("expected a parked calendar request")
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        guard lock.withLock({ parking }) else {
            return try await stub.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        lock.withLock { parked += 1 }
        // Bounded: a test that never cancels fails here after five seconds.
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled { Issue.record("a parked calendar request was never cancelled") }
        throw URLError(.cancelled)
    }
}
