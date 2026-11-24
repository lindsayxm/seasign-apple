import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Seasign

/// The v12 events box rows (task 193): `eventRow()` in
/// `design-ideas/v12-imago/index.html`, and the plan's defaults.
@Suite struct EventRowTextTests {
    private func dashes(_ count: Int) -> String { String(repeating: "-", count: count) }

    @Test func aFullRowFillsWithDashes() {
        #expect(EventRowText.row(time: "11:00", letter: "A", title: "Hanna\u{2019}s Show", columns: 34)
            == "11:00 A " + dashes(11) + " Hanna\u{2019}s Show /")
        #expect(EventRowText.row(time: "8:15", letter: "P", title: "Night Workout", columns: 34)
            == " 8:15 P " + dashes(10) + " Night Workout /")
        // At least one dash: the longest title that is not cut.
        let longest = String(repeating: "x", count: 22)
        #expect(EventRowText.row(time: "8:15", letter: "P", title: longest, columns: 34) == " 8:15 P - " + longest + " /")
    }

    @Test func aTitleTooLongIsCutAndEndsInTheSlash() {
        #expect(EventRowText.row(time: "1:00", letter: "P", title: "Wearables and sensing demo", columns: 34)
            == " 1:00 P - Wearables and sensing d/")
        #expect(EventRowText.row(time: "6:45", letter: "P", title: "Submit hours for studio payroll", columns: 34)
            == " 6:45 P - Submit hours for studio/")
        // One character over the longest whole title.
        let over = String(repeating: "x", count: 23)
        #expect(EventRowText.row(time: "8:15", letter: "P", title: over, columns: 34) == " 8:15 P - " + String(repeating: "x", count: 23) + "/")
        #expect(EventRowText.row(time: "8:15", letter: "P", title: over + "yz", columns: 34).count == 34)
    }

    /// A cut that would end in a space ends at the word before it; the
    /// row keeps its width with one more dash in front.
    @Test func aCutNeverEndsInASpace() {
        #expect(EventRowText.row(time: "6:45", letter: "P", title: "Submit hours for studio payroll", columns: 35)
            == " 6:45 P -- Submit hours for studio/")
        #expect(EventRowText.row(time: "6:45", letter: "P", title: "Submit hours for studio payroll", columns: 35).count == 35)
    }

    @Test func allDayShowsAllAndNoLetter() {
        #expect(EventRowText.row(time: "ALL", letter: nil, title: "Market", columns: 34)
            == "  ALL   " + dashes(17) + " Market /")
    }

    @Test func anotherDayShowsTheWeekdayAndNoLetter() {
        #expect(EventRowText.row(time: "TUE", letter: nil, title: "Dentist", columns: 34)
            == "  TUE   " + dashes(16) + " Dentist /")
    }

    @Test func otherWidths() {
        for columns in [12, 20, 32, 35, 39, 41, 60] {
            let whole = EventRowText.row(time: "11:00", letter: "A", title: "Hanna\u{2019}s Show", columns: columns)
            #expect(whole.count == columns, "\(columns): \(whole)")
            #expect(whole.hasSuffix("/"))
            #expect(whole.hasPrefix("11:00 A "))
        }
        #expect(EventRowText.row(time: "11:00", letter: "A", title: "Hanna\u{2019}s Show", columns: 35)
            == "11:00 A " + dashes(12) + " Hanna\u{2019}s Show /")
        #expect(EventRowText.row(time: "1:00", letter: "P", title: "Wearables and sensing demo", columns: 32)
            == " 1:00 P - Wearables and sensing/")
        // Below the minimum the row is written at the minimum.
        #expect(EventRowText.row(time: "1:00", letter: "P", title: "Lunch", columns: 3).count == EventRowText.minimumColumns)
    }

    @Test func whiteSpaceInTheTitleIsOneSpace() {
        #expect(EventRowText.row(time: "9:00", letter: "A", title: "  Stand\tup\nmeeting ", columns: 34)
            == " 9:00 A " + dashes(7) + " Stand up meeting /")
    }

    @Test func theZipPromptIsWrittenLikeARow() {
        #expect(EventRowText.message("Set your zip code in Settings", columns: 34) == "-- Set your zip code in Settings /")
        #expect(EventRowText.message("Set your zip code in Settings", columns: 32) == "- Set your zip code in Settings/")
    }

    /// Each CJK character or emoji two cells wide, as a fallback font draws it.
    private let cells: (String) -> CGFloat = { text in
        CGFloat(text.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) })
    }

    @Test func wideCharactersAreCutToTheMeasuredWidth() {
        let title = "東京都の天気予報と週間予報のお知らせ会議"
        let row = EventRowText.row(time: "9:00", letter: "A", title: title, columns: 34, maxWidth: 34, measure: cells)
        #expect(cells(row) <= 34)
        #expect(row == " 9:00 A -- 東京都の天気予報と週間/")
    }

    /// A short title in wide characters is never cut while dashes remain:
    /// the dashes give way first.
    @Test func aShortWideTitleGivesUpDashesNotCharacters() {
        let cjk = EventRowText.row(time: "9:00", letter: "A", title: "会議資料", columns: 34, maxWidth: 34, measure: cells)
        #expect(cjk == " 9:00 A " + dashes(15) + " 会議資料 /")
        #expect(cells(cjk) == 34)
        let emoji = EventRowText.row(time: "9:00", letter: "A", title: "🎉🎂", columns: 34, maxWidth: 34, measure: cells)
        #expect(emoji == " 9:00 A " + dashes(19) + " 🎉🎂 /")
        // One wide character among narrow ones: one dash fewer.
        let mixed = EventRowText.row(time: "9:00", letter: "A", title: "Café 🍵", columns: 34, maxWidth: 34, measure: cells)
        #expect(mixed == " 9:00 A " + dashes(16) + " Café 🍵 /")
        // A wide title that fits whole only with one dash keeps it whole.
        let exact = String(repeating: "会", count: 11)
        let one = EventRowText.row(time: "9:00", letter: "A", title: exact, columns: 34, maxWidth: 34, measure: cells)
        #expect(one == " 9:00 A - " + exact + " /")
        // The zip prompt in a wide language gives up dashes the same way.
        #expect(EventRowText.message("郵便番号を設定", columns: 34, maxWidth: 34, measure: cells)
            == dashes(17) + " 郵便番号を設定 /")
    }

    @Test func columnsFromWidth() {
        #expect(EventRowText.columns(width: 34 * 6.8, cell: 6.8) == 34)
        #expect(EventRowText.columns(width: 34 * 6.8 - 0.5, cell: 6.8) == 33)
        #expect(EventRowText.columns(width: 0, cell: 6.8) == EventRowText.minimumColumns)
        #expect(EventRowText.columns(width: 200, cell: 0) == EventRowText.minimumColumns)
    }

    /// What VoiceOver says is the plain event, never the dashes.
    @Test func theSpokenLabelIsThePlainEvent() {
        let zone = TimeZone(identifier: "America/New_York")!
        let start = Date(timeIntervalSince1970: 1_794_846_960 + 3600)
        let label = EventLabel(
            event: UpcomingEvent(link: UUID(), title: "Night Workout", start: start, end: start, allDay: false),
            now: Date(timeIntervalSince1970: 1_794_846_960), timeZone: zone, clock: .twelveHour
        )
        let layout = TodayOverlayLayout(size: CGSize(width: 393, height: 852), labels: [label], showsZipPrompt: false)
        #expect(layout.eventRows[0].spoken == label.spoken)
        #expect(label.spoken == "Night Workout, 12:36 PM")
        #expect(!label.spoken.contains("-"))
    }
}

