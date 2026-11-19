import CoreGraphics
import Testing

@testable import Seasign

/// The pull on Today (task 150): which drags refresh.
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
}
