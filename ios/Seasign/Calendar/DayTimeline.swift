import CoreGraphics
import Foundation

/// Where everything on the day screen's timeline goes (task 181), as Google
/// Calendar draws a day: the top of an event's box is its start, the bottom
/// its end, and the whole day, midnight to midnight in the events' zone,
/// fits the height it is given. Pure, so every rule is tested.
///
/// - The scale is real time: a point is the same number of seconds all day,
///   so a 23- or 25-hour day (a clock change) has one hour fewer or more,
///   and its hour lines are labelled by the clock (`1AM`, `3AM` on the day
///   the clocks go forward).
/// - All-day events, and a timed event that covers the whole day, go to the
///   strip above the grid.
/// - A box is never shorter than one title line (`Metrics.minimumBoxHeight`):
///   an event without a length, or a short one, is drawn that tall, and one
///   that would run past the bottom is moved up to end there.
/// - An event running past either midnight is cut at that edge.
/// - Boxes that touch on screen (after the minimum height) sit side by side
///   in columns. A group of boxes that overlap, directly or through others,
///   shares one column count; a box widens into the columns to its right
///   that are free for its whole height.
enum DayTimeline {
    /// The sizes the layout works with, in points. The view sets them from
    /// its fonts; the tests use the defaults.
    struct Metrics: Equatable, Sendable {
        /// Height of one title line in a box.
        var titleLine: CGFloat = 12
        /// Height of the time line under the title.
        var timeLine: CGFloat = 11
        /// Space above and below a box's text.
        var padding: CGFloat = 2
        /// Horizontal space between boxes side by side.
        var columnGap: CGFloat = 2
        /// Kept clear above midnight and below the next midnight.
        var inset: CGFloat = 4
        /// The least distance between two labelled hour lines, and between an
        /// hour label and the now label: about a label's height.
        var labelSpacing: CGFloat = 13

        /// The shortest box: one title line with its padding.
        var minimumBoxHeight: CGFloat {
            titleLine + 2 * padding
        }
    }

    /// What a box has room for.
    enum Content: Equatable, Sendable {
        /// One line: the title (with the start beside it when it fits).
        case title
        /// The title on up to `titleLines` lines, the time under it.
        case titleAndTime(titleLines: Int)
    }

    /// One timed event's box in the grid.
    struct Box: Equatable, Sendable {
        /// Index of the event in the list given to `layout`.
        var index: Int
        /// In the events' area: x from its left edge, y from the grid's top.
        var frame: CGRect
        var column: Int
        /// Columns of the group of overlapping boxes it belongs to.
        var columns: Int
        /// Columns it covers, counting its own (it widens into free ones).
        var span: Int
        /// The event began before the day: the box is cut at the top.
        var startsBefore: Bool
        /// The event ends after the day: the box is cut at the bottom.
        var endsAfter: Bool
        var content: Content
    }

    /// One line across the grid at a clock hour.
    struct HourMark: Equatable, Sendable {
        var date: Date
        /// The clock in the events' zone at the line: 0 to 23 and 0 to 59.
        var hour: Int
        var minute: Int
        var y: CGFloat
        /// Whether the line has its time written beside it: not the two
        /// midnights at the edges, only every `labelStep`th hour when hours
        /// are short, and never close to the now label.
        var labelled: Bool
    }

    struct Layout: Equatable, Sendable {
        /// Indices of the events that go to the strip, in the order given.
        var allDay: [Int]
        /// The timed events' boxes, by start (then the longer first).
        var boxes: [Box]
        /// Every hour line from midnight to the next midnight, both included.
        var hours: [HourMark]
        /// Hours between labelled lines: 1, 2, 3, 4 or 6.
        var labelStep: Int
        /// Points per hour.
        var hourHeight: CGFloat
        /// The current time's line; nil when `now` is not in the day.
        var nowY: CGFloat?