/// The star dragged from SAVE onto a title (task 193).
@Suite struct StarDropTests {
    private let layout = TodayOverlayLayout(size: CGSize(width: 393, height: 852), labels: [], showsZipPrompt: false)
    private var bands: [CGRect] { (0..<5).map { layout.titleBand($0) } }

    @Test func aDropOnATitleSavesIt() {
        // On the second title's first line.
        let point = CGPoint(x: 120, y: layout.titleRowTop(1) + 8)
        #expect(StarDrop.outcome(at: point, bands: bands) { _ in false } == .save(1))
        // Between two titles: the nearer one.
        let between = CGPoint(x: 200, y: layout.titleRowTop(2) - 3)
        #expect(StarDrop.row(at: between, bands: bands) == 2)
        let justAbove = CGPoint(x: 200, y: layout.titleRowTop(1) + 34 + 5)
        #expect(StarDrop.row(at: justAbove, bands: bands) == 1)
    }

    @Test func aDropElsewhereDoesNothing() {
        for point in [CGPoint(x: 200, y: 300), CGPoint(x: 200, y: 780), CGPoint(x: 5, y: layout.titleRowTop(0) + 8),
                      CGPoint(x: 380, y: layout.titleRowTop(0) + 8)] {
            #expect(StarDrop.outcome(at: point, bands: bands) { _ in false } == StarDrop.Outcome.none, "\(point)")
        }
        // Only shown titles count: with two titles, the third row is empty.
        let third = CGPoint(x: 120, y: layout.titleRowTop(2) + 8)
        #expect(StarDrop.row(at: third, bands: Array(bands.prefix(2))) == nil)
    }

