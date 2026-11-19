import Foundation
import Testing
import UIKit

@testable import Seasign

/// Today's fixed overlay (design v11), against the mockup's figures
/// (`design-ideas/v11-artemis/index.html`, 393 x 852).
@Suite struct TodayOverlayLayoutTests {
    private let zone = TimeZone(identifier: "America/New_York")!
    private let iPhone16 = CGSize(width: 393, height: 852)
    /// 11:36 on Monday 16 November in New York.
    private var now: Date { Date(timeIntervalSince1970: 1_794_846_960) }

    private func labels(_ titles: [String]) -> [EventLabel] {
        titles.enumerated().map { index, title in
            let start = now.addingTimeInterval(Double(index + 1) * 3600)
            let event = UpcomingEvent(link: UUID(), title: title, start: start, end: start.addingTimeInterval(1800), allDay: false)
            return EventLabel(event: event, now: now, timeZone: zone, clock: .twelveHour)
        }
    }

    private func layout(_ titles: [String], prompt: Bool = false, size: CGSize? = nil) -> TodayOverlayLayout {
        TodayOverlayLayout(
            size: size ?? iPhone16, labels: labels(titles), showsZipPrompt: prompt, date: "NOV 16", weekday: "Mon"
        )
    }

    private let sample = ["Hanna\u{2019}s show", "Submit work hours for studio payroll", "Brush pets teeth"]

    @Test func theMockupSampleMatchesItsFigures() {
        let layout = layout(sample)
        #expect(layout.rows.map(\.lines.count) == [1, 2, 1])
        #expect(layout.rows.map(\.top) == [72, 98, 140])
        // The box's bottom and the hairline at 168.
        #expect(abs(layout.hairlineY - 168) < 0.5)
        #expect(layout.box == CGRect(x: 96, y: 64, width: 281, height: layout.hairlineY - 64))
        #expect(layout.timeX == 112)
        #expect(abs(layout.titleX - 178) < 0.01)
        #expect(abs(layout.titleWidth - 191) < 0.01)
        // Buttons centred on x 331, tops 18, 63 and 108 under the hairline.
        #expect(layout.buttonCenters.map(\.x) == [331, 331, 331])
        let hairline = layout.hairlineY
        let tops: [CGFloat] = layout.buttonCenters.map { (center: CGPoint) -> CGFloat in center.y - 9.5 - hairline }
        #expect(tops == [18, 63, 108])
        // ∀: 10 points, centred, top 58 above the bottom.
        #expect(layout.allRect == CGRect(x: 191.5, y: 794, width: 10, height: 10))
        #expect(layout.headlinesTop == 486)
        #expect(abs(layout.headlineRowTop(4) - (486 + 4 * 57)) < 0.01)
    }

    @Test func leftColumnLinesUpWithTheEvents() {
        let layout = layout(sample)
        let fonts = layout.fonts
        let dateTop = layout.dateBaseline - fonts.date.capHeight
        let firstEventTop = layout.rows[0].top + layout.eventBaseline - fonts.event.capHeight
        #expect(abs(dateTop - firstEventTop) < 0.01)
        let lastEventBaseline = layout.rows[2].top + layout.eventBaseline
        #expect(abs(layout.temperatureBaseline - lastEventBaseline) < 0.01)
        // The day name midway between the date and the temperature.
        let above = layout.dayBaseline - layout.dayFont.capHeight - layout.dateBaseline
        let below = layout.temperatureBaseline - fonts.temperature.capHeight - layout.dayBaseline
        #expect(abs(above - below) < 0.01)
        // And as wide as the date.
        let dateWidth = TodayType.width("NOV 16", font: fonts.date, tracking: TodayOverlayLayout.Fonts.dateTracking)
        let dayWidth = TodayType.width("MON", font: layout.dayFont, tracking: TodayOverlayLayout.Fonts.dayTracking)
        #expect(abs(dateWidth - dayWidth) < 0.05)
        #expect(layout.dayFont.fontName == FontName.todayDayName)
    }

    @Test func theWidestDateClearsTheEventsBox() {
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let fonts = TodayOverlayLayout.Fonts(scale: 1)
        let widest = months.flatMap { month in (1...31).map { "\(month) \($0)" } }
            .map { TodayType.width($0, font: fonts.date, tracking: TodayOverlayLayout.Fonts.dateTracking) }
            .max() ?? 0
        #expect(34 + widest < 96 - 8)
    }

    @Test func noEventsMeansNoBoxAndTheHairlineUnderTheTemperature() {
        let layout = layout([])
        #expect(layout.box == nil)
        #expect(layout.rows.isEmpty && layout.prompt == nil)
        #expect(abs(layout.hairlineY - (layout.temperatureBaseline + 16)) < 0.01)
        // About where the sample puts it, so nothing below jumps.
        #expect(abs(layout.hairlineY - 168) < 1)
    }

    @Test func oneEventStretchesTheBoxToTheHairline() {
        let layout = layout(["Dentist"])
        #expect(layout.rows.count == 1)
        #expect(layout.box?.maxY == layout.hairlineY)
        #expect(abs(layout.hairlineY - (layout.temperatureBaseline + 16)) < 0.01)
    }

