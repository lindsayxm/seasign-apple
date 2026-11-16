import Foundation
import HTTPTypes
import Testing

@testable import Seasign

private let newYork = TimeZone(identifier: "America/New_York")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

private func event(
    _ title: String,
    _ start: String,
    _ end: String? = nil,
    allDay: Bool = false,
    date: String? = nil,
    link: UUID = UUID()
) -> UpcomingEvent {
    UpcomingEvent(link: link, title: title, start: instant(start), end: instant(end ?? start), allDay: allDay, date: date)
}

@Suite struct CalendarAPITests {
    @Test func decodesARealisticResponse() async throws {
        let stub = CalendarStub(status: .ok, json: calendarJSONThreeLinks)
        let answer = try await stubbedCalendarAPI(stub).calendarEvents(
            links: [TestLinks.google, TestLinks.icloud, TestLinks.outlook],
            timezone: "America/New_York"
        )

        #expect(answer.events.count == 4)
        let allDay = try #require(answer.events.first)
        #expect(allDay.allDay)
        #expect(allDay.date == "2026-11-15")
        #expect(allDay.calendar == 1)
        #expect(allDay.start == instant("2026-11-15T05:00:00Z"))
        #expect(allDay.end == instant("2026-11-16T05:00:00Z"))
        let show = answer.events[1]
        #expect(show.title == "Hanna's show")
        #expect(!show.allDay)
        #expect(show.date == nil)
        #expect(show.start == instant("2026-11-16T01:25:00Z"))
        #expect(answer.events[3].title == "")

        #expect(answer.calendars == [
            .init(index: 0, ok: true, partial: false, error: nil),
            .init(index: 1, ok: true, partial: true, error: nil),
            .init(index: 2, ok: false, partial: false, error: .notCalendar),
        ])
    }

    /// A body the API's own tests expect, through the client and on to Today's wording.
    @Test func readsWhatTheAPISendsAndWordsItForToday() async throws {
        let stub = CalendarStub(status: .ok, json: calendarJSONFromAPITest)
        let answer = try await stubbedCalendarAPI(stub).calendarEvents(links: ["a", "b", "c"], timezone: "America/New_York")
        #expect(answer.events.count == 7)
        #expect(answer.calendars.allSatisfy { $0.ok && !$0.partial && $0.error == nil })

        let ids = [UUID(), UUID(), UUID()]
        let zone = TimeZone(identifier: "America/New_York")!
        func labels(at now: Date) -> [String] {
            let snapshot = EventsSnapshot.make(from: answer, links: ids, timezone: zone.identifier, previous: nil, now: now)
            return EventPicker.next(snapshot.events, now: now).map {
                let label = EventLabel(event: $0, now: now, timeZone: zone)
                return "\(label.time) \(label.title)"
            }
        }
        // 19:00 on Sunday 15 November in New York.
        #expect(labels(at: instant("2026-11-16T00:00:00Z")) == ["ALL DAY Road trip", "6:00PM Camping at the lake", "TUE 7:30AM Morning run"])
        // 18:59 on Tuesday: the call at 19:00 has no length and is still ahead.
        #expect(labels(at: instant("2026-11-17T23:59:00Z")) == ["ALL DAY Road trip", "7:00PM Call the landlord", "WED ALL DAY Mom's birthday"])
        // 19:01: it is over.
        #expect(labels(at: instant("2026-11-18T00:01:00Z")) == ["ALL DAY Road trip", "WED ALL DAY Mom's birthday"])
    }

    @Test func sendsTheLinksAndTheTimeZone() async throws {
        let stub = CalendarStub([TestLinks.google: .events([])])
        _ = try await stubbedCalendarAPI(stub).calendarEvents(
            links: [TestLinks.google, TestLinks.icloud],
            timezone: "America/Chicago"
        )
        #expect(stub.requests == [.init(links: [TestLinks.google, TestLinks.icloud], timezone: "America/Chicago")])
    }

    @Test func everyErrorCodeOfTheAPIIsKnown() async throws {
        for problem in LinkProblem.allCases {
            let stub = CalendarStub([TestLinks.google: .failure(problem.rawValue)])
            let answer = try await stubbedCalendarAPI(stub).calendarEvents(links: [TestLinks.google], timezone: nil)
            #expect(answer.calendars == [.init(index: 0, ok: false, partial: false, error: problem)])
            #expect(!problem.message.isEmpty)
        }
        #expect(LinkProblem.notCalendar.message == "That link didn't return a calendar.")
        #expect(LinkStatus(problem: nil, partial: true).message == "Some events in this calendar couldn't be read.")
        #expect(LinkStatus(problem: nil, partial: false).message == nil)
        #expect(LinkStatus(problem: .timeout, partial: false).message == LinkProblem.timeout.message)
    }

    @Test func aRefusedRequestAndAServerFailureAreToldApart() async {
        let refused = CalendarStub(status: .badRequest, json: #"{"error":"invalid_request","message":"Send 1 to 10 links"}"#)
        await #expect(throws: SeasignAPI.CalendarFailure.invalidRequest) {
            try await stubbedCalendarAPI(refused).calendarEvents(links: [TestLinks.google], timezone: "Mars/Olympus")
        }
        let broken = CalendarStub(status: .internalServerError, json: #"{"error":"internal_error","message":"Something went wrong"}"#)
        await #expect(throws: SeasignAPI.CalendarFailure.unavailable) {
            try await stubbedCalendarAPI(broken).calendarEvents(links: [TestLinks.google], timezone: nil)
        }
        let garbled = CalendarStub(status: .ok, json: #"{"events":"none"}"#)
        await #expect(throws: SeasignAPI.CalendarFailure.unavailable) {
            try await stubbedCalendarAPI(garbled).calendarEvents(links: [TestLinks.google], timezone: nil)
        }
    }

    /// The generated client's own error describes the request. Ours must not.
    @Test func aFailureSaysNothingAboutTheLink() async {
        let stub = CalendarStub()
        stub.setOffline(true)
        do {
            _ = try await stubbedCalendarAPI(stub).calendarEvents(links: [TestLinks.google], timezone: nil)
            Issue.record("expected a failure")
        } catch {
            #expect(error as? SeasignAPI.CalendarFailure == .unavailable)
            for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                #expect(!text.contains("SECRETTOKEN"))
                #expect(!text.contains("google"))
            }
        }
    }
}