    @Test func aSavedTitleIsNeverRemovedByADrop() {
        let point = CGPoint(x: 120, y: layout.titleRowTop(0) + 8)
        #expect(StarDrop.outcome(at: point, bands: bands) { $0 == 0 } == .alreadySaved(0))
    }

    @Test func theStarRidesAboveTheFinger() {
        let finger = CGPoint(x: 240, y: 760)
        #expect(StarDrop.star(finger: finger) == CGPoint(x: 240, y: 760 - StarDrop.lift))
        #expect(StarDrop.lift > 20)
    }

    /// However the drag ends, the star goes back; only a lift over a title
    /// saves it.
    @Test func theStarNeverStaysOut() {
        var flight = StarFlight()
        #expect(!flight.isFlying)
        let over = CGPoint(x: 120, y: layout.titleRowTop(1) + 8 + StarDrop.lift)
        flight.move(finger: over)
        #expect(flight.isFlying)
        #expect(flight.row(bands: bands) == 1)
        // Cancelled (an alert, the app leaving, a cover opening).
        flight.cancel()
        #expect(!flight.isFlying && flight.row(bands: bands) == nil)
        // Lifted over a title: saved, and the star is back.
        flight.move(finger: over)
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == .save(1))
        #expect(!flight.isFlying)
        // Lifted elsewhere: nothing, and the star is back.
        flight.move(finger: CGPoint(x: 200, y: 300))
        #expect(flight.land(finger: CGPoint(x: 200, y: 300), bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        #expect(!flight.isFlying)
    }

    /// Today showing, nothing over it, the app active.
    private var onToday: TodayActivity {
        TodayActivity(tab: .day, coverOpen: false, appActive: true)
    }

    /// A landing saves only when a drag is under way and Today is the page
    /// showing with nothing over it (task 195, from the task 194 review):
    /// a lift with no drag (none started, or one already cancelled), or on
    /// another page or under a cover, saves nothing and leaves the star in
    /// its tile.
    @Test func aLandingWithNoDragOrOffTodaySavesNothing() {
        let over = CGPoint(x: 120, y: layout.titleRowTop(1) + 8 + StarDrop.lift)
        var flight = StarFlight()
        // No drag started.
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        #expect(!flight.isFlying)
        // A drag already cancelled.
        flight.move(finger: over)
        flight.cancel()
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        #expect(!flight.isFlying)
        // A drag under way, but another page is showing, or a cover is up.
        for tab in HUDTileBar.Tile.allCases where tab != .day {
            flight.move(finger: over)
            let elsewhere = TodayActivity(tab: tab, coverOpen: false, appActive: true)
            #expect(flight.land(finger: over, bands: bands, activity: elsewhere) { _ in false } == StarDrop.Outcome.none, "\(tab)")
            #expect(!flight.isFlying)
        }
        flight.move(finger: over)
        let covered = TodayActivity(tab: .day, coverOpen: true, appActive: true)
        #expect(flight.land(finger: over, bands: bands, activity: covered) { _ in false } == StarDrop.Outcome.none)
        #expect(!flight.isFlying)
        // The same drop with a drag under way on Today saves the title.
        flight.move(finger: over)
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == .save(1))
    }

    /// Task 198: a real drop saves whichever SwiftUI reports first, the
    /// gesture's end or its state going back; a drag the system cancelled
    /// (the reset alone) saves nothing, and the next drag is a normal one.
    @Test func aDropSavesInEitherOrderOfEndAndReset() {
        let over = CGPoint(x: 120, y: layout.titleRowTop(1) + 8 + StarDrop.lift)
        // The end first, then the reset.
        var flight = StarFlight()
        flight.move(finger: over)
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == .save(1))
        flight.gestureReset()
        #expect(!flight.isFlying)
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        // The reset first, then the end: the star is back at once, and the
        // drop still saves, once.
        flight.move(finger: over)
        flight.gestureReset()
        #expect(!flight.isFlying && flight.row(bands: bands) == nil)
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == .save(1))
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        // Reset first, then the end off Today (a cover opened): nothing.
        flight.move(finger: over)
        flight.gestureReset()
        let covered = TodayActivity(tab: .day, coverOpen: true, appActive: true)
        #expect(flight.land(finger: over, bands: bands, activity: covered) { _ in false } == StarDrop.Outcome.none)
    }

    @Test func aResetAloneOrAfterTodayCancelledSavesNothing() {
        let over = CGPoint(x: 120, y: layout.titleRowTop(1) + 8 + StarDrop.lift)
        var flight = StarFlight()
        // A reset with nothing out stays idle: a later stray end saves nothing.
        flight.gestureReset()
        #expect(!flight.isFlying)
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        // Today cancelled (a cover, another page, the app left), then the
        // reset and a late end: nothing.
        flight.move(finger: over)
        flight.cancel()
        flight.gestureReset()
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        // The reset, then Today cancelled, then the end: nothing.
        flight.move(finger: over)
        flight.gestureReset()
        flight.cancel()
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        // The system took the touch (a reset, no end); the next drag starts
        // afresh and its drop elsewhere saves nothing, its drop on a title saves.
        flight.move(finger: over)
        flight.gestureReset()
        flight.move(finger: CGPoint(x: 200, y: 300))
        #expect(flight.isFlying)
        #expect(flight.land(finger: CGPoint(x: 200, y: 300), bands: bands, activity: onToday) { _ in false } == StarDrop.Outcome.none)
        flight.move(finger: over)
        #expect(flight.land(finger: over, bands: bands, activity: onToday) { _ in false } == .save(1))
    }

    /// Task 207: on the iPhone SE the two rows are 50 apart; their bands
    /// meet halfway between the rows, a drop on either saves it, and nothing
    /// lies under the second.
    @Test func theBandsFollowTheTighterPitchOnTheSE() {
        let se = TodayOverlayLayout(size: CGSize(width: 375, height: 667), labels: [], showsZipPrompt: false)
        #expect(se.titleCapacity == 2 && se.titlePitch == 50)
        let bands = (0..<se.titleCapacity).map { se.titleBand($0) }
        #expect(bands.allSatisfy { $0.height == 50 })
        #expect(bands[0].maxY == bands[1].minY)
        // Halfway through the 12-point gap between the rows.
        #expect(bands[0].maxY == se.titleRowTop(1) - 6)
        #expect(StarDrop.outcome(at: CGPoint(x: 120, y: se.titleRowTop(1) + 8), bands: bands) { _ in false } == .save(1))
        #expect(StarDrop.row(at: CGPoint(x: 120, y: se.titleRowTop(1) - 5), bands: bands) == 1)
        #expect(StarDrop.row(at: CGPoint(x: 120, y: se.titleRowTop(1) - 7), bands: bands) == 0)
        #expect(StarDrop.row(at: CGPoint(x: 120, y: se.titleRowTop(0) + 8), bands: bands) == 0)
        // Below the second row's band: no title, and the band stays clear of
        // the tiles.
        #expect(StarDrop.row(at: CGPoint(x: 120, y: bands[1].maxY + 1), bands: bands) == nil)
        #expect(bands[1].maxY <= se.tiles[0].minY)
    }

    /// A tap on the tile is not a drag, and the drag starts before Today's
    /// pull would watch it.
    @Test func aTapIsNotADrag() {
        #expect(StarDrop.minimumDistance >= 5)
        #expect(StarDrop.minimumDistance < TodayPull.minimumDistance)
        // An upward drag from the tiles to a title is never a pull.
        #expect(!TodayPull.isPull(CGSize(width: 0, height: -250)))
    }
}

