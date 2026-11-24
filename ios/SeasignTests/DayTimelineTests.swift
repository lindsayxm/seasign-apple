import CoreGraphics
import Foundation
import Testing

@testable import Seasign

/// The day screen's timeline layout (task 181).
@Suite struct DayTimelineTests {
    private let zone = TimeZone(identifier: "America/New_York")!
    private let link = UUID()
    private let metrics = DayTimeline.Metrics()

    /// `2026-11-23T09:00:00-05:00`
    private func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func event(_ title: String, _ start: String, _ end: String, allDay: Bool = false, date: String? = nil) -> UpcomingEvent {
        UpcomingEvent(link: link, title: title, start: at(start), end: at(end), allDay: allDay, date: date)
    }

    private var day: DateInterval {
        DayTimeline.bounds(of: at("2026-11-23T12:00:00-05:00"), in: zone)
    }

    /// A grid whose 24 hours are 480 points: 20 points an hour, plus the insets.
    private var height: CGFloat { 480 + 2 * metrics.inset }

    private func layout(_ events: [UpcomingEvent], day: DateInterval? = nil, now: Date? = nil, height: CGFloat? = nil, width: CGFloat = 300) -> DayTimeline.Layout {
        DayTimeline.layout(
            events: events, day: day ?? self.day, zone: zone, now: now,
            height: height ?? self.height, width: width, metrics: metrics
        )
    }

    @Test func startAndEndMapToY() throws {
        let result = layout([event("Planning", "2026-11-23T09:00:00-05:00", "2026-11-23T10:30:00-05:00")])
        let box = try #require(result.boxes.first)
        #expect(result.hourHeight == 20)
        #expect(box.frame.minY == metrics.inset + 180)
        #expect(box.frame.maxY == metrics.inset + 210)
        #expect(box.frame.minX == 0 && box.frame.width == 300)
        #expect(box.columns == 1 && box.column == 0 && box.span == 1)
        #expect(!box.startsBefore && !box.endsAfter)
        #expect(result.allDay.isEmpty)
    }

    @Test func overlapsGetColumnsAndAGroupSharesItsColumnCount() throws {
        let events = [
            event("A", "2026-11-23T09:00:00-05:00", "2026-11-23T10:30:00-05:00"),
            event("B", "2026-11-23T09:30:00-05:00", "2026-11-23T10:00:00-05:00"),
            event("C", "2026-11-23T10:00:00-05:00", "2026-11-23T11:00:00-05:00"),
            event("D", "2026-11-23T10:30:00-05:00", "2026-11-23T12:00:00-05:00"),
            event("Later", "2026-11-23T15:00:00-05:00", "2026-11-23T16:00:00-05:00"),
        ]
        // 40 points an hour, so each half hour is taller than the minimum.
        let result = layout(events, height: 960 + 2 * metrics.inset)
        let byTitle = Dictionary(uniqueKeysWithValues: result.boxes.map { (events[$0.index].title, $0) })
        let a = try #require(byTitle["A"]), b = try #require(byTitle["B"])
        let c = try #require(byTitle["C"]), d = try #require(byTitle["D"])
        let later = try #require(byTitle["Later"])
        // A, B, C and D overlap through one another: one group of two columns.
        #expect([a, b, c, d].allSatisfy { $0.columns == 2 })
        #expect(a.column == 0 && b.column == 1)
        // C starts as B ends, so it takes B's column; D starts as A ends.
        #expect(c.column == 1 && d.column == 0)
        #expect(b.frame.minX == (300 + metrics.columnGap) / 2)
        #expect(abs(a.frame.width - (300 - metrics.columnGap) / 2) < 0.001)
        // Side by side boxes never cover each other.
        #expect(a.frame.maxX < b.frame.minX)
        // A box alone has the whole width.
        #expect(later.columns == 1 && later.frame.width == 300)
    }