@Suite struct LinkMaskTests {
    @Test func showsOnlyAShortHost() {
        #expect(LinkMask.host(of: TestLinks.google) == "google.com")
        #expect(LinkMask.host(of: TestLinks.icloud) == "icloud.com")
        #expect(LinkMask.host(of: TestLinks.outlook) == "live.com")
        #expect(LinkMask.host(of: "https://outlook.office365.com/owa/calendar/a/b/calendar.ics") == "office365.com")
        #expect(LinkMask.host(of: "  HTTPS://Cal.Example.CO.UK/x.ics?key=SECRETTOKEN \n") == "example.co.uk")
    }

    @Test func neverShowsPathQueryUserOrSubdomain() {
        let links = [
            TestLinks.google, TestLinks.icloud, TestLinks.outlook,
            "https://user:SECRETTOKEN@cal.example.com/feed.ics",
            "https://SECRETTOKEN.cal.example.com/feed.ics",
            "https://cal.example.com/feed.ics?token=SECRETTOKEN#SECRETTOKEN",
        ]
        for link in links {
            let shown = LinkMask.host(of: link) ?? ""
            #expect(!shown.isEmpty)
            #expect(!shown.localizedCaseInsensitiveContains("secret"))
            #expect(!shown.contains("/"))
            #expect(!shown.contains("@"))
            #expect(!shown.contains("?"))
        }
    }

    @Test func textWithoutAHostShowsNothing() {
        for text in ["", "not a link", "SECRETTOKEN", "https://", "https://192.168.1.10/cal.ics", "https://localhost/cal.ics", "mailto:someone@example.com"] {
            #expect(LinkMask.host(of: text) == nil, "\(text)")
        }
    }
}

@Suite struct EventPickerTests {
    private let now = instant("2026-11-15T23:05:00Z")

    @Test func takesTheNextThreeSoonestFirst() {
        let events = [
            event("Thursday", "2026-11-19T15:00:00Z", "2026-11-19T16:00:00Z"),
            event("Tonight", "2026-11-16T01:25:00Z", "2026-11-16T03:00:00Z"),
            event("Tuesday", "2026-11-17T15:00:00Z", "2026-11-17T16:00:00Z"),
            event("Tomorrow", "2026-11-16T14:00:00Z", "2026-11-16T15:00:00Z"),
        ]
        #expect(EventPicker.next(events, now: now).map(\.title) == ["Tonight", "Tomorrow", "Tuesday"])
        #expect(EventPicker.next(events, now: now, limit: 1).map(\.title) == ["Tonight"])
        #expect(EventPicker.next([], now: now).isEmpty)
    }