/// The words inside the frame's corners and the top row (task 193).
@Suite struct FrameTextTests {
    @Test func weatherIsTemperatureOverWind() throws {
        var state = try midday()
        state.temperatureF = 54.6
        state.windMph = 8.2
        let text = FrameText.weather(state)
        #expect(text.lines == ["55°F", "wind 8/"])
        #expect(text.spoken == "55 degrees Fahrenheit, wind 8 miles per hour")
        state.temperatureF = nil
        state.windMph = nil
        #expect(FrameText.weather(state).lines.isEmpty && FrameText.weather(state).spoken == nil)
    }

    @Test func spanIsHowLongTheBodyIsUp() throws {
        var state = try midday()
        let rise = Date(timeIntervalSince1970: 1_800_000_000)
        state.sunPass = SkyPass(rise: rise, set: rise.addingTimeInterval(9 * 3600 + 50 * 60))
        state.isLive = true
        #expect(state.body?.kind == .sun)
        let text = FrameText.span(state)
        #expect(text.lines == ["Daylight", "9h 50m/"])
        #expect(text.spoken == "Daylight, 9 hours 50 minutes")
        state.sunPass = SkyPass(rise: rise, set: rise.addingTimeInterval(10 * 3600 + 5 * 60))
        #expect(FrameText.span(state).lines.last == "10h 05m/")
        state.sunPass = SkyPass(rise: rise, set: nil)
        #expect(FrameText.span(state).lines.isEmpty)
        state.isLive = false
        #expect(FrameText.span(state).spoken == nil)
    }

