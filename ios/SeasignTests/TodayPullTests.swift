import CoreGraphics
import Testing

@testable import Seasign

/// The pulls on Today (tasks 150 and 151): which drags refresh, and what.
@Suite struct TodayPullTests {
    @Test func aLongDownwardDragIsAPull() {
        #expect(TodayPull.isPull(CGSize(width: 0, height: 100)))
        #expect(TodayPull.isPull(CGSize(width: 0, height: 300)))
        // A little sideways drift is fine.
        #expect(TodayPull.isPull(CGSize(width: -50, height: 100)))
        #expect(TodayPull.isPull(CGSize(width: 60, height: 160)))
    }

    @Test func shortSidewaysAndUpwardDragsAreNot() {
        #expect(!TodayPull.isPull(.zero))
        #expect(!TodayPull.isPull(CGSize(width: 0, height: 99)))
        #expect(!TodayPull.isPull(CGSize(width: 0, height: -200)))
        // More sideways than down.
        #expect(!TodayPull.isPull(CGSize(width: 120, height: 200)))
        #expect(!TodayPull.isPull(CGSize(width: -300, height: 120)))
    }

    /// A tap never reaches the drag: buttons and headlines keep their taps.
    @Test func theDragIsOnlyWatchedPastATapsWobble() {
        #expect(TodayPull.minimumDistance >= 10)
        #expect(TodayPull.minimumDistance < TodayPull.distance)
    }

    // MARK: Which pull (task 151)

    private let horizon: CGFloat = 386
    private let down = CGSize(width: 0, height: 150)

    /// Above the horizon (the header, the events box, the sky): the calendar
    /// and the sky. At or below it (the sea, the titles): the headlines.
    @Test func whereTheFingerWentDownPicksThePull() {
        for y: CGFloat in [0, 40, 80, 120, 300, 385.9] {
            #expect(TodayPull.target(start: CGPoint(x: 200, y: y), translation: down, horizonY: horizon) == .calendar, "\(y)")
        }
        for y: CGFloat in [386, 386.1, 486, 700, 852] {
            #expect(TodayPull.target(start: CGPoint(x: 200, y: y), translation: down, horizonY: horizon) == .headlines, "\(y)")
        }
    }

    /// The side of the screen does not matter, only the height.
    @Test func theStartsXDoesNotMatter() {
        for x: CGFloat in [0, 34, 360, 393] {
            #expect(TodayPull.target(start: CGPoint(x: x, y: 100), translation: down, horizonY: horizon) == .calendar)
            #expect(TodayPull.target(start: CGPoint(x: x, y: 600), translation: down, horizonY: horizon) == .headlines)
        }
    }

    /// A drag that is not a pull refreshes nothing, wherever it started.
    @Test func aDragThatIsNotAPullIsNeither() {
        for y: CGFloat in [100, 600] {
            let start = CGPoint(x: 200, y: y)
            #expect(TodayPull.target(start: start, translation: .zero, horizonY: horizon) == nil)
            #expect(TodayPull.target(start: start, translation: CGSize(width: 0, height: 99), horizonY: horizon) == nil)
            #expect(TodayPull.target(start: start, translation: CGSize(width: 0, height: -200), horizonY: horizon) == nil)
            #expect(TodayPull.target(start: start, translation: CGSize(width: 150, height: 200), horizonY: horizon) == nil)
        }
    }

    /// On a real screen the line is the scene's horizon.
    @Test func theLineIsTheScenesHorizon() {
        let size = CGSize(width: 440, height: 956)
        let horizonY = SceneLayout(size: size).horizonY
        #expect(abs(horizonY - 386 * 440 / 393) < 0.01)
        #expect(TodayPull.target(start: CGPoint(x: 220, y: horizonY - 1), translation: down, horizonY: horizonY) == .calendar)
        #expect(TodayPull.target(start: CGPoint(x: 220, y: horizonY), translation: down, horizonY: horizonY) == .headlines)
    }

    @Test func voiceOverHasTwoActions() {
        #expect(TodayPull.calendarActionName == "Refresh calendar and weather")
        #expect(TodayPull.headlinesActionName == "Refresh headlines")
    }

    // MARK: Spinners

    @Test func theSpinnersShareAColumnAtTheBoxsRightPadding() {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 440, height: 956), CGSize(width: 375, height: 667)] {
            let layout = TodayOverlayLayout(size: size, labels: [], showsZipPrompt: false)
            let calendar = layout.calendarSpinnerCenter
            let headlines = layout.headlineSpinnerCenter
            let half = TodayOverlayLayout.spinnerSide / 2
            #expect(calendar.x == headlines.x)
            // Inside the events box's border at its right (design v12).
            #expect(abs(calendar.x + half - (layout.eventsBox.maxX - 1.4)) < 0.01)
            #expect(abs(calendar.x + half - (size.width - 34 - 1.4)) < 0.01)
            // Level with the first event row and the first title line.
            // Task 205: three 22-point rows centred in the box (4.6 under
            // the border) and 19-point title lines.
            #expect(abs(calendar.y - (105 + 1.4 + 4.6 + 22 / 2)) < 0.01)
            #expect(abs(headlines.y - (layout.titleRowTop(0) + 19 / 2)) < 0.01)
            // The calendar one in the sky, the headline one in the sea.
            let horizonY = SceneLayout(size: size).horizonY
            #expect(calendar.y + half < horizonY)
            #expect(headlines.y - half > horizonY)
        }
    }
}
