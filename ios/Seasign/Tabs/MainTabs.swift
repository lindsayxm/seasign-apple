import Observation
import SwiftUI

/// Which of the four main pages is showing (design v12): DAY (Today), LIST
/// (Do / Get), SAVE (Saved) and LISTEN. The four tiles at the bottom of those
/// pages switch between them in place; the filled tile is the page showing
/// (`plans/2026-11-23-v12-in-the-app.md`, task 194).
///
/// Today is never torn down by a switch (`MainTabsView` keeps it mounted);
/// what it runs while another page shows is read from `today(coverOpen:appActive:)`.
@MainActor
@Observable
final class MainTabs {
    typealias Tile = HUDTileBar.Tile

    /// The page showing; its tile is the filled one.
    private(set) var showing: Tile
    /// A switch away from Saved that is waiting because Saved's notes could
    /// not be written; nil when nothing is waiting.
    private(set) var heldBack: Tile?

    init(showing: Tile = .day) {
        self.showing = showing
    }

    /// Shows `tile`'s page. Leaving Saved writes its notes first
    /// (`writeSavedNotes`, which says whether they were written); when they
    /// could not be, the switch waits in `heldBack` and this returns false,
    /// so the user can try again or leave anyway (the notes stay in memory).
    @discardableResult
    func select(_ tile: Tile, writeSavedNotes: () -> Bool = { true }) -> Bool {
        heldBack = nil
        guard tile != showing else { return true }
        if showing == .save, !writeSavedNotes() {
            heldBack = tile
            return false
        }
        showing = tile
        return true
    }

    /// Goes on to the page held back, notes written or not.
    func leaveAnyway() {
        guard let tile = heldBack else { return }
        heldBack = nil
        showing = tile
    }

    /// Stays on Saved; the switch held back is dropped.
    func stay() {
        heldBack = nil
    }

    /// What Today runs now, with a cover (Settings, the day screen, the
    /// read view) open over it or not and the app active or not.
    func today(coverOpen: Bool, appActive: Bool) -> TodayActivity {
        TodayActivity(tab: showing, coverOpen: coverOpen, appActive: appActive)
    }
}

/// What Today runs, given the page showing and what covers it. The one gate
/// `TodayView` reads for its scene, clock, refresh loop, Google poll and
/// touches, so that switching to another page pauses them and coming back
/// resumes them, without Today being rebuilt.
struct TodayActivity: Equatable {
    var tab: HUDTileBar.Tile
    var coverOpen: Bool
    var appActive: Bool

    /// Today is the page showing (a cover may still be over it).
    var isShowing: Bool { tab == .day }

    /// Today is the page showing and nothing covers it.
    var isOnScreen: Bool { isShowing && !coverOpen }

    /// The scene's animation and the 20-second clock run. Under a cover the
    /// system already stops drawing Today (it takes it off screen), as it did
    /// before tabs; on another page it is paused here.
    var animates: Bool { isShowing }

    /// The minute loop that refreshes the sky and the pasted-link events.
    /// It keeps running under a cover, as before tabs (the day screen reads
    /// those events), and stops on another page.
    var refreshLoopRuns: Bool { isShowing }

    /// Today takes taps and pulls (pull to refresh, the star's drag).
    var takesTouches: Bool { isShowing }

    /// Whether Today polls Google (`GooglePoll.isOn`): only while it is on
    /// screen, the app is active and Google can be polled.
    func pollsGoogle(canPoll: Bool) -> Bool {
        GooglePoll.isOn(appActive: appActive, todayOnScreen: isOnScreen, canPoll: canPoll)
    }
}

/// Today's clock (`TodayView`): an entry every `interval` seconds from the
/// start, so the sun and moon creep along their arcs; paused, only the first
/// entry, so a Today hidden behind another page is not redrawn.
struct TodayClockSchedule: TimelineSchedule {
    var interval: TimeInterval = 20
    var paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, interval: interval, paused: paused)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let interval: TimeInterval
        let paused: Bool

        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            upcoming = paused ? nil : date.addingTimeInterval(interval)
            return date
        }
    }
}
