import SwiftUI
import UIKit

/// The day screen's timeline (task 181): the all-day strip, then the whole
/// day from midnight to midnight in the height that is left, an event's box
/// running from its start to its end (`DayTimeline` places everything).
/// Hour lines with the clock in the gutter on the left, a line in the sun's
/// red at the current time with the time beside it, ended events dimmed as
/// on the list before it. Fixed type sizes, since the screen does not
/// scroll and the day has to fit.
///
/// Design v12 (task 196): the HUD's mono type on the dark plate; the hour
/// labels and lines dim; each box and all-day chip outlined in the user's
/// accent (`\.hudAccent`) with accent words, the event under way (or, with
/// none, the next one) filled with the accent and dark words
/// (`DayTimelineFocus`); the now line, its dot and time in white, Today's
/// colour for what is live, so it never sinks into an accent box.
///
/// VoiceOver reads the all-day events, then each box in order of start:
/// title, start, end and length (`DayTimeline.spoken`). The lines and
/// labels are hidden from it.
struct DayTimelineView: View {
    var rows: [DayRow]
    var day: DateInterval
    var zone: TimeZone
    var now: Date
    var clock: ClockStyle

    @Environment(\.hudAccent) private var accent

    /// The type and sizes, measured from the fonts that draw them.
    private enum Style {
        static let titleFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        static let titleTracking: CGFloat = 0.02
        static let timeFont = TodayType.mono(8.5)
        static let labelFont = TodayType.mono(8.5)
        static let gutterGap: CGFloat = 6
        static let boxInset: CGFloat = 5
        static let chipHeight: CGFloat = 18
        static let chipGap: CGFloat = 4
        /// The outline of a box or chip, and its corners: Today's tiles'.
        static let line: CGFloat = 1
        static let radius: CGFloat = HUDShape.radius
        static let stripRows = 2
        /// Between the strip and the grid.
        static let stripGap: CGFloat = 6

        static let metrics = DayTimeline.Metrics(
            titleLine: ceil(titleFont.lineHeight),
            timeLine: ceil(timeFont.lineHeight),
            padding: 2,
            columnGap: 2,
            inset: 6,
            labelSpacing: ceil(labelFont.lineHeight) + 3
        )
    }

    private var gutter: CGFloat {
        // The widest label each form can show, the now label included.
        let samples = clock == .twelveHour ? ["12:59PM", "12PM", "ALL"] : ["23:59", "ALL"]
        return ceil(samples.map { TodayType.width($0, font: Style.labelFont, tracking: 0) }.max() ?? 30)
    }

    var body: some View {
        GeometryReader { geometry in
            let allDay = rows.indices.filter { DayTimeline.isAllDay(rows[$0].event, day: day) }
            let areaWidth = max(40, geometry.size.width - gutter - Style.gutterGap)
            let stripLayout = DayTimeline.strip(
                widths: allDay.map { chipWidth(rows[$0].label.title) }, available: areaWidth, gap: Style.chipGap,
                maxRows: Style.stripRows, moreWidth: chipWidth("+\(allDay.count) more")
            )
            let count = CGFloat(stripLayout.rows.count)
            let stripHeight = allDay.isEmpty ? 0 : count * Style.chipHeight + (count - 1) * Style.chipGap + Style.stripGap
            VStack(alignment: .leading, spacing: 0) {
                if !allDay.isEmpty {
                    strip(allDay, layout: stripLayout, width: areaWidth)
                        .frame(height: stripHeight - Style.stripGap, alignment: .top)
                        .padding(.bottom, Style.stripGap)
                }
                grid(size: CGSize(width: geometry.size.width, height: max(0, geometry.size.height - stripHeight)))
            }
        }
    }

    // MARK: The all-day strip

    private func chipWidth(_ title: String) -> CGFloat {
        ceil(TodayType.width(title.uppercased(), font: Style.titleFont, tracking: Style.titleTracking)) + 2 * Style.boxInset + 1
    }

