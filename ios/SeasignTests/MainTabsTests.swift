import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Seasign

/// The four main pages and their tiles (task 194): each tile switches the
/// page in place and is the filled one on its page; Today pauses while
/// another page shows and resumes on return; the bar never moves.
@MainActor
@Suite struct MainTabsTests {
    typealias Tile = HUDTileBar.Tile

    @Test func theAppStartsOnTodayWithDayFilled() {
        let tabs = MainTabs()
        #expect(tabs.showing == .day)
        #expect(tabs.heldBack == nil)
    }

    @Test func eachTileShowsItsPageAndIsTheFilledOne() {
        let tabs = MainTabs()
        // Every page from every page, Today included.
        for from in Tile.allCases {
            for to in Tile.allCases {
                tabs.select(from)
                #expect(tabs.select(to))
                #expect(tabs.showing == to)
                #expect(tabs.heldBack == nil)
            }
        }
    }

    @Test func theTileOfThePageShowingChangesNothing() {
        let tabs = MainTabs(showing: .save)
        var asked = 0
        #expect(tabs.select(.save) { asked += 1; return false })
        #expect(tabs.showing == .save)
        #expect(asked == 0)
    }

    @Test func leavingSavedWritesItsNotesFirst() {
        let tabs = MainTabs(showing: .save)
        var asked = 0
        #expect(tabs.select(.list) { asked += 1; return true })
        #expect(asked == 1)
        #expect(tabs.showing == .list)
        // Only Saved has notes to write.
        #expect(tabs.select(.listen) { asked += 1; return false })
        #expect(asked == 1)
        #expect(tabs.showing == .listen)
    }

    @Test func notesThatCannotBeWrittenHoldTheSwitchUntilTheUserChooses() {
        let tabs = MainTabs(showing: .save)
        #expect(!tabs.select(.day) { false })
        #expect(tabs.showing == .save)
        #expect(tabs.heldBack == .day)

        // Stay: the switch is dropped.
        tabs.stay()
        #expect(tabs.showing == .save)
        #expect(tabs.heldBack == nil)

        // Leave anyway: on to the page asked for.
        #expect(!tabs.select(.listen) { false })
        tabs.leaveAnyway()
        #expect(tabs.showing == .listen)
        #expect(tabs.heldBack == nil)

        // Nothing held back: nothing happens.
        tabs.leaveAnyway()
        #expect(tabs.showing == .listen)
    }

    /// Everything Today runs pauses on another page and resumes on Today,
    /// through the same gate `TodayView` reads.
    @Test func todayPausesOnAnotherPageAndResumesOnReturn() {
        let tabs = MainTabs()
        let live = tabs.today(coverOpen: false, appActive: true)
        #expect(live.animates)
        #expect(live.refreshLoopRuns)
        #expect(live.takesTouches)
        #expect(live.pollsGoogle(canPoll: true))

        for other in [Tile.list, .save, .listen] {
            tabs.select(other)
            let hidden = tabs.today(coverOpen: false, appActive: true)
            #expect(!hidden.isShowing)
            #expect(!hidden.animates)
            #expect(!hidden.refreshLoopRuns)
            #expect(!hidden.takesTouches)
            #expect(!hidden.pollsGoogle(canPoll: true))

            tabs.select(.day)
            #expect(tabs.today(coverOpen: false, appActive: true) == live)
        }
    }

    /// A cover over Today keeps what it did before tabs: the Google poll
    /// stops, the minute loop goes on, and the system stops the drawing.
    @Test func aCoverOverTodayStopsOnlyTheGooglePoll() {
        let tabs = MainTabs()
        let covered = tabs.today(coverOpen: true, appActive: true)
        #expect(covered.isShowing)
        #expect(!covered.isOnScreen)
        #expect(!covered.pollsGoogle(canPoll: true))
        #expect(covered.refreshLoopRuns)
        #expect(covered.animates)

        // In the background, or with nothing to poll, Google is not asked.
        #expect(!tabs.today(coverOpen: false, appActive: false).pollsGoogle(canPoll: true))
        #expect(!tabs.today(coverOpen: false, appActive: true).pollsGoogle(canPoll: false))
    }

    @Test func theClockTicksEveryTwentySecondsAndStopsWhenPaused() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let running = Array(TodayClockSchedule(paused: false).entries(from: start, mode: .normal).prefix(3))
        #expect(running == [start, start.addingTimeInterval(20), start.addingTimeInterval(40)])

        // Paused: one entry, where it stopped, and nothing after it.
        let paused = Array(TodayClockSchedule(paused: true).entries(from: start, mode: .normal).prefix(3))
        #expect(paused == [start])
    }

    /// The bar sits at one place on every page and every screen: 34 in from
    /// each side, its top 118 above the bottom, as Today's tiles.
    @Test func theTileBarIsAtTheSamePlaceOnEveryPage() {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 402, height: 874),
                     CGSize(width: 375, height: 667), CGSize(width: 440, height: 956)] {
            let bar = TodayOverlayLayout.tileBar(screen: size)
            #expect(bar.minX == 34)
            #expect(bar.maxX == size.width - 34)
            #expect(bar.minY == size.height - 118)
            #expect(bar.height == 78)
            // Today's four tiles fill exactly that bar.
            let layout = TodayOverlayLayout(size: size, labels: [], showsZipPrompt: false)
            let tiles = layout.tiles.dropFirst().reduce(layout.tiles[0]) { $0.union($1) }
            #expect(abs(tiles.minX - bar.minX) < 0.001)
            #expect(abs(tiles.maxX - bar.maxX) < 0.001)
            #expect(tiles.minY == bar.minY)
            #expect(tiles.height == bar.height)
        }
    }

    @Test func pagesLeaveRoomForTheTilesExceptUnderTheKeyboard() {
        // iPhone 17: home indicator 34; the last row stops 12 above the tiles.
        #expect(MainTabsView.roomForTiles(bottomInset: 34) == CGFloat(118 + 12 - 34))
        // iPhone SE: no home indicator.
        #expect(MainTabsView.roomForTiles(bottomInset: 0) == 130)
        // The keyboard covers the tiles: no extra room.
        #expect(MainTabsView.roomForTiles(bottomInset: 336) == 0)
    }

    @Test func eachTileSaysItsPage() {
        #expect(Tile.allCases == [.day, .list, .save, .listen])
        #expect(Tile.allCases.map(\.spoken) == ["Today", "Do and get lists", "Saved", "Listen"])
    }
}