    @Test func leavesOutWhatHasEnded() {
        let events = [
            event("Over", "2026-11-15T20:00:00Z", "2026-11-15T21:00:00Z"),
            event("Ends this instant", "2026-11-15T22:00:00Z", "2026-11-15T23:05:00Z"),
            event("Under way", "2026-11-15T22:30:00Z", "2026-11-15T23:30:00Z"),
            event("Next", "2026-11-16T00:00:00Z", "2026-11-16T01:00:00Z"),
        ]
        #expect(EventPicker.next(events, now: now).map(\.title) == ["Under way", "Next"])
    }

    /// The API's rule: an event without a length is over once it has started.
    @Test func anEventWithoutALengthLastsUntilItsStart() {
        let reminder = event("Reminder", "2026-11-15T23:05:00Z")
        #expect(!reminder.hasEnded(at: now))
        #expect(reminder.hasEnded(at: now.addingTimeInterval(1)))
        #expect(!reminder.hasEnded(at: now.addingTimeInterval(-60)))
    }

    @Test func anAllDayEventStaysUntilItsDayEnds() {
        let market = event("Market", "2026-11-15T05:00:00Z", "2026-11-16T05:00:00Z", allDay: true, date: "2026-11-15")
        let show = event("Show", "2026-11-16T01:25:00Z", "2026-11-16T03:00:00Z")
        #expect(EventPicker.next([show, market], now: now).map(\.title) == ["Market", "Show"])
        // Midnight in New York: the day is over.
        #expect(EventPicker.next([show, market], now: instant("2026-11-16T05:00:00Z")).isEmpty)
    }

    @Test func eventsAtTheSameInstantKeepOneOrder() {
        let start = "2026-11-16T05:00:00Z"
        let events = [
            event("Zoo", start, "2026-11-16T06:00:00Z"),
            event("Birthday", start, "2026-11-17T05:00:00Z", allDay: true, date: "2026-11-16"),
            event("Alarm", start, "2026-11-16T05:30:00Z"),
        ]
        #expect(EventPicker.next(events, now: now).map(\.title) == ["Birthday", "Alarm", "Zoo"])
        #expect(EventPicker.next(events.reversed(), now: now).map(\.title) == ["Birthday", "Alarm", "Zoo"])
    }
}

@Suite struct EventLabelTests {
    /// 18:05 on Sunday 15 November in New York.
    private let now = instant("2026-11-15T23:05:00Z")

    private func label(_ event: UpcomingEvent, now: Date? = nil, in zone: TimeZone = newYork) -> EventLabel {
        EventLabel(event: event, now: now ?? self.now, timeZone: zone)
    }

    @Test func timeIsTwelveHourWithoutASpace() {
        #expect(label(event("A", "2026-11-16T01:25:00Z")).time == "8:25PM")
        #expect(label(event("A", "2026-11-16T02:45:00Z")).time == "9:45PM")
        // Earlier today and still running.
        #expect(label(event("A", "2026-11-15T15:15:00Z", "2026-11-16T00:00:00Z")).time == "10:15AM")
        #expect(label(event("A", "2026-11-15T17:00:00Z", "2026-11-16T00:00:00Z")).time == "12:00PM")
        #expect(label(event("A", "2026-11-15T17:05:00Z", "2026-11-16T00:00:00Z")).time == "12:05PM")
    }

    @Test func midnightAndNoonAreTwelve() {
        let sundayMorning = instant("2026-11-15T04:30:00Z") // 23:30 Saturday in New York
        #expect(label(event("A", "2026-11-15T05:00:00Z"), now: sundayMorning).time == "SUN 12:00AM")
        #expect(label(event("A", "2026-11-15T05:30:00Z"), now: instant("2026-11-15T05:10:00Z")).time == "12:30AM")
    }

    @Test func aLaterDayIsNamed() {
        #expect(label(event("A", "2026-11-16T14:00:00Z")).time == "MON 9:00AM")
        #expect(label(event("A", "2026-11-17T14:00:00Z")).time == "TUE 9:00AM")
        #expect(label(event("A", "2026-11-21T23:30:00Z")).time == "SAT 6:30PM")
        // Seven days out is a Sunday again; the name tells it from today.
        #expect(label(event("A", "2026-11-22T22:00:00Z")).time == "SUN 5:00PM")
    }