    @Test func aBoxWidensIntoColumnsThatAreFreeForItsHeight() throws {
        let events = [
            event("Long", "2026-11-23T09:00:00-05:00", "2026-11-23T12:00:00-05:00"),
            event("First", "2026-11-23T09:00:00-05:00", "2026-11-23T10:00:00-05:00"),
            event("Second", "2026-11-23T09:00:00-05:00", "2026-11-23T10:00:00-05:00"),
            event("After", "2026-11-23T10:30:00-05:00", "2026-11-23T11:00:00-05:00"),
        ]
        let result = layout(events)
        let after = try #require(result.boxes.first { events[$0.index].title == "After" })
        #expect(after.columns == 3)
        #expect(after.column == 1 && after.span == 2)
        #expect(abs(after.frame.maxX - 300) < 0.001)
    }

    @Test func shortAndLengthlessEventsGetTheMinimumHeightAndColumnsFromWhatIsDrawn() throws {
        let events = [
            event("Pill", "2026-11-23T08:00:00-05:00", "2026-11-23T08:00:00-05:00"),
            event("Call", "2026-11-23T09:00:00-05:00", "2026-11-23T09:05:00-05:00"),
            // Ten minutes after Call: apart in time, but Call's box reaches it.
            event("Coffee", "2026-11-23T09:10:00-05:00", "2026-11-23T09:25:00-05:00"),
        ]
        let result = layout(events)
        for box in result.boxes {
            #expect(box.frame.height == metrics.minimumBoxHeight)
            #expect(box.content == .title)
        }
        let pill = try #require(result.boxes.first { events[$0.index].title == "Pill" })
        #expect(pill.frame.minY == metrics.inset + 160)
        #expect(pill.columns == 1)
        let call = try #require(result.boxes.first { events[$0.index].title == "Call" })
        let coffee = try #require(result.boxes.first { events[$0.index].title == "Coffee" })
        #expect(call.columns == 2 && coffee.columns == 2 && call.column != coffee.column)
    }

    @Test func aMinimumHeightBoxAtTheEndOfTheDayStaysInside() throws {
        let result = layout([event("Bedtime", "2026-11-23T23:55:00-05:00", "2026-11-24T00:00:00-05:00")])
        let box = try #require(result.boxes.first)
        #expect(box.frame.maxY == height - metrics.inset)
        #expect(box.frame.height == metrics.minimumBoxHeight)
    }

    @Test func eventsRunningPastMidnightAreCutAtTheEdge() throws {
        let events = [
            event("Night flight", "2026-11-22T22:00:00-05:00", "2026-11-23T01:30:00-05:00"),
            event("Late show", "2026-11-23T22:30:00-05:00", "2026-11-24T01:00:00-05:00"),
            event("Yesterday", "2026-11-22T20:00:00-05:00", "2026-11-23T00:00:00-05:00"),
            event("Tomorrow", "2026-11-24T00:00:00-05:00", "2026-11-24T01:00:00-05:00"),
        ]
        let result = layout(events)
        #expect(result.boxes.count == 2)
        let flight = try #require(result.boxes.first { events[$0.index].title == "Night flight" })
        #expect(flight.frame.minY == metrics.inset)
        #expect(flight.frame.maxY == metrics.inset + 30)
        #expect(flight.startsBefore && !flight.endsAfter)
        let show = try #require(result.boxes.first { events[$0.index].title == "Late show" })
        #expect(show.frame.minY == metrics.inset + 450)
        #expect(show.frame.maxY == height - metrics.inset)
        #expect(show.endsAfter && !show.startsBefore)
    }

