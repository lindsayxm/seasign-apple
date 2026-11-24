import CoreGraphics

/// Dragging the star from the SAVE tile onto an article title saves that
/// title (design v12, `plans/2026-11-23-v12-in-the-app.md`). Pure: where the
/// star is, and what letting go there does, from the title rows' bands
/// (`TodayOverlayLayout.titleBand`). A tap on the tile is not a drag (the
/// gesture's minimum distance), so it switches to Saved instead.
///
/// VoiceOver keeps drags for itself, so each title also offers a "Save"
/// action that does the same as a drop.
enum StarDrop {
    /// A drag shorter than this is a tap.
    static let minimumDistance: CGFloat = 8

    /// The star is drawn this far above the finger, so the finger does not
    /// hide it; it is the star, not the finger, that lands on a title.
    static let lift: CGFloat = 28

    /// Where the star is for a finger at `finger`.
    static func star(finger: CGPoint) -> CGPoint {
        CGPoint(x: finger.x, y: finger.y - lift)
    }

    /// What letting go of the star leads to.
    enum Outcome: Equatable {
        /// Not over a title: nothing happens.
        case none
        /// Over title `index`, which is not saved yet: save it.
        case save(Int)
        /// Over title `index`, which is already saved: nothing changes
        /// (a drop never removes a saved title).
        case alreadySaved(Int)
    }

    /// The row under `point`, if any: the first band that contains it.
    static func row(at point: CGPoint, bands: [CGRect]) -> Int? {
        bands.firstIndex { $0.contains(point) }
    }

    /// What a drop at `point` does. `isSaved` says whether row `index`'s
    /// title is saved already.
    static func outcome(at point: CGPoint, bands: [CGRect], isSaved: (Int) -> Bool) -> Outcome {
        guard let index = row(at: point, bands: bands) else { return .none }
        return isSaved(index) ? .alreadySaved(index) : .save(index)
    }
}

/// The star while it is out of the SAVE tile: where it is, and every way the
/// drag can end. Today keeps one of these; a drag that is cancelled (an
/// alert, the app leaving the foreground, a cover opening, the system taking
/// the touch) puts the star back, so it and the row outline never stay up.
///
/// The drag's end reaches it twice: `land` (the gesture's `onEnded`) and
/// `gestureReset` (its `@GestureState` going back, which also comes when the
/// system cancels the drag and then alone). SwiftUI does not document their
/// order, so either order saves a real drop (task 198): the reset puts the
/// star back but leaves the drag's one landing pending until the next drag
/// moves or Today cancels.
struct StarFlight: Equatable {
    /// Where the star is drawn; nil when it is in its tile.
    private(set) var star: CGPoint?
    /// The drag's gesture state went back while the star was out, and its
    /// end may still be reported: one landing still counts.
    private var landingPending = false

    var isFlying: Bool { star != nil }

    /// The finger moved to `finger` (a new drag starts this way too, which
    /// drops any landing left pending by an earlier one).
    mutating func move(finger: CGPoint) {
        star = StarDrop.star(finger: finger)
        landingPending = false
    }

    /// The finger lifted at `finger`: the star goes back, and the outcome
    /// says what the drop does. A landing counts only for a drag under way
    /// (the star is out, or its gesture state has just gone back) and while
    /// Today is the page showing with nothing over it
    /// (`TodayActivity.isOnScreen`); any other landing saves nothing.
    mutating func land(
        finger: CGPoint,
        bands: [CGRect],
        activity: TodayActivity,
        isSaved: (Int) -> Bool
    ) -> StarDrop.Outcome {
        let counts = isFlying || landingPending
        star = nil
        landingPending = false
        guard counts, activity.isOnScreen else { return .none }
        return StarDrop.outcome(at: StarDrop.star(finger: finger), bands: bands, isSaved: isSaved)
    }

    /// The drag's gesture state went back: it ended (before or after
    /// `land`) or the system took the touch. The star goes back; if it was
    /// out, the drag's landing may still come and counts.
    mutating func gestureReset() {
        if star != nil { landingPending = true }
        star = nil
    }

    /// Today cancelled the drag (a cover opened, another page, the app left
    /// the foreground): the star goes back and no landing counts.
    mutating func cancel() {
        star = nil
        landingPending = false
    }

    /// The row the star is over, for the outline.
    func row(bands: [CGRect]) -> Int? {
        star.flatMap { StarDrop.row(at: $0, bands: bands) }
    }
}