    /// The chips in `layout`'s rows; what did not fit is one "+N" chip.
    private func strip(_ indices: [Int], layout: DayTimeline.Strip, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Style.gutterGap) {
            Text(verbatim: "ALL DAY")
                .font(Font(Style.labelFont as CTFont))
                .foregroundStyle(Palette.dimText)
                .multilineTextAlignment(.trailing)
                .frame(width: gutter, alignment: .trailing)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Style.chipGap) {
                ForEach(Array(layout.rows.enumerated()), id: \.offset) { rowNumber, chips in
                    HStack(spacing: Style.chipGap) {
                        ForEach(chips, id: \.self) { position in
                            chip(rows[indices[position]])
                        }
                        if rowNumber == layout.rows.count - 1, !layout.hidden.isEmpty {
                            moreChip(layout.hidden.map { rows[indices[$0]] })
                        }
                    }
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private func chip(_ row: DayRow) -> some View {
        Text(caps: row.label.title)
            .font(Font(Style.titleFont as CTFont))
            .tracking(Style.titleFont.pointSize * Style.titleTracking)
            .foregroundStyle(accent)
            .lineLimit(1)
            .opacity(row.hasEnded ? DayTimelineFocus.endedOpacity : 1)
            .padding(.horizontal, Style.boxInset)
            .frame(height: Style.chipHeight)
            .background(BoxBackground(cutTop: false, cutBottom: false, dimmed: row.hasEnded, filled: false))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text(verbatim: spoken(row)))
    }

    /// The all-day events that did not fit, read out in full by VoiceOver.
    private func moreChip(_ hidden: [DayRow]) -> some View {
        Text(caps: "+\(hidden.count) more")
            .font(Font(Style.titleFont as CTFont))
            .tracking(Style.titleFont.pointSize * Style.titleTracking)
            .foregroundStyle(Palette.dimText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Style.boxInset)
            .frame(height: Style.chipHeight)
            .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Palette.rule, lineWidth: Style.line))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text(verbatim: "\(hidden.count) more all-day: " + hidden.map(spoken).joined(separator: "; ")))
    }

    // MARK: The grid

    private func grid(size: CGSize) -> some View {
        let areaX = gutter + Style.gutterGap
        let areaWidth = max(40, size.width - areaX)
        let events = rows.map(\.event)
        let focus = DayTimelineFocus.highlighted(rows: rows, day: day, now: now)
        let layout = DayTimeline.layout(
            events: events, day: day, zone: zone, now: now,
            height: size.height, width: areaWidth, metrics: Style.metrics
        )
        // VoiceOver reads the boxes by start, whatever their column.
        let spokenOrder = layout.boxes.map(\.index).sorted { first, second in
            let a = rows[first].event
            let b = rows[second].event
            return a.start != b.start ? a.start < b.start : first < second
        }
        return ZStack(alignment: .topLeading) {
            hourLines(layout, from: areaX, width: areaWidth)
            // The line runs under the boxes so it never crosses a title; its
            // dot and time stay on top, at the gutter's edge.
            if let nowY = layout.nowY {
                Rectangle()
                    .fill(Palette.white)
                    .frame(width: areaWidth, height: 1)
                    .position(x: areaX + areaWidth / 2, y: nowY)
                    .accessibilityHidden(true)
            }
            ForEach(layout.boxes, id: \.index) { box in
                boxView(rows[box.index], box: box, filled: focus.contains(box.index))
                    .offset(x: areaX + box.frame.minX, y: box.frame.minY)
                    .accessibilitySortPriority(Double(layout.boxes.count - (spokenOrder.firstIndex(of: box.index) ?? 0)))
            }
            if let nowY = layout.nowY {
                nowLine(at: nowY, from: areaX, width: areaWidth, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func hourLines(_ layout: DayTimeline.Layout, from x: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for mark in layout.hours {
                    path.move(to: CGPoint(x: x, y: mark.y))
                    path.addLine(to: CGPoint(x: x + width, y: mark.y))
                }
            }
            .stroke(Palette.rule.opacity(0.5), lineWidth: 0.5)
            ForEach(layout.hours.filter(\.labelled), id: \.date) { mark in
                Text(verbatim: DayTimeline.hourLabel(hour: mark.hour, minute: mark.minute, clock: clock))
                    .font(Font(Style.labelFont as CTFont))
                    .foregroundStyle(Palette.dimText)
                    .fixedSize()
                    .frame(width: gutter, alignment: .trailing)
                    .position(x: gutter / 2, y: mark.y)
            }
        }
        .accessibilityHidden(true)
    }

    /// The current time's dot at the start of its line (drawn under the
    /// boxes) and the time in the gutter (the hour labels near it are left out).
    private func nowLine(at y: CGFloat, from x: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        let half = Style.labelFont.lineHeight / 2
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(Palette.white)
                .frame(width: 5, height: 5)
                .position(x: x, y: y)
            Text(verbatim: DayTimeline.startText(
                UpcomingEvent(link: UUID(), title: "", start: now, end: now, allDay: false), zone: zone, clock: clock
            ))
            .font(Font(Style.labelFont as CTFont))
            .foregroundStyle(Palette.white)
            .fixedSize()
            .frame(width: gutter, alignment: .trailing)
            .position(x: gutter / 2, y: min(max(y, half), height - half))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func boxView(_ row: DayRow, box: DayTimeline.Box, filled: Bool) -> some View {
        let title = Text(caps: row.label.title)
            .font(Font(Style.titleFont as CTFont))
            .tracking(Style.titleFont.pointSize * Style.titleTracking)
            .foregroundStyle(filled ? Palette.onAccent : accent)
        return Group {
            switch box.content {
            case .title:
                // The start beside the title when both fit, else the title alone.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        title.lineLimit(1).fixedSize()
                        time(DayTimeline.startText(row.event, zone: zone, clock: clock), filled: filled).fixedSize()
                    }
                    title.lineLimit(1)
                }
            case .titleAndTime(let lines):
                VStack(alignment: .leading, spacing: 0) {
                    title.lineLimit(lines)
                    time(DayTimeline.timeText(row.event, zone: zone, clock: clock), filled: filled).lineLimit(1)
                }
            }
        }
        .opacity(row.hasEnded ? DayTimelineFocus.endedOpacity : 1)
        .padding(.horizontal, Style.boxInset)
        .padding(.vertical, Style.metrics.padding)
        .frame(width: box.frame.width, height: box.frame.height, alignment: .topLeading)
        .background(BoxBackground(cutTop: box.startsBefore, cutBottom: box.endsAfter, dimmed: row.hasEnded, filled: filled))
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(Text(verbatim: spoken(row)))
    }

    private func time(_ text: String, filled: Bool) -> some View {
        Text(verbatim: text)
            .font(Font(Style.timeFont as CTFont))
            .foregroundStyle(filled ? Palette.onAccent : Palette.dimText)
    }

    private func spoken(_ row: DayRow) -> String {
        DayTimeline.spoken(row.event, day: day, zone: zone, now: now, clock: clock)
    }
}