    @Test func aDayWithTheClocksGoingForwardHas23HoursAndBackHas25() throws {
        let spring = DayTimeline.bounds(of: at("2026-03-08T12:00:00-04:00"), in: zone)
        #expect(spring.duration == 23 * 3600)
        let short = layout([event("Brunch", "2026-03-08T11:00:00-04:00", "2026-03-08T12:00:00-04:00")], day: spring, height: 460 + 2 * metrics.inset)
        #expect(short.hourHeight == 20)
        #expect(short.hours.count == 24)
        // 1 AM, then 3 AM: the clock skips 2.
        #expect(short.hours.prefix(4).map(\.hour) == [0, 1, 3, 4])
        // 11 AM is 10 real hours after midnight.
        #expect(short.boxes.first?.frame.minY == metrics.inset + 200)
        #expect(short.hours.last?.y == metrics.inset + 460)

        let fall = DayTimeline.bounds(of: at("2026-11-01T12:00:00-05:00"), in: zone)
        #expect(fall.duration == 25 * 3600)
        let long = layout([event("Brunch", "2026-11-01T11:00:00-05:00", "2026-11-01T12:00:00-05:00")], day: fall, height: 500 + 2 * metrics.inset)
        #expect(long.hourHeight == 20)
        #expect(long.hours.count == 26)
        // 1 AM twice.
        #expect(long.hours.prefix(4).map(\.hour) == [0, 1, 1, 2])
        // 11 AM is 12 real hours after midnight.
        #expect(long.boxes.first?.frame.minY == metrics.inset + 240)
    }

    @Test func allDayEventsAndTimedEventsCoveringTheDayGoToTheStrip() {
        let events = [
            event("Market", "2026-11-23T00:00:00-05:00", "2026-11-24T00:00:00-05:00", allDay: true, date: "2026-11-23"),
            event("Conference", "2026-11-22T09:00:00-05:00", "2026-11-25T17:00:00-05:00"),
            event("Planning", "2026-11-23T09:00:00-05:00", "2026-11-23T10:00:00-05:00"),
        ]
        let result = layout(events)
        #expect(result.allDay == [0, 1])
        #expect(result.boxes.map(\.index) == [2])
    }

    @Test func whatABoxShowsAtEachHeight() {
        // One line: title (and the start if it fits).
        #expect(DayTimeline.content(height: metrics.minimumBoxHeight, metrics: metrics) == .title)
        let twoTier = metrics.titleLine + metrics.timeLine + 2 * metrics.padding
        #expect(DayTimeline.content(height: twoTier - 1, metrics: metrics) == .title)
        #expect(DayTimeline.content(height: twoTier, metrics: metrics) == .titleAndTime(titleLines: 1))
        #expect(DayTimeline.content(height: twoTier + 2 * metrics.titleLine, metrics: metrics) == .titleAndTime(titleLines: 3))
    }

    @Test func hourLinesAreLabelledByTheClockExceptAtTheEdgesAndNearNow() {
        let now = at("2026-11-23T14:05:00-05:00")
        let result = layout([], now: now)
        #expect(result.hours.count == 25)
        #expect(result.labelStep == 1)
        #expect(result.nowY.map { abs($0 - (metrics.inset + 280 + 20.0 / 12)) < 0.001 } == true)
        #expect(result.hours.first?.labelled == false && result.hours.last?.labelled == false)
        // 2 PM sits under the now label; 1 PM and 3 PM are far enough.
        let labelled = Set(result.hours.filter(\.labelled).map(\.hour))
        #expect(!labelled.contains(14))
        #expect(labelled.contains(13) && labelled.contains(15))
        #expect(layout([], now: at("2026-11-24T00:30:00-05:00")).nowY == nil)
        // Short hours are labelled every few hours.
        let small = layout([], height: 24 * 5 + 2 * metrics.inset)
        #expect(small.labelStep == 3)
        #expect(small.hours.filter(\.labelled).map(\.hour) == [3, 6, 9, 12, 15, 18, 21])
    }

