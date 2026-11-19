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

    @Test func theBoxNeverOutgrowsThreeTwoLineEvents() {
        let long = Array(repeating: "A very long event title that will need two lines here", count: 3)
        let full = layout(long)
        #expect(full.rows.map(\.lines.count) == [2, 2, 2])
        // 72 + 6 * 16 + 2 * 10 + 12.
        #expect(full.hairlineY == 200)

        // With the zip prompt under them, events are dropped from the end.
        let prompted = layout(long, prompt: true)
        #expect(prompted.prompt != nil)
        #expect(prompted.rows.count == 2)
        #expect(prompted.hairlineY <= 200)
        // The last button stays clear of the horizon's sun or moon (radius
        // about 50 at the horizon, 386).
        let lastBottom: CGFloat = (prompted.buttonCenters.last?.y ?? 0) + 9.5
        #expect(lastBottom < 340)
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