/// An event's box: the plate, so the hour lines and the now line do not
/// show through, outlined in the accent, or filled with it for the event
/// under way or next (`DayTimelineFocus`). The corners are square where the
/// event is cut at midnight. An ended event's outline is dimmed but its
/// ground stays opaque, so the hour lines stay hidden.
private struct BoxBackground: View {
    var cutTop: Bool
    var cutBottom: Bool
    var dimmed: Bool
    var filled: Bool

    @Environment(\.hudAccent) private var accent

    var body: some View {
        let radius = HUDShape.radius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: cutTop ? 0 : radius, bottomLeadingRadius: cutBottom ? 0 : radius,
            bottomTrailingRadius: cutBottom ? 0 : radius, topTrailingRadius: cutTop ? 0 : radius
        )
        ZStack {
            shape.fill(Palette.hudPlate)
            Group {
                if filled {
                    shape.fill(accent)
                } else {
                    shape.strokeBorder(accent, lineWidth: 1)
                }
            }
            .opacity(dimmed ? DayTimelineFocus.endedOpacity : 1)
        }
    }
}

/// Which boxes on the day's timeline are filled with the accent (task 196):
/// every timed event under way at `now`, or, when none is, the next one to
/// start (all of them if several start together). Ended events and the
/// all-day strip never are. Pure, so the rule is tested.
enum DayTimelineFocus {
    /// An ended event's words and outline: dimmer than the rest, still
    /// readable as accent on the plate (was 0.4 on the charcoal).
    static let endedOpacity = 0.5

    static func highlighted(rows: [DayRow], day: DateInterval, now: Date) -> Set<Int> {
        let timed = rows.indices.filter { index in
            let event = rows[index].event
            return !rows[index].hasEnded && !DayTimeline.isAllDay(event, day: day) && DayTimeline.isInDay(event, day: day)
        }
        let live = timed.filter { rows[$0].event.start <= now }
        if !live.isEmpty { return Set(live) }
        guard let next = timed.map({ rows[$0].event.start }).min() else { return [] }
        return Set(timed.filter { rows[$0].event.start == next })
    }
}