    @Test func hourLabelsAndBoxTimesFollowTheClock() {
        #expect(DayTimeline.hourLabel(hour: 0, minute: 0, clock: .twelveHour) == "12AM")
        #expect(DayTimeline.hourLabel(hour: 13, minute: 0, clock: .twelveHour) == "1PM")
        #expect(DayTimeline.hourLabel(hour: 13, minute: 0, clock: .twentyFourHour) == "13:00")
        let morning = event("A", "2026-11-23T09:00:00-05:00", "2026-11-23T10:30:00-05:00")
        #expect(DayTimeline.timeText(morning, zone: zone, clock: .twelveHour) == "9:00–10:30AM")
        #expect(DayTimeline.timeText(morning, zone: zone, clock: .twentyFourHour) == "09:00–10:30")
        let noon = event("B", "2026-11-23T11:00:00-05:00", "2026-11-23T13:00:00-05:00")
        #expect(DayTimeline.timeText(noon, zone: zone, clock: .twelveHour) == "11:00AM–1:00PM")
        let pill = event("C", "2026-11-23T08:00:00-05:00", "2026-11-23T08:00:00-05:00")
        #expect(DayTimeline.timeText(pill, zone: zone, clock: .twelveHour) == "8:00AM")
    }

    @Test func voiceOverReadsTitleStartEndAndLength() {
        let now = at("2026-11-23T12:00:00-05:00")
        func spoken(_ event: UpcomingEvent, clock: ClockStyle = .twelveHour) -> String {
            DayTimeline.spoken(event, day: day, zone: zone, now: now, clock: clock)
        }
        #expect(spoken(event("Planning", "2026-11-23T13:00:00-05:00", "2026-11-23T14:30:00-05:00"))
            == "Planning, 1:00 PM to 2:30 PM, 1 hour 30 minutes")
        #expect(spoken(event("Planning", "2026-11-23T13:00:00-05:00", "2026-11-23T14:30:00-05:00"), clock: .twentyFourHour)
            == "Planning, 13:00 to 14:30, 1 hour 30 minutes")
        #expect(spoken(event("Run", "2026-11-23T07:00:00-05:00", "2026-11-23T08:00:00-05:00"))
            == "Run, 7:00 AM to 8:00 AM, 1 hour, ended")
        #expect(spoken(event("Pill", "2026-11-23T18:00:00-05:00", "2026-11-23T18:00:00-05:00"))
            == "Pill, at 6:00 PM, no end time")
        #expect(spoken(event("Flight", "2026-11-22T22:00:00-05:00", "2026-11-23T01:30:00-05:00"))
            == "Flight, yesterday 10:00 PM to 1:30 AM, 3 hours 30 minutes, ended")
        #expect(spoken(event("Show", "2026-11-23T22:30:00-05:00", "2026-11-24T01:00:00-05:00"))
            == "Show, 10:30 PM to tomorrow 1:00 AM, 2 hours 30 minutes")
        #expect(spoken(event("  ", "2026-11-23T00:00:00-05:00", "2026-11-24T00:00:00-05:00", allDay: true, date: "2026-11-23"))
            == "No title, all day")
        #expect(DayTimeline.length(5 * 60) == "5 minutes")
        #expect(DayTimeline.length(3600) == "1 hour")
        #expect(DayTimeline.length(3 * 86_400 + 8 * 3600) == "3 days 8 hours")
    }

    @Test func theStripFoldsWhatDoesNotFitIntoOneChipAtTheEnd() {
        // Everything fits in two rows.
        let fits = DayTimeline.strip(widths: [100, 100, 100], available: 250, gap: 4, maxRows: 2, moreWidth: 40)
        #expect(fits.rows == [[0, 1], [2]])
        #expect(fits.hidden.isEmpty)
        // Too many: the last row keeps room for the "+N" chip.
        let many = DayTimeline.strip(widths: [100, 100, 100, 100, 100, 100], available: 250, gap: 4, maxRows: 2, moreWidth: 40)
        #expect(many.rows == [[0, 1], [2, 3]])
        #expect(many.hidden == [4, 5])
        let tight = DayTimeline.strip(widths: [100, 100, 100, 100, 100], available: 250, gap: 4, maxRows: 2, moreWidth: 60)
        #expect(tight.rows == [[0, 1], [2]])
        #expect(tight.hidden == [3, 4])
        // A chip wider than the row goes in a row of its own, cut to it.
        let wide = DayTimeline.strip(widths: [400, 50], available: 250, gap: 4, maxRows: 2, moreWidth: 40)
        #expect(wide.rows == [[0], [1]])
        #expect(DayTimeline.strip(widths: [], available: 250, gap: 4, maxRows: 2, moreWidth: 40) == DayTimeline.Strip(rows: [], hidden: []))
    }
}