    @Test func allDayShowsNoTime() {
        let today = event("Market", "2026-11-15T05:00:00Z", "2026-11-16T05:00:00Z", allDay: true, date: "2026-11-15")
        #expect(label(today).time == "ALL DAY")
        #expect(label(today).spoken == "Market, all day")
        let tuesday = event("Trip", "2026-11-17T05:00:00Z", "2026-11-18T05:00:00Z", allDay: true, date: "2026-11-17")
        #expect(label(tuesday).time == "TUE ALL DAY")
        #expect(label(tuesday).spoken == "Trip, Tuesday, all day")
    }

    /// The date of an all-day event is a calendar date, not an instant: it
    /// keeps its day even when read in a zone where its start instant falls
    /// on another day.
    @Test func anAllDayEventBelongsToItsDate() {
        let monday = event("Holiday", "2026-11-16T05:00:00Z", "2026-11-17T05:00:00Z", allDay: true, date: "2026-11-16")
        #expect(label(monday).time == "MON ALL DAY")
        // In Los Angeles that start instant is 21:00 on Sunday.
        #expect(label(monday, in: losAngeles).time == "MON ALL DAY")
        // On the day itself it is simply all day.
        #expect(label(monday, now: instant("2026-11-16T15:00:00Z")).time == "ALL DAY")
    }

    @Test func anEventThatBeganBeforeTodayHasNoDayName() {
        let trip = event("Trip", "2026-11-13T05:00:00Z", "2026-11-18T05:00:00Z", allDay: true, date: "2026-11-13")
        #expect(label(trip).time == "ALL DAY")
        let overnight = event("Night shift", "2026-11-15T03:00:00Z", "2026-11-16T03:00:00Z")
        #expect(label(overnight, now: instant("2026-11-15T12:00:00Z")).time == "10:00PM")
    }

    /// The same instant is tonight in New York and tomorrow in Tokyo. The
    /// zip's zone decides, not the phone's.
    @Test func theZoneDecidesTheTimeAndTheDay() {
        let show = event("Show", "2026-11-16T01:25:00Z", "2026-11-16T03:00:00Z")
        #expect(label(show, in: newYork).time == "8:25PM")
        #expect(label(show, in: losAngeles).time == "5:25PM")
        // In Tokyo it is already 08:05 on Monday, and the show is at 10:25.
        #expect(label(show, in: tokyo).time == "10:25AM")
        // Late on Sunday in Los Angeles this is "today"; in New York it is Monday.
        let late = event("Late", "2026-11-16T06:30:00Z")
        #expect(label(late, in: losAngeles).time == "10:30PM")
        #expect(label(late, in: newYork).time == "MON 1:30AM")
    }

    @Test func titleAndSpokenText() {
        let show = label(event("  Hanna's show ", "2026-11-16T01:25:00Z"))
        #expect(show.title == "Hanna's show")
        #expect(show.spoken == "Hanna's show, 8:25 PM")
        #expect(label(event("Dentist", "2026-11-16T14:00:00Z")).spoken == "Dentist, Monday, 9:00 AM")
        let untitled = label(event("", "2026-11-16T01:25:00Z"))
        #expect(untitled.title == "No title")
        #expect(untitled.spoken == "No title, 8:25 PM")
    }

    @Test func weekdayOfADateString() {
        #expect(EventLabel.weekday(ofDate: "2026-11-15") == 0)
        #expect(EventLabel.weekday(ofDate: "2026-11-21") == 6)
        #expect(EventLabel.weekday(ofDate: "2028-02-29") == 2)
        for bad in ["", "2026-11", "2026-13-01", "2026-02-30", "20261115", "tomorrow"] {
            #expect(EventLabel.weekday(ofDate: bad) == nil, "\(bad)")
        }
    }
}

@Suite struct EventZoneTests {
    private let fetched = instant("2026-11-15T23:00:00Z")

    @Test func theZipsZoneWinsOverThePhones() async throws {
        let sky = try await snapshot(fetchedAt: fetched)
        #expect(EventZone.resolve(zip: "10001", snapshot: sky, device: tokyo) == newYork)
    }

    @Test func withoutAZipThePhonesZoneIsUsed() async throws {
        let sky = try await snapshot(fetchedAt: fetched)
        #expect(EventZone.resolve(zip: nil, snapshot: nil, device: tokyo) == tokyo)
        #expect(EventZone.resolve(zip: nil, snapshot: sky, device: tokyo) == tokyo)
        // A zip whose sky is not known yet, or a sky left over from another zip.
        #expect(EventZone.resolve(zip: "94103", snapshot: nil, device: tokyo) == tokyo)
        #expect(EventZone.resolve(zip: "94103", snapshot: sky, device: tokyo) == tokyo)
    }
}