    private func midday() throws -> SceneState {
        let zone = try #require(TimeZone(identifier: "America/Chicago"))
        let now = Date(timeIntervalSince1970: 1_794_846_960)
        return SceneState.make(snapshot: nil, now: now, deviceTimeZone: zone)
    }
}

/// The v12 line drawings stay inside their viewBox (task 193).
@Suite struct HUDGlyphTests {
    @Test func everyGlyphFitsItsViewBox() {
        for glyph in HUDGlyph.allCases {
            let box = CGRect(origin: .zero, size: glyph.viewBox)
            for stroke in glyph.strokes {
                let bounds = stroke.path.boundingRect
                #expect(box.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(glyph): \(bounds)")
            }
        }
    }

    /// The S of the mark bulges left above the middle line and right below.
    @Test func theMarksSCurvesTheRightWay() {
        let inside = HUDGlyph.mark.strokes[1].path.boundingRect
        #expect(abs(inside.minX - 1) < 0.01 && abs(inside.maxX - 27) < 0.01)
        let stroked = HUDGlyph.mark.strokes[1].path.strokedPath(StrokeStyle(lineWidth: 1.5))
        #expect(stroked.contains(CGPoint(x: 7.5, y: 7.5)))
        #expect(stroked.contains(CGPoint(x: 20.5, y: 20.5)))
        #expect(!stroked.contains(CGPoint(x: 20.5, y: 7.5)))
        #expect(!stroked.contains(CGPoint(x: 7.5, y: 20.5)))
    }

    /// LIST's two arcs bulge outward, each a short arc over its chord.
    @Test func theListArcsBulgeOut() {
        let bounds = HUDGlyph.list.strokes[0].path.boundingRect
        #expect(bounds.minX > 1.5 && bounds.minX < 2.5, "\(bounds)")
        #expect(bounds.maxX > 19.5 && bounds.maxX < 20.5, "\(bounds)")
    }

    @Test func theFourTilesAreInOrder() {
        #expect(HUDTileBar.Tile.allCases.map(\.label) == ["Day", "List", "Save", "Listen"])
        #expect(HUDTileBar.Tile.allCases.map(\.spoken) == ["Today", "Do and get lists", "Saved", "Listen"])
    }
}