/// Which boxes the day screen fills with the accent (task 196): the events
/// under way, else the next one to start; never an ended or all-day event.
@Suite struct DayTimelineFocusTests {
    private let zone = TimeZone(identifier: "America/New_York")!
    private let link = UUID()

    private func at(_ time: String) -> Date {
        ISO8601DateFormatter().date(from: "2026-11-23T\(time):00-05:00")!
    }

    private var day: DateInterval {
        DayTimeline.bounds(of: at("12:00"), in: zone)
    }

    private func rows(_ events: [(String, String, String)], allDay: Set<String> = [], now: Date) -> [DayRow] {
        events.map { title, start, end in
            let event = allDay.contains(title)
                ? UpcomingEvent(link: link, title: title, start: day.start, end: day.end, allDay: true, date: "2026-11-23")
                : UpcomingEvent(link: link, title: title, start: at(start), end: at(end), allDay: false)
            return DayRow(
                event: event, label: EventLabel(event: event, now: now, timeZone: zone, clock: .twelveHour),
                hasEnded: event.hasEnded(at: now)
            )
        }
    }

    private let day1 = [
        ("Market", "00:00", "00:00"),
        ("Run", "07:00", "08:00"),
        ("Planning", "09:00", "10:30"),
        ("Call", "09:30", "10:00"),
        ("Lunch", "12:30", "13:30"),
        ("Dentist", "15:00", "16:00"),
        ("Swim", "15:00", "16:30"),
    ]

    @Test func everyEventUnderWayIsFilled() {
        let now = at("09:45")
        let result = DayTimelineFocus.highlighted(rows: rows(day1, allDay: ["Market"], now: now), day: day, now: now)
        #expect(result == [2, 3])
    }

    @Test func withNoneUnderWayTheNextIsFilled() {
        let now = at("11:00")
        let result = DayTimelineFocus.highlighted(rows: rows(day1, allDay: ["Market"], now: now), day: day, now: now)
        #expect(result == [4])
        // Two that start together are both next.
        let later = at("14:00")
        #expect(DayTimelineFocus.highlighted(rows: rows(day1, allDay: ["Market"], now: later), day: day, now: later) == [5, 6])
    }

    @Test func endedAndAllDayEventsAreNeverFilled() {
        let now = at("17:00")
        // Only the all-day event is left, and it is in the strip.
        #expect(DayTimelineFocus.highlighted(rows: rows(day1, allDay: ["Market"], now: now), day: day, now: now).isEmpty)
        // An event that ends at the now is over.
        let atEnd = at("08:00")
        #expect(!DayTimelineFocus.highlighted(rows: rows(day1, allDay: ["Market"], now: atEnd), day: day, now: atEnd).contains(1))
        #expect(DayTimelineFocus.highlighted(rows: [], day: day, now: now).isEmpty)
    }

    @Test func aMomentWithNoLengthIsNextUntilItPasses() {
        let events = [("Medicine", "08:00", "08:00"), ("Call", "09:00", "09:05")]
        let before = at("07:30")
        #expect(DayTimelineFocus.highlighted(rows: rows(events, now: before), day: day, now: before) == [0])
        let after = at("08:01")
        #expect(DayTimelineFocus.highlighted(rows: rows(events, now: after), day: day, now: after) == [1])
    }
}