        /// Where the now line crosses `box`, from the box's top; nil when it
        /// does not cross it (task 208: the view draws this piece of the
        /// line over the filled box, which would otherwise hide it). Nil
        /// too when the event has not `started`: a box near midnight is
        /// moved up to stay in the day, so its top can be earlier than its
        /// start, and the line must not cross an event that is still to come.
        func nowY(in box: Box, started: Bool) -> CGFloat? {
            guard started, let nowY, nowY >= box.frame.minY, nowY <= box.frame.maxY else { return nil }
            return nowY - box.frame.minY
        }
    }

    /// The day `date` falls on in `zone`, from its midnight to the next:
    /// 23, 24 or 25 hours long.
    static func bounds(of date: Date, in zone: TimeZone) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start).map { calendar.startOfDay(for: $0) }
        return DateInterval(start: start, end: max(next ?? start.addingTimeInterval(86_400), start.addingTimeInterval(3600)))
    }

    /// Whether an event goes to the strip: all-day, or timed and covering
    /// the whole day.
    static func isAllDay(_ event: UpcomingEvent, day: DateInterval) -> Bool {
        event.allDay || (event.start <= day.start && event.end >= day.end)
    }

    /// Whether a timed event is seen in the day at all: it overlaps it, or
    /// has no length and starts in it.
    static func isInDay(_ event: UpcomingEvent, day: DateInterval) -> Bool {
        if event.end == event.start { return event.start >= day.start && event.start < day.end }
        return event.start < day.end && event.end > day.start
    }

    /// The layout of `events` (any order) for `day` in `zone`, in a grid
    /// `height` tall whose events' area is `width` wide.
    static func layout(
        events: [UpcomingEvent],
        day: DateInterval,
        zone: TimeZone,
        now: Date?,
        height: CGFloat,
        width: CGFloat,
        metrics: Metrics = Metrics()
    ) -> Layout {
        let top = metrics.inset
        let bottom = max(top + metrics.minimumBoxHeight, height - metrics.inset)
        let span = bottom - top
        let seconds = max(day.duration, 1)
        func y(_ date: Date) -> CGFloat {
            top + CGFloat(date.timeIntervalSince(day.start) / seconds) * span
        }
        let hourHeight = span * 3600 / CGFloat(seconds)

        // The strip, and the timed events with their boxes' heights on screen.
        var allDay: [Int] = []
        struct Item {
            var index: Int
            var top: CGFloat
            var bottom: CGFloat
            var startsBefore: Bool
            var endsAfter: Bool
            var column = 0
        }
        var items: [Item] = []
        for (index, event) in events.enumerated() {
            if isAllDay(event, day: day) {
                allDay.append(index)
                continue
            }
            guard isInDay(event, day: day) else { continue }
            var boxTop = y(max(event.start, day.start))
            var boxBottom = max(y(min(event.end, day.end)), boxTop + metrics.minimumBoxHeight)
            if boxBottom > bottom {
                boxBottom = bottom
                boxTop = min(boxTop, max(top, bottom - metrics.minimumBoxHeight))
            }
            items.append(Item(
                index: index, top: boxTop, bottom: boxBottom,
                startsBefore: event.start < day.start, endsAfter: event.end > day.end
            ))
        }
        items.sort { first, second in
            if first.top != second.top { return first.top < second.top }
            if first.bottom != second.bottom { return first.bottom > second.bottom }
            return first.index < second.index
        }

        // Groups of boxes that overlap on screen, each with its columns.
        var boxes: [Box] = []
        var group: [Item] = []
        var groupBottom = -CGFloat.infinity
        func close() {
            guard !group.isEmpty else { return }
            let columns = (group.map(\.column).max() ?? 0) + 1
            let columnWidth = (width + metrics.columnGap) / CGFloat(columns)
            for item in group {
                var covered = 1
                while item.column + covered < columns {
                    let next = item.column + covered
                    let blocked = group.contains { $0.column == next && $0.top < item.bottom && item.top < $0.bottom }
                    if blocked { break }
                    covered += 1
                }
                let frame = CGRect(
                    x: CGFloat(item.column) * columnWidth,
                    y: item.top,
                    width: max(0, CGFloat(covered) * columnWidth - metrics.columnGap),
                    height: item.bottom - item.top
                )
                boxes.append(Box(
                    index: item.index, frame: frame, column: item.column, columns: columns, span: covered,
                    startsBefore: item.startsBefore, endsAfter: item.endsAfter,
                    content: content(height: frame.height, metrics: metrics)
                ))
            }
            group = []
        }
        var columnBottoms: [CGFloat] = []
        for var item in items {
            if item.top >= groupBottom {
                close()
                columnBottoms = []
                groupBottom = -CGFloat.infinity
            }
            if let free = columnBottoms.firstIndex(where: { $0 <= item.top }) {
                item.column = free
                columnBottoms[free] = item.bottom
            } else {
                item.column = columnBottoms.count
                columnBottoms.append(item.bottom)
            }
            groupBottom = max(groupBottom, item.bottom)
            group.append(item)
        }
        close()

        // The now line, then the hour lines.
        let nowY = now.flatMap { day.contains($0) && $0 < day.end ? y($0) : nil }
        var step = 1
        for candidate in [1, 2, 3, 4, 6] {
            step = candidate
            if CGFloat(candidate) * hourHeight >= metrics.labelSpacing { break }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var hours: [HourMark] = []
        let count = Int((seconds / 3600).rounded())
        for offset in 0...count {
            let date = offset == count ? day.end : day.start.addingTimeInterval(TimeInterval(offset) * 3600)
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let lineY = offset == count ? bottom : y(date)
            let edge = offset == 0 || offset == count
            let nearNow = nowY.map { abs($0 - lineY) < metrics.labelSpacing } ?? false
            hours.append(HourMark(
                date: date, hour: parts.hour ?? 0, minute: parts.minute ?? 0, y: lineY,
                labelled: !edge && offset % step == 0 && !nearNow
            ))
        }

        return Layout(allDay: allDay, boxes: boxes, hours: hours, labelStep: step, hourHeight: hourHeight, nowY: nowY)
    }

    /// What a box `height` tall shows.
    static func content(height: CGFloat, metrics: Metrics) -> Content {
        let room = height - 2 * metrics.padding
        guard room >= metrics.titleLine + metrics.timeLine else { return .title }
        return .titleAndTime(titleLines: max(1, Int(((room - metrics.timeLine) / metrics.titleLine).rounded(.down))))
    }

    // MARK: The all-day strip

    /// How the all-day chips are laid out: in rows across `available`, at
    /// most `maxRows`; what does not fit is folded into one "+N" chip at the
    /// end of the last row (which VoiceOver reads out in full).
    struct Strip: Equatable, Sendable {
        /// Positions in the list of widths given, row by row.
        var rows: [[Int]]
        /// Positions folded into the "+N" chip, in order.
        var hidden: [Int]
    }

    /// `widths` are the chips' natural widths (a chip wider than the row is
    /// cut to it); `moreWidth` the "+N" chip's.
    static func strip(widths: [CGFloat], available: CGFloat, gap: CGFloat, maxRows: Int, moreWidth: CGFloat) -> Strip {
        // A chip that starts a row always goes in it, cut to what is left.
        func flow(_ indices: [Int], reserveOnLastRow reserve: CGFloat) -> (rows: [[Int]], placed: Int) {
            var rows: [[Int]] = [[]]
            var used: CGFloat = 0
            var placed = 0
            for index in indices {
                let width = min(widths[index], available)
                while true {
                    let isLast = rows.count == maxRows
                    let limit = isLast ? available - reserve : available
                    let empty = rows[rows.count - 1].isEmpty
                    let needed = empty ? width : used + gap + width
                    if needed <= limit || empty {
                        rows[rows.count - 1].append(index)
                        used = min(needed, limit)
                        placed += 1
                        break
                    }
                    if isLast { return (rows, placed) }
                    rows.append([])
                    used = 0
                }
            }
            return (rows.filter { !$0.isEmpty }, placed)
        }
        let all = Array(widths.indices)
        guard maxRows > 0 else { return Strip(rows: [], hidden: all) }
        let plain = flow(all, reserveOnLastRow: 0)
        if plain.placed == all.count { return Strip(rows: plain.rows, hidden: []) }
        let reserved = flow(all, reserveOnLastRow: moreWidth + gap)
        return Strip(rows: reserved.rows, hidden: Array(all.dropFirst(reserved.placed)))
    }

    // MARK: Words

    /// The time shown in a box: `9:00–10:30AM`, `11:00AM–1:00PM`,
    /// `09:00–10:30`; the start alone for an event without a length. The
    /// real times, even when the box is cut at midnight.
    static func timeText(_ event: UpcomingEvent, zone: TimeZone, clock: ClockStyle) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.dateComponents([.hour, .minute], from: event.start)
        let startShown = clock.clock(hour: start.hour ?? 0, minute: start.minute ?? 0).shown
        guard event.end > event.start else { return startShown }
        let end = calendar.dateComponents([.hour, .minute], from: event.end)
        let endShown = clock.clock(hour: end.hour ?? 0, minute: end.minute ?? 0).shown
        let startColumns = clock.columns(hour: start.hour ?? 0, minute: start.minute ?? 0)
        let endColumns = clock.columns(hour: end.hour ?? 0, minute: end.minute ?? 0)
        if let half = startColumns.half, half == endColumns.half {
            return "\(startColumns.clock)–\(endShown)"
        }
        return "\(startShown)–\(endShown)"
    }

    /// The start alone, as on Today: `9:00AM`, `09:00`.
    static func startText(_ event: UpcomingEvent, zone: TimeZone, clock: ClockStyle) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.dateComponents([.hour, .minute], from: event.start)
        return clock.clock(hour: start.hour ?? 0, minute: start.minute ?? 0).shown
    }

    /// An hour line's label: `1AM`, `12PM`, `13:00` (`1:30AM` for a line
    /// off the hour, as after a half-hour clock change).
    static func hourLabel(hour: Int, minute: Int, clock: ClockStyle) -> String {
        switch clock {
        case .twelveHour:
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let half = hour < 12 ? "AM" : "PM"
            return minute == 0 ? "\(hour12)\(half)" : "\(hour12):\(String(format: "%02d", minute))\(half)"
        case .twentyFourHour:
            return clock.clock(hour: hour, minute: minute).shown
        }
    }

    /// What VoiceOver reads for an event on the day screen: its title, start,
    /// end and length, and whether it has ended. "Coffee with Sam, 9:00 AM
    /// to 9:30 AM, 30 minutes"; "Reminder, at 3:00 PM, no end time";
    /// "Night flight, yesterday 10:00 PM to 1:30 AM, 3 hours 30 minutes";
    /// "Farmers' market, all day". Times are the real ones, with the day
    /// named when it is not `day`.
    static func spoken(_ event: UpcomingEvent, day: DateInterval, zone: TimeZone, now: Date, clock: ClockStyle) -> String {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? EventLabel.untitled : trimmed
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func when(_ date: Date) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let clockText = clock.clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0).spoken
            if day.contains(date) && date < day.end { return clockText }
            let days = calendar.dateComponents([.day], from: day.start, to: calendar.startOfDay(for: date)).day ?? 0
            let name: String
            switch days {
            case -1: name = "yesterday"
            case 1: name = "tomorrow"
            default:
                let weekday = calendar.component(.weekday, from: date) - 1
                name = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][max(0, min(6, weekday))]
            }
            return "\(name) \(clockText)"
        }
        var text: String
        if event.allDay {
            text = "\(title), all day"
        } else if event.end <= event.start {
            text = "\(title), at \(when(event.start)), no end time"
        } else {
            text = "\(title), \(when(event.start)) to \(when(event.end)), \(length(event.end.timeIntervalSince(event.start)))"
        }
        if event.hasEnded(at: now) { text += ", ended" }
        return text
    }

    /// "30 minutes", "1 hour", "1 hour 30 minutes", "2 days 3 hours".
    static func length(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        let rest = minutes % 60
        func unit(_ count: Int, _ name: String) -> String {
            "\(count) \(name)\(count == 1 ? "" : "s")"
        }
        var parts: [String] = []
        if days > 0 { parts.append(unit(days, "day")) }
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if rest > 0 { parts.append(unit(rest, "minute")) }
        return parts.joined(separator: " ")
    }
}
