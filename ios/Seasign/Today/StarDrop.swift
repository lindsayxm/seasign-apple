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
