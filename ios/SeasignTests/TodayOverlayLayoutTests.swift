import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Seasign

/// Today's overlay (design v12), against the mockup's figures
/// (`design-ideas/v12-imago/index.html` and its README, 393 x 852), and the
/// plan's rules for other screens: 34-point margins, tiles that stretch, the
/// view's furniture hung from the horizon, titles that give way first.
///
/// Rewritten for v12 in task 193 from the v11 tests of the same names' places
/// (the v11 left column, hairline and buttons are gone). Task 205 changed the
/// figures for larger type: three event rows at 13 on 22 (was four at 11.3 on
/// 17), titles at 12 on two 19-point lines, 54 apart (was 10.5, 17, 51).
@Suite struct TodayOverlayLayoutTests {
    private let zone = TimeZone(identifier: "America/New_York")!
    private let iPhone16 = CGSize(width: 393, height: 852)
    private let iPhone17 = CGSize(width: 402, height: 874)
    private let proMax = CGSize(width: 440, height: 956)
    private let se = CGSize(width: 375, height: 667)
    /// 11:36 on Monday 16 November in New York.
    private var now: Date { Date(timeIntervalSince1970: 1_794_846_960) }

    /// Events today at the given hours after midnight.
    private func labels(_ titles: [String], hours: [Double]? = nil, clock: ClockStyle = .twelveHour) -> [EventLabel] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = calendar.startOfDay(for: now)
        let hours = hours ?? titles.indices.map { 12 + Double($0) }
        return zip(titles, hours).map { title, hour in
            let start = midnight.addingTimeInterval(hour * 3600)
            let event = UpcomingEvent(link: UUID(), title: title, start: start, end: start.addingTimeInterval(1800), allDay: false)
            return EventLabel(event: event, now: now, timeZone: zone, clock: clock)
        }
    }

    private func layout(_ labels: [EventLabel] = [], prompt: Bool = false, size: CGSize? = nil) -> TodayOverlayLayout {
        TodayOverlayLayout(size: size ?? iPhone16, labels: labels, showsZipPrompt: prompt)
    }

    /// The mockup's four events.
    private var sample: [EventLabel] {
        labels(
            ["Hanna\u{2019}s Show", "Wearables and sensing demo", "Submit hours for studio payroll", "Night Workout"],
            hours: [11, 13, 18.75, 20.25]
        )
    }

    private let style = HUDType.eventRow

    /// Task 170 and 193: the events box and the date tile both open the day
    /// screen, each at least 44 points; the box is there with or without
    /// events, and neither reaches the top row or the frame.
    @Test func theDayTargetIsTheBoxOrItsPlace() throws {
        for labels in [[], Array(sample.prefix(1)), sample] {
            for prompt in [false, true] {
                let layout = layout(labels, prompt: prompt)
                for target in [layout.eventsBox, layout.dateTile] {
                    #expect(target.height >= 44 && target.width >= 44)
                    #expect(target.minY >= layout.markRect.maxY + 10)
                    #expect(target.maxY <= layout.frame.minY - 10)
                }
                // The targets are the same whatever is in the box: no
                // events, one, four, with or without the zip prompt.
                #expect(layout.eventsBox == CGRect(x: 116.75, y: 105, width: 242.25, height: 78))
                #expect(layout.dateTile == CGRect(x: 34, y: 105, width: 76.75, height: 78))
                // What is in it changes, and every row stays inside the box.
                let expected = min(labels.count, prompt ? 2 : 3) + (prompt ? 1 : 0)
                #expect(layout.eventRows.count == expected, "\(labels.count) events, prompt \(prompt)")
                #expect(layout.promptIndex == (prompt ? expected - 1 : nil))
                for row in layout.eventRows {
                    let rect = CGRect(x: row.origin.x, y: row.origin.y, width: row.width, height: style.lineHeight)
                    #expect(layout.eventsBox.insetBy(dx: 1.4, dy: 1.4).contains(rect), "\(row.text)")
                }
            }
        }
    }

    /// The README's positions at 393 x 852, with task 205's event rows and
    /// title pitch.
    @Test func theMockupSampleMatchesItsFigures() {
        let layout = layout(sample)
        #expect(layout.horizonY == 386)
        #expect(layout.markRect == CGRect(x: 34, y: 66, width: 24, height: 24))
        #expect(layout.settingsRect == CGRect(x: 335, y: 66, width: 24, height: 24))
        #expect(layout.placeRight == 321)
        #expect(layout.dateTile == CGRect(x: 34, y: 105, width: 76.75, height: 78))
        #expect(layout.eventsBox == CGRect(x: 116.75, y: 105, width: 242.25, height: 78))
        #expect(layout.eventColumns == 29)
        #expect(layout.eventRows.map(\.text) == [
            "11:00 A " + String(repeating: "-", count: 6) + " Hanna\u{2019}s Show /",
            " 1:00 P - Wearables and sens/",
            " 6:45 P - Submit hours for s/",
        ])
        // Three line boxes 22 tall, centred: 4.6 under the 1.4 border and
        // 4.6 above the bottom one.
        #expect(layout.eventRows.map(\.origin.y) == [111, 133, 155])
        #expect(abs(layout.eventsBox.maxY - 1.4 - (155 + 22) - 4.6) < 0.001)
        #expect(layout.frame == CGRect(x: 34, y: 194, width: 325, height: 232))
        #expect(layout.frameLabelTop == 201.5 && layout.frameLabelLeft == 42 && layout.frameLabelRight == 349)
        #expect(layout.plate == CGRect(x: 7, y: 428, width: 379, height: 417))
        #expect(layout.rimRadius == 39)
        #expect(layout.rimGap == 190...440)
        #expect(layout.titlesTop == 461 && layout.titleWidth == 290)
        #expect(layout.titleCapacity == 5)
        #expect(layout.titleRowTop(4) == CGFloat(461 + 4 * 54))
        // Five rows still fit: the fifth ends at 461 + 216 + 38 = 715, above
        // the tiles' 17-point clearance at 734 - 17 = 717.
        #expect(layout.titleRowTop(4) + 38 <= 734 - 17)
        #expect(self.layout(size: iPhone17).titleCapacity == 5)
        #expect(layout.tiles.map(\.minX) == [34, 116.75, 199.5, 282.25])
        #expect(layout.tiles.allSatisfy { $0.minY == 734 && $0.height == 78 && $0.width == 76.75 })
    }

    /// The date tile and the events box share their top and bottom, and the
    /// rows are centred in the box with between half a character and a
    /// character free at each side.
    @Test func leftColumnLinesUpWithTheEvents() {
        let layout = layout(sample)
        #expect(layout.dateTile.minY == layout.eventsBox.minY)
        #expect(layout.dateTile.maxY == layout.eventsBox.maxY)
        #expect(abs(layout.eventsBox.minX - layout.dateTile.maxX - 6) < 0.001)
        for row in layout.eventRows {
            let left = row.origin.x - layout.eventsBox.minX
            let right = layout.eventsBox.maxX - (row.origin.x + row.width)
            #expect(abs(left - right) < 0.01)
            #expect(left >= 1.4 + style.cell / 2 - 0.01 && left < 1.4 + style.cell + 0.5, "\(left)")
        }
        // Every row starts at the same x, also when one holds wide
        // characters that measure differently from the mono cells.
        let wide = self.layout(labels(["会議資料", "Night Workout", "🎉🎂"]))
        #expect(Set(wide.eventRows.map { $0.origin.x }).count == 1)
        #expect(wide.eventRows[0].origin.x == layout.eventRows[0].origin.x)
        // Three rows fill the box: the last ends inside the border.
        let last = layout.eventRows[2].origin.y + style.lineHeight
        #expect(last <= layout.eventsBox.maxY - 1.4)
    }

    /// The widest date fits the foot of the date tile beside the slash, on
    /// the narrowest screen.
    @Test func theWidestDateClearsTheEventsBox() {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let foot = HUDType.tileFoot
        let widest = months.flatMap { month in (1...31).map { "\(month) \($0)" } }.map { foot.width($0) }.max() ?? 0
        let tile = layout(size: se).dateTile
        let inner = tile.width - 2 * (1.4 + 7)
        #expect(foot.width("/") + 4 + widest <= inner, "\(widest) of \(inner)")
    }

    /// No events: the box stays (empty), so the grid keeps its shape.
    @Test func noEventsLeavesTheBoxEmpty() {
        let layout = layout([])
        #expect(layout.eventRows.isEmpty)
        #expect(layout.promptIndex == nil)
        #expect(layout.eventsBox.width > 200)
    }

    /// One event takes the first row only; the box does not change size.
    @Test func oneEventTakesTheFirstRowAndTheBoxKeepsItsSize() {
        let one = layout(Array(sample.prefix(1)))
        #expect(one.eventRows.count == 1)
        #expect(one.eventRows[0].origin.y == 111)
        #expect(one.eventsBox == layout(sample).eventsBox)
    }

    /// Never more than three rows, however many events (task 205; was four).
    @Test func theBoxNeverShowsMoreThanThreeRows() {
        let many = labels(Array(repeating: "A very long event title that will be cut", count: 7))
        let layout = layout(many)
        #expect(layout.eventRows.count == 3)
        #expect(layout.eventRows.allSatisfy { $0.text.count == 29 && $0.text.hasSuffix("/") })
    }

    /// With no zip, the prompt takes the last row and two events stay
    /// (task 205; was three). The full prompt is cut at 29 characters, so
    /// the short one is drawn whole; VoiceOver still says the full one.
    @Test func thePromptAndTwoEventsAlwaysFit() {
        let layout = layout(sample, prompt: true)
        #expect(layout.eventRows.count == 3)
        #expect(layout.promptIndex == 2)
        #expect(layout.eventRows[2].text == "-- Set zip code in Settings /")
        #expect(layout.eventRows[2].spoken == nil)
        #expect(layout.eventRows[2].origin.y == 155)
        #expect(layout.eventRows.prefix(2).map(\.spoken) == sample.prefix(2).map(\.spoken))
    }

    /// The zip prompt is never cut mid-word: the full text where it fits
    /// (Pro Max), the short one elsewhere, on every screen.
    @Test func theZipPromptIsNeverCutMidWord() {
        let expected: [(CGSize, String)] = [
            (se, "- Set zip code in Settings/"),
            (iPhone16, "-- Set zip code in Settings /"),
            (iPhone17, "--- Set zip code in Settings /"),
            (proMax, "-- Set your zip code in Settings /"),
        ]
        for (size, text) in expected {
            let layout = layout([], prompt: true, size: size)
            #expect(layout.eventRows.map(\.text) == [text], "\(size)")
        }
        #expect(TodayOverlayLayout.zipPrompt(columns: 32) == TodayOverlayLayout.zipPromptText)
        #expect(TodayOverlayLayout.zipPrompt(columns: 31) == TodayOverlayLayout.shortZipPromptText)
    }

    /// A pasted link or a title written without spaces never runs past the
    /// box: wide characters are cut further, the row still ends in a slash.
    @Test func anUnbreakableTitleStaysInsideTheBox() {
        let titles = [
            "https://us02web.zoom.us/j/81234567890?pwd=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
            "東京都の天気予報と週間予報のお知らせ会議の資料を準備する",
            "Standup",
        ]
        for size in [iPhone16, se, proMax] {
            let layout = layout(labels(titles), size: size)
            let inner = layout.eventsBox.width - 2 * 1.4
            #expect(layout.eventRows.count == 3)
            for row in layout.eventRows {
                #expect(row.width <= inner + 0.5, "\(row.text): \(row.width) of \(inner)")
                #expect(row.text.hasSuffix("/"))
            }
            #expect(layout.eventRows[0].text.count == layout.eventColumns)
            #expect(layout.eventRows[1].text.count < layout.eventColumns)
        }
    }

    /// The same for article titles, measured as `HeadlinesColumn` measures them.
    /// At 12 points a 290-point line holds 37 characters (task 205; 42 at
    /// 10.5), so the mockup's first title breaks earlier than the still.
    @Test func anUnbreakableArticleTitleStaysInsideItsColumn() {
        let layout = layout([])
        let title = HUDType.title
        for text in ["https://example.com/a/very/long/path/that/never/has/a/space/in/it/at/all/index.html",
                     "気象庁は今週末にかけて広い範囲で大雨となる見込みだと発表しました"] {
            let lines = HeadlinesColumn.lines(text, width: layout.titleWidth)
            #expect(lines.count == 2)
            #expect(lines.allSatisfy { title.width($0) <= layout.titleWidth + 0.5 })
        }
        #expect(HeadlinesColumn.lines("A short explainer on quantum mechanics and its uses", width: layout.titleWidth)
            == ["A short explainer on quantum", "mechanics and its uses"])
        #expect(title.width(String(repeating: "0", count: 37)) <= layout.titleWidth)
        #expect(title.width(String(repeating: "0", count: 38)) > layout.titleWidth)
    }

    /// A 24-hour phone: the time in five, no letter, the dashes still line up.
    @Test func aTwentyFourHourPhoneShowsNoLetter() {
        let layout = layout(labels(["Hanna\u{2019}s Show", "Night Workout"], hours: [9, 20.25], clock: .twentyFourHour))
        #expect(layout.eventRows.map(\.text) == [
            "09:00   " + String(repeating: "-", count: 6) + " Hanna\u{2019}s Show /",
            "20:15   " + String(repeating: "-", count: 5) + " Night Workout /",
        ])
    }

    /// iPhone 16 Pro Max size: margins stay 34, the tiles and box stretch,
    /// the rows hold more characters, five titles fit.
    @Test func aLargeScreenScalesEverything() {
        let layout = layout(sample, size: proMax)
        #expect(abs(layout.horizonY - 386 * 440 / 393) < 0.001)
        #expect(layout.dateTile.minX == 34 && layout.eventsBox.maxX == 406)
        #expect(layout.tiles.last?.maxX == 406)
        #expect(layout.tiles.allSatisfy { abs($0.width - 88.5) < 0.001 && $0.minY == CGFloat(956 - 118) })
        #expect(layout.settingsRect.minX == CGFloat(440 - 58))
        #expect(layout.eventColumns == 34)
        #expect(layout.eventRows.allSatisfy { $0.text.count == 34 })
        #expect(layout.titleCapacity == 5)
        #expect(abs(layout.frame.maxY - (layout.horizonY + 40)) < 0.001)
        #expect(abs(layout.plate.minY - (layout.horizonY + 42)) < 0.001)
        #expect(layout.plate.maxY == CGFloat(956 - 7))
        #expect(layout.titleWidth == CGFloat(440 - 35 - 68))
        // The last title row ends above the tiles.
        #expect(layout.titleRowTop(4) + 38 <= layout.tiles[0].minY - 17)
    }

    /// Type does not scale: every screen uses the mockup's sizes, and the
    /// date tile's text fits its tile on each.
    @Test func typeDoesNotScaleAndTheWeekdayFitsTheDateTile() {
        #expect(HUDType.tileLabel.size == 12 && HUDType.tileFoot.size == 11 && HUDType.eventRow.size == 13)
        #expect(HUDType.eventRow.lineHeight == 22 && HUDType.title.size == 12 && HUDType.title.lineHeight == 19)
        for size in [se, iPhone16, iPhone17, proMax] {
            let tile = layout(size: size).dateTile
            let inner = tile.width - 2 * (1.4 + 7)
            for day in ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] {
                #expect(HUDType.tileLabel.width(day) < inner)
            }
        }
    }

    /// Every screen size: the rows' character count is the most that fits
    /// with half a character free each side, and the rows stay in the box.
    @Test func everyScreenGetsTheMostColumnsThatFit() {
        let expected: [(CGSize, Int)] = [(se, 27), (iPhone16, 29), (iPhone17, 30), (proMax, 34)]
        for (size, columns) in expected {
            let layout = layout(sample, size: size)
            #expect(layout.eventColumns == columns, "\(size)")
            let inner = layout.eventsBox.width - 2 * 1.4
            #expect(CGFloat(columns + 1) * style.cell <= inner + 0.01)
            #expect(CGFloat(columns + 2) * style.cell > inner)
            for row in layout.eventRows {
                #expect(row.text.count == columns)
                #expect(row.width <= inner - style.cell / 2)
            }
        }
    }

    /// The zip prompt alone sits in the first row.
    @Test func thePromptAloneSitsInTheBox() {
        let layout = layout([], prompt: true)
        #expect(layout.eventRows.count == 1)
        #expect(layout.promptIndex == 0)
        #expect(layout.eventRows[0].origin.y == 111)
        #expect(layout.eventRows[0].text == "-- Set zip code in Settings /")
    }

    /// An event on a later day shows its weekday in the time column and no
    /// letter; the columns still line up with today's rows.
    @Test func aLaterDayShowsItsWeekdayAndTheColumnsAlign() {
        let later = UpcomingEvent(
            link: UUID(), title: "Dentist", start: now.addingTimeInterval(2 * 86_400),
            end: now.addingTimeInterval(2 * 86_400 + 1800), allDay: false
        )
        let label = EventLabel(event: later, now: now, timeZone: zone, clock: .twelveHour)
        let layout = layout(Array(sample.prefix(1)) + [label])
        #expect(layout.eventRows[1].text == "  WED   " + String(repeating: "-", count: 11) + " Dentist /")
        #expect(layout.eventRows.map { $0.text.firstIndex(of: "-") } == layout.eventRows.map { _ in layout.eventRows[0].text.firstIndex(of: "-") })
    }

    /// Task 207: the pitch tightens only where it turns one row into two.
    @Test func thePitchTightensOnlyToFitASecondRow() {
        // Two or more rows fit at 54, or none does: 54.
        #expect(TodayOverlayLayout.titlePitch(fitting: 92) == 54)
        #expect(TodayOverlayLayout.titlePitch(fitting: 300) == 54)
        #expect(TodayOverlayLayout.titlePitch(fitting: 30) == 54)
        // One fits: the largest whole pitch that fits a second, 46 or more.
        #expect(TodayOverlayLayout.titlePitch(fitting: 88.68) == 50)
        #expect(TodayOverlayLayout.titleRows(fitting: 88.68, pitch: 50) == 2)
        #expect(TodayOverlayLayout.titlePitch(fitting: 84) == 46)
        #expect(TodayOverlayLayout.titleRows(fitting: 84, pitch: 46) == 2)
        // The largest tightened pitch is 53, just under the seam at 91.5.
        #expect(TodayOverlayLayout.titlePitch(fitting: 91) == 53)
        #expect(TodayOverlayLayout.titleRows(fitting: 91, pitch: 53) == 2)
        #expect(TodayOverlayLayout.titlePitch(fitting: 91.49) == 53)
        // At 91.5 two rows fit at 54 (with the half-point tolerance), so the
        // pitch stays 54.
        #expect(TodayOverlayLayout.titleRows(fitting: 91.5, pitch: 54) == 2)
        #expect(TodayOverlayLayout.titlePitch(fitting: 91.5) == 54)
        // Too little room for a second row even 8 apart: 54, one row.
        #expect(TodayOverlayLayout.titlePitch(fitting: 83.9) == 54)
        #expect(TodayOverlayLayout.titleRows(fitting: 83.9, pitch: 54) == 1)
    }

    /// Task 207: only the iPhone SE tightens. The other small sizes keep 54
    /// and the rows that fit at it (the #207 review's figures).
    @Test func theOtherSmallScreensKeepTheMockupPitch() {
        let expected: [(CGSize, Int)] = [
            (CGSize(width: 375, height: 812), 4),
            (CGSize(width: 390, height: 844), 4),
            (CGSize(width: 320, height: 568), 1),
        ]
        for (size, capacity) in expected {
            let layout = layout(size: size)
            #expect(layout.titlePitch == 54, "\(size)")
            #expect(layout.titleCapacity == capacity, "\(size)")
            // The last row ends clear of the tiles.
            #expect(layout.titleRowTop(capacity - 1) + 38 <= layout.tiles[0].minY - 17 + 0.5, "\(size)")
        }
    }

    /// iPhone SE size: the titles give way first, whole rows at a time; the
    /// top and the tiles keep their places. Task 205: at 12 points on a 54
    /// pitch one title fits (two did at 10.5 on 51). Task 207: so the pitch
    /// tightens to 50 there and two fit.
    @Test func aSmallScreenScalesEverything() {
        let layout = layout(sample, size: se)
        #expect(abs(layout.horizonY - 386 * 375 / 393) < 0.001)
        #expect(layout.tiles[0].minY == CGFloat(667 - 118))
        #expect(layout.titleCapacity == 2)
        #expect(layout.titlePitch == 50)
        #expect(layout.titleRowTop(1) == layout.titleRowTop(0) + 50)
        #expect(layout.titleRowTop(1) + 38 <= layout.tiles[0].minY - 17)
        #expect(layout.titleRowTop(0) + 54 + 38 > layout.tiles[0].minY - 17)
        #expect(layout.titleBand(0).maxY == layout.titleBand(1).minY && layout.titleBand(0).height == 50)
        #expect(self.layout(sample).titlePitch == 54 && self.layout(sample, size: iPhone17).titlePitch == 54)
        #expect(layout.eventsBox.minY == 105 && layout.markRect.minY == 66)
        // The frame still clears the date tile.
        #expect(layout.frame.minY > layout.dateTile.maxY)
        #expect(layout.frame.maxY < layout.plate.minY)
    }

    // MARK: Rim

    /// The rim's corners turn the short way: the path stays inside the
    /// screen and its top and bottom parts end at the gap.
    @Test func theRimFollowsTheCornersAndBreaksAtTheView() {
        for radius in [nil, 48] as [CGFloat?] {
            let layout = TodayOverlayLayout(size: iPhone16, labels: [], showsZipPrompt: false, cornerRadius: radius)
            let bounds = layout.rimPath.boundingRect
            #expect(abs(bounds.minX - 7) < 0.01 && abs(bounds.maxX - 386) < 0.01)
            #expect(abs(bounds.minY - 7) < 0.01 && abs(bounds.maxY - 845) < 0.01)
            #expect(layout.rimRadius == (radius ?? 39))
            // Nothing drawn along the sides in the gap.
            let gapMiddle = CGPoint(x: 7, y: (layout.rimGap.lowerBound + layout.rimGap.upperBound) / 2)
            #expect(!layout.rimPath.strokedPath(StrokeStyle(lineWidth: 1.4)).contains(gapMiddle))
            #expect(layout.rimPath.strokedPath(StrokeStyle(lineWidth: 1.4)).contains(CGPoint(x: 7, y: 150)))
        }
        // A radius of nothing reported is the mockup's.
        #expect(TodayOverlayLayout(size: iPhone16, labels: [], showsZipPrompt: false, cornerRadius: 0).rimRadius == 39)
    }

    /// The title bands meet, so a drop between two titles lands on one.
    @Test func theTitleBandsMeet() {
        let layout = layout()
        for index in 0..<4 {
            #expect(layout.titleBand(index).maxY == layout.titleBand(index + 1).minY)
        }
        #expect(layout.titleBand(0).minX == 32 && layout.titleBand(0).maxX == 358)
    }
}