@Suite struct EventsSnapshotTests {
    private let now = instant("2026-11-15T23:05:00Z")
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()

    private func answer() async throws -> CalendarAnswer {
        try await stubbedCalendarAPI(CalendarStub(status: .ok, json: calendarJSONThreeLinks))
            .calendarEvents(links: ["a", "b", "c"], timezone: "America/New_York")
    }

    @Test func tiesEventsAndStatusesToLinkIDs() async throws {
        let made = EventsSnapshot.make(
            from: try await answer(), links: [first, second, third],
            timezone: "America/New_York", previous: nil, now: now
        )
        #expect(made.events.map(\.title) == ["Farmers' market", "Hanna's show", "Dentist", ""])
        #expect(made.events.map(\.link) == [second, first, first, second])
        #expect(made.status(for: first) == LinkStatus(problem: nil, partial: false))
        #expect(made.status(for: second) == LinkStatus(problem: nil, partial: true))
        #expect(made.status(for: third) == LinkStatus(problem: .notCalendar, partial: false))
        #expect(made.status(for: UUID()) == nil)
        #expect(made.timezone == "America/New_York")
        #expect(made.fetchedAt == now)
    }

    @Test func anEventOfAnUnknownCalendarIsDropped() async throws {
        let made = EventsSnapshot.make(
            from: try await answer(), links: [first],
            timezone: "America/New_York", previous: nil, now: now
        )
        #expect(made.events.map(\.title) == ["Hanna's show", "Dentist"])
        #expect(made.statuses.map(\.link) == [first])
    }

    @Test func pruningDropsEndedEventsAndRemovingDropsALink() async throws {
        let made = EventsSnapshot.make(
            from: try await answer(), links: [first, second, third],
            timezone: "America/New_York", previous: nil, now: now
        )
        let monday = made.pruned(at: instant("2026-11-16T12:00:00Z"))
        #expect(monday.events.map(\.title) == ["Dentist", ""])
        #expect(monday.statuses == made.statuses)
        let without = made.removing(link: second)
        #expect(without.events.map(\.title) == ["Hanna's show", "Dentist"])
        #expect(without.statuses.map(\.link) == [first, third])
    }

    @Test func survivesTheCacheEncoding() async throws {
        let made = EventsSnapshot.make(
            from: try await answer(), links: [first, second, third],
            timezone: "America/New_York", previous: nil, now: now
        )
        let data = try JSONEncoder().encode(made)
        #expect(try JSONDecoder().decode(EventsSnapshot.self, from: data) == made)
        // The cache holds ids, never links.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("http"))
        #expect(!text.contains("webcal"))
    }

    /// A calendar that cannot be reached for a moment keeps the events read
    /// before; one whose link stopped being a calendar does not.
    @Test func eventsOfAnUnreachableCalendarAreCarriedOver() {
        func status(_ ok: Bool, _ error: LinkProblem?) -> [CalendarAnswer.Status] {
            [.init(index: 0, ok: true, partial: false, error: nil), .init(index: 1, ok: ok, partial: false, error: error)]
        }
        let previous = EventsSnapshot(
            events: [
                event("Kept", "2026-11-16T14:00:00Z", "2026-11-16T15:00:00Z", link: second),
                event("Over", "2026-11-15T20:00:00Z", "2026-11-15T21:00:00Z", link: second),
                event("Stale", "2026-11-16T16:00:00Z", "2026-11-16T17:00:00Z", link: first),
            ],
            statuses: [], timezone: "America/New_York", fetchedAt: now.addingTimeInterval(-900)
        )
        let fresh = CalendarAnswer.Event(
            calendar: 0, title: "Fresh", start: instant("2026-11-16T18:00:00Z"),
            end: instant("2026-11-16T19:00:00Z"), allDay: false, date: nil
        )
        func make(_ error: LinkProblem, zone: String = "America/New_York") -> [String] {
            EventsSnapshot.make(
                from: CalendarAnswer(events: [fresh], calendars: status(false, error)),
                links: [first, second], timezone: zone, previous: previous, now: now
            ).events.map(\.title)
        }
        #expect(make(.timeout) == ["Kept", "Fresh"])
        #expect(make(.fetchFailed) == ["Kept", "Fresh"])
        #expect(make(.notCalendar) == ["Fresh"])
        #expect(make(.invalidLink) == ["Fresh"])
        // Events placed for another time zone are not carried over.
        #expect(make(.timeout, zone: "Asia/Tokyo") == ["Fresh"])
    }
}