    @Test func theBoxNeverOutgrowsFiveLines() {
        let long = Array(repeating: "A very long event title that will need two lines here", count: 3)
        let full = layout(long)
        // Three events kept; the last title is cut to one line.
        #expect(full.rows.map(\.lines.count) == [2, 2, 1])
        #expect(full.rows.last?.lines.first?.hasSuffix("…") == true)
        // 72 + 5 * 16 + 2 * 10 + 12.
        #expect(full.hairlineY == 184)

        // With the zip prompt under them, titles are cut to one line from
        // the last up; the three events stay.
        let prompted = layout(long, prompt: true)
        #expect(prompted.prompt != nil)
        #expect(prompted.rows.map(\.lines.count) == [1, 1, 1])
        #expect(prompted.hairlineY <= 184)

        // The saved button ends by 311, above the top of a sun or moon low
        // at the right of the path (about 324 at its highest there).
        let lastBottom: CGFloat = (full.buttonCenters.last?.y ?? 0) + 9.5
        #expect(lastBottom <= 311.5)
    }

    @Test func eventsAreDroppedOnlyWhenEveryTitleIsOneLine() {
        // A two-line prompt is not reachable at 393 wide, so check the
        // budget directly: three one-line events and the prompt fit.
        let short = layout(["A", "B", "C"], prompt: true)
        #expect(short.rows.count == 3)
        #expect(short.prompt != nil)
    }

    /// Every weekday at the widest and narrowest dates: the day name stays
    /// clear of the date and the temperature. Its size follows the date's
    /// width, as the plan asks, so it swings widely: about 14.7 pt (MON on
    /// JUL 1) to 38.4 pt (FRI on NOV 20) against the mockup's 28.
    @Test func everyDayNameFitsBetweenTheDateAndTheTemperature() {
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let fonts = TodayOverlayLayout.Fonts(scale: 1)
        let dates = months.flatMap { month in (1...31).map { "\(month) \($0)" } }
        func width(_ date: String) -> CGFloat {
            TodayType.width(date, font: fonts.date, tracking: TodayOverlayLayout.Fonts.dateTracking)
        }
        let widest = dates.max { width($0) < width($1) } ?? "NOV 16"
        let narrowest = dates.min { width($0) < width($1) } ?? "NOV 16"
        for date in [widest, narrowest] {
            for day in ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] {
                let layout = TodayOverlayLayout(size: iPhone16, labels: [], showsZipPrompt: false, date: date, weekday: day)
                let size = layout.dayFont.pointSize
                #expect(size > 12 && size < 42, "\(day) on \(date): \(size)")
                let above = layout.dayBaseline - layout.dayFont.capHeight - layout.dateBaseline
                let below = layout.temperatureBaseline - layout.fonts.temperature.capHeight - layout.dayBaseline
                #expect(above > 6 && below > 6, "\(day) on \(date): \(above), \(below)")
                print("day name \(day) on \(date): \(size) pt, gaps \(above)")
            }
        }
    }

    @Test func thePromptAloneSitsInTheBox() {
        let layout = layout([], prompt: true)
        #expect(layout.rows.isEmpty)
        #expect(layout.prompt?.top == 72)
        #expect(layout.prompt?.lines == [TodayOverlayLayout.zipPromptText])
        #expect(layout.box != nil)
    }

    @Test func aWiderTimeWidensTheColumnsForEveryRow() {
        let later = UpcomingEvent(
            link: UUID(), title: "Dentist", start: now.addingTimeInterval(2 * 86_400),
            end: now.addingTimeInterval(2 * 86_400 + 1800), allDay: false
        )
        let label = EventLabel(event: later, now: now, timeZone: zone, clock: .twelveHour)
        #expect(label.timeLead == "WED 11:36")
        let layout = TodayOverlayLayout(
            size: iPhone16, labels: labels(["A"]) + [label], showsZipPrompt: false, date: "NOV 16", weekday: "Mon"
        )
        let leadWidth = TodayType.width("WED 11:36", font: layout.fonts.time, tracking: TodayOverlayLayout.Fonts.timeTracking)
        #expect(layout.tailX > layout.timeX + leadWidth)
        #expect(layout.titleX > 178)
    }

    @Test func aSmallScreenScalesEverything() {
        let se = CGSize(width: 375, height: 667)
        let layout = layout(sample, size: se)
        let s = 375.0 / 393.0
        #expect(abs(layout.hairlineY - 168 * s) < 0.5)
        #expect(abs(layout.allRect.minY - (667 - 58 * s)) < 0.01)
        // Room for at least two one-line article rows above ∀'s target.
        let available = layout.headlinesBottom - layout.headlinesTop
        #expect(HeadlineFit.count(
            textHeights: [layout.titleLineHeight, layout.titleLineHeight, layout.titleLineHeight],
            pitch: layout.headlinePitch, available: available
        ) >= 2)
    }
}
