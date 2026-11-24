import SwiftUI
import UIKit

/// Where every part of Today's overlay sits (design v12,
/// `design-ideas/v12-imago/`: `index.html` and the positions in its
/// `README.md`). Worked out once from the screen size and the text, so
/// nothing is measured back from the views. Everything is in screen points
/// from the top-left corner.
///
/// The mockup is 393 × 852. On other screens (the plan's defaults):
///
/// - the side margins stay 34 points and the tiles stretch; type never
///   scales;
/// - the top (mark, place, settings, date tile, events box) keeps its
///   distance from the top of the screen, and the four tiles keep theirs
///   from the bottom;
/// - the scene scales with the width as before (`SceneLayout`), and the
///   view's furniture hangs from its horizon: the frame's corner brackets,
///   the break in the rim, the plate and the titles. On a tall screen the
///   spare height goes to the scene; on a short one the titles give way
///   first, whole rows at a time.
struct TodayOverlayLayout {
    /// The mockup's figures, in its points (393 × 852, horizon at 386).
    enum Mockup {
        static let margin: CGFloat = 34
        /// Extra room under the status bar, added to the mockup's figures for
        /// the top row and everything that hangs from it down to the frame's
        /// top (the user, 2026-11-23: the mark and settings sat too close to
        /// the system's time, battery and wifi).
        static let topPadding: CGFloat = 14
        /// The top row: the mark, the place name and settings.
        static let topRowY: CGFloat = 52 + topPadding
        static let topRowHeight: CGFloat = 24
        static let markSide: CGFloat = 24
        /// Settings stands this far in from the right edge (335 on 393).
        static let settingsFromRight: CGFloat = 58
        /// The place name ends this far in from the right edge (`right: 72px`).
        static let placeFromRight: CGFloat = 72
        /// The four-column grid of the date tile and the bottom tiles.
        static let tileGap: CGFloat = 6
        static let tileHeight: CGFloat = 78
        static let tileRadius: CGFloat = 4
        static let tileBorder: CGFloat = 1.4
        /// The label inside a tile: 7 points in from the border.
        static let tilePadding: CGFloat = 7
        /// The foot (slash and value) stands 6 points above the border.
        static let tileFootBottom: CGFloat = 6
        static let tilesTop: CGFloat = 91 + topPadding
        /// The bottom tiles' top, from the bottom of the screen (734 on 852).
        static let bottomTilesFromBottom: CGFloat = 118
        /// How many rows the events box holds (task 205: three in larger
        /// type; the mockup has four).
        static let eventRows = 3
        /// The rows are centred in the box: the first line box starts this
        /// far under the border (4.6 for three 22-point rows in 78; the
        /// mockup's four 17-point rows started 3.6 under it).
        static var eventsPaddingTop: CGFloat {
            (tileHeight - 2 * tileBorder - CGFloat(eventRows) * HUDType.eventRow.lineHeight) / 2
        }
        /// The frame round the view: from 180 down to 40 under the horizon.
        static let frameTop: CGFloat = 180 + topPadding
        static let frameBelowHorizon: CGFloat = 40
        static let bracket: CGFloat = 10
        static let bracketLine: CGFloat = 1.2
        /// The labels inside the frame's top corners.
        static let frameLabelTop: CGFloat = 187.5 + topPadding
        static let frameLabelLeft: CGFloat = 42
        static let frameLabelFromRight: CGFloat = 44
        /// The rim: 7 in from the edge, broken from 176 to 54 under the horizon.
        static let rimInset: CGFloat = 7
        static let rimRadius: CGFloat = 39
        static let rimLine: CGFloat = 1.4
        static let rimGapTop: CGFloat = 176 + topPadding
        static let rimGapBelowHorizon: CGFloat = 54
        /// The plate: from 42 under the horizon to the rim's bottom.
        static let plateBelowHorizon: CGFloat = 42
        /// Its top fades in over this many points (the CSS gradient's stops).
        static let plateFade: CGFloat = 36
        /// The titles: first row 75 under the horizon, numbers at x 32,
        /// titles at x 68 and 290 wide, two 19-point lines on a 54 pitch
        /// (task 205, for 12-point type; the mockup's 17-point lines sat on a
        /// 51 pitch). Five rows still fit above the tiles at 393 x 852.
        static let titlesBelowHorizon: CGFloat = 75
        static let numberX: CGFloat = 32
        static let titleX: CGFloat = 68
        /// The title column ends 35 in from the right edge (358 on 393).
        static let titleFromRight: CGFloat = 35
        static let titleLine: CGFloat = 19
        static let titleRowHeight: CGFloat = 38
        static let titlePitch: CGFloat = 54
        /// The tightest pitch a small screen may use to fit a second row
        /// (task 207): the rows 8 apart.
        static let titlePitchFloor: CGFloat = 46
        /// A row is shown only when it ends at least this far above the tiles.
        static let titlesAboveTiles: CGFloat = 17
    }

    /// Type sizes the scene shares with the overlay.
    enum Fonts {
        /// The rise and set times under the horizon, drawn by the scene
        /// (task 165: 10 points; the v12 mockup kept v11's 8.5).
        static let timeSize: CGFloat = 10
    }

    static let zipPromptText = "Set your zip code in Settings"
    /// The prompt drawn when the full one would be cut (task 205: at 13
    /// points a row holds 27 to 30 characters on most phones). VoiceOver
    /// still says `zipPromptText`.
    static let shortZipPromptText = "Set zip code in Settings"

    /// The prompt to draw in a row of `columns` characters: the full text
    /// when it fits whole (in the cut form's room, a dash and the slash),
    /// otherwise the short one.
    static func zipPrompt(columns: Int) -> String {
        zipPromptText.count + 3 <= columns ? zipPromptText : shortZipPromptText
    }

    let size: CGSize
    /// The scene's horizon.
    let horizonY: CGFloat

    // Top row.
    let markRect: CGRect
    let settingsRect: CGRect
    /// The right edge of the place name; it is centred on the top row.
    let placeRight: CGFloat
    /// The widest the place name may be: from past the mark to `placeRight`.
    let placeMaxWidth: CGFloat

    // Date tile and events box.
    let dateTile: CGRect
    let eventsBox: CGRect
    /// How many characters a row of the box holds (29 at 393 points; the
    /// mockup's smaller type held 34).
    let eventColumns: Int
    /// The rows as drawn, at most three: events, then the zip prompt.
    let eventRows: [EventRow]
    /// The zip prompt's row index in `eventRows`, if shown.
    let promptIndex: Int?

    // The frame round the view.
    let frame: CGRect
    let frameLabelTop: CGFloat
    let frameLabelLeft: CGFloat
    let frameLabelRight: CGFloat

    // Rim and plate.
    let rimRadius: CGFloat
    let rimGap: ClosedRange<CGFloat>
    let plate: CGRect

    // Titles.
    let titlesTop: CGFloat
    let titleWidth: CGFloat
    /// How many title rows fit above the tiles (never more than five).
    let titleCapacity: Int
    /// From one row's top to the next: `Mockup.titlePitch`, or tighter on a
    /// screen that would otherwise fit a single row (`titlePitch(fitting:)`).
    let titlePitch: CGFloat

    // Bottom tiles.
    let tiles: [CGRect]

    struct EventRow: Equatable {
        /// What is drawn, one line of mono text.
        var text: String
        /// What VoiceOver says; nil for the zip prompt (its button speaks).
        var spoken: String?
        /// The left of the text (the same for every row: a full row centred
        /// in the box, as CSS centres it) and the top of its line box
        /// (`HUDType.eventRow.lineHeight`).
        var origin: CGPoint
        var width: CGFloat
    }

    /// - Parameters:
    ///   - labels: the next events, soonest first; at most three are shown,
    ///     two when the zip prompt takes the last row.
    ///   - showsZipPrompt: no zip is set yet.
    ///   - cornerRadius: the rim's corner radius, when the system reports
    ///     the screen's own (`concentricCornerRadii`); the mockup's 39
    ///     otherwise.
    init(size: CGSize, labels: [EventLabel], showsZipPrompt: Bool, cornerRadius: CGFloat? = nil) {
        typealias M = Mockup
        self.size = size
        let width = size.width
        let horizon = SceneLayout(size: size).horizonY
        horizonY = horizon

        markRect = CGRect(x: M.margin, y: M.topRowY, width: M.markSide, height: M.markSide)
        settingsRect = CGRect(x: width - M.settingsFromRight, y: M.topRowY, width: M.markSide, height: M.markSide)
        placeRight = width - M.placeFromRight
        placeMaxWidth = max(0, placeRight - markRect.maxX - 12)

        // The four-column grid: the date tile is one column, the events box
        // the other three and their gaps.
        let tileWidth = Self.tileWidth(screenWidth: width)
        dateTile = CGRect(x: M.margin, y: M.tilesTop, width: tileWidth, height: M.tileHeight)
        let boxX = M.margin + tileWidth + M.tileGap
        eventsBox = CGRect(x: boxX, y: M.tilesTop, width: width - M.margin - boxX, height: M.tileHeight)
        let bar = Self.tileBar(screen: size)
        tiles = (0..<4).map { index in
            CGRect(
                x: bar.minX + CGFloat(index) * (tileWidth + M.tileGap),
                y: bar.minY,
                width: tileWidth, height: M.tileHeight
            )
        }

        // The rows: as many characters as fit inside the border with at
        // least half a character free at each side (34 on the mockup, whose
        // rows stand about 4 points in from the border; 29 at 13 points).
        let style = HUDType.eventRow
        let inner = eventsBox.width - 2 * M.tileBorder
        let columns = EventRowText.columns(width: inner - style.cell, cell: style.cell)
        eventColumns = columns
        let measure: (String) -> CGFloat = { style.width($0) }
        // Every row starts at one x: a full row of mono cells centred in
        // the box, so the time columns line up even when a row of wide
        // characters measures differently. A row may run to the border.
        let rowLeft = eventsBox.midX - measure(String(repeating: "0", count: columns)) / 2
        let maxWidth = eventsBox.maxX - M.tileBorder - rowLeft
        let shown = Array(labels.prefix(showsZipPrompt ? M.eventRows - 1 : M.eventRows))
        var texts: [(String, String?)] = shown.map {
            (EventRowText.row($0, columns: columns, maxWidth: maxWidth, measure: measure), $0.spoken)
        }
        if showsZipPrompt {
            promptIndex = texts.count
            texts.append((EventRowText.message(Self.zipPrompt(columns: columns), columns: columns, maxWidth: maxWidth, measure: measure), nil))
        } else {
            promptIndex = nil
        }
        let firstLine = eventsBox.minY + M.tileBorder + M.eventsPaddingTop
        eventRows = texts.enumerated().map { index, entry in
            EventRow(
                text: entry.0,
                spoken: entry.1,
                origin: CGPoint(x: rowLeft, y: firstLine + CGFloat(index) * style.lineHeight),
                width: measure(entry.0)
            )
        }

        frame = CGRect(x: M.margin, y: M.frameTop, width: width - 2 * M.margin, height: horizon + M.frameBelowHorizon - M.frameTop)
        frameLabelTop = M.frameLabelTop
        frameLabelLeft = M.frameLabelLeft
        frameLabelRight = width - M.frameLabelFromRight

        rimRadius = cornerRadius.flatMap { $0 > 1 ? $0 : nil } ?? M.rimRadius
        rimGap = M.rimGapTop...(horizon + M.rimGapBelowHorizon)
        let plateTop = horizon + M.plateBelowHorizon
        plate = CGRect(x: M.rimInset, y: plateTop, width: width - 2 * M.rimInset, height: size.height - M.rimInset - plateTop)

        titlesTop = horizon + M.titlesBelowHorizon
        titleWidth = width - M.titleFromRight - M.titleX
        let room = (size.height - M.bottomTilesFromBottom) - M.titlesAboveTiles - titlesTop
        titlePitch = Self.titlePitch(fitting: room)
        titleCapacity = Self.titleRows(fitting: room, pitch: titlePitch)
    }

    /// The four-tile bar on a screen `screen` big, in full-screen points:
    /// 34 in from each side, its top 118 above the bottom edge. Every main
    /// page puts the bar here (Today through `tiles`, List, Saved and Listen
    /// through `MainTabsView`), so it does not move when the page changes.
    static func tileBar(screen: CGSize) -> CGRect {
        CGRect(
            x: Mockup.margin,
            y: screen.height - Mockup.bottomTilesFromBottom,
            width: max(0, screen.width - 2 * Mockup.margin),
            height: Mockup.tileHeight
        )
    }

    /// One column of the four-column grid on a screen `screenWidth` wide.
    static func tileWidth(screenWidth: CGFloat) -> CGFloat {
        max(0, (screenWidth - 2 * Mockup.margin - 3 * Mockup.tileGap) / 4)
    }

    /// The rows' pitch in `room` points (task 207, the user's choice of
    /// 2026-11-24): the mockup's 54 wherever two rows fit at it or not even
    /// one does; where only one fits, the largest whole-point pitch, 46 or
    /// more, that fits a second (50 on the iPhone SE), so a small screen
    /// shows two titles. With no such pitch it stays 54 and one row shows.
    static func titlePitch(fitting room: CGFloat) -> CGFloat {
        guard titleRows(fitting: room, pitch: Mockup.titlePitch) == 1 else { return Mockup.titlePitch }
        // No rounding tolerance here: the second row must end clear of the tiles.
        let tight = (room - Mockup.titleRowHeight).rounded(.down)
        return tight >= Mockup.titlePitchFloor ? min(tight, Mockup.titlePitch) : Mockup.titlePitch
    }

    /// How many whole two-line rows fit in `room` points on `pitch`, never
    /// more than five.
    static func titleRows(fitting room: CGFloat, pitch: CGFloat = Mockup.titlePitch) -> Int {
        var count = 0
        // A hair of tolerance for rounding.
        while count < HeadlineFit.maxCount,
              CGFloat(count) * pitch + Mockup.titleRowHeight <= room + 0.5 {
            count += 1
        }
        return count
    }

    // MARK: Titles

    /// The top of title row `index`.
    func titleRowTop(_ index: Int) -> CGFloat {
        titlesTop + CGFloat(index) * titlePitch
    }

    /// Title row `index` as a band from the number to the column's end, half
    /// a gap above and below, so the bands of neighbouring rows meet and a
    /// drop between two titles still lands on one.
    func titleBand(_ index: Int) -> CGRect {
        let half = (titlePitch - Mockup.titleRowHeight) / 2
        return CGRect(
            x: Mockup.numberX,
            y: titleRowTop(index) - half,
            width: Mockup.titleX + titleWidth - Mockup.numberX,
            height: titlePitch
        )
    }

    // MARK: Rim

    /// The rim: a rounded outline `rimInset` in from the edge, broken down
    /// both sides along `rimGap`, where the view is.
    var rimPath: Path {
        let inset = Mockup.rimInset
        let r = rimRadius
        let x0 = inset, x1 = size.width - inset, y0 = inset, y1 = size.height - inset
        var path = Path()
        path.move(to: CGPoint(x: x0, y: rimGap.lowerBound))
        path.addLine(to: CGPoint(x: x0, y: y0 + r))
        path.addArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: x1 - r, y: y0))
        path.addArc(center: CGPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: x1, y: rimGap.lowerBound))
        path.move(to: CGPoint(x: x0, y: rimGap.upperBound))
        path.addLine(to: CGPoint(x: x0, y: y1 - r))
        path.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: x1 - r, y: y1))
        path.addArc(center: CGPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: x1, y: rimGap.upperBound))
        return path
    }

    // MARK: Pull spinners

    /// The frame of each pull's spinner, in points.
    static let spinnerSide: CGFloat = 20

    /// The calendar pull's spinner: in the events box's upper right corner,
    /// level with the first row.
    var calendarSpinnerCenter: CGPoint {
        CGPoint(
            x: eventsBox.maxX - Mockup.tileBorder - Self.spinnerSide / 2,
            y: eventsBox.minY + Mockup.tileBorder + Mockup.eventsPaddingTop + HUDType.eventRow.lineHeight / 2
        )
    }

    /// The headline pull's spinner: at the right of the first title line,
    /// under the calendar one.
    var headlineSpinnerCenter: CGPoint {
        CGPoint(x: calendarSpinnerCenter.x, y: titlesTop + Mockup.titleLine / 2)
    }
}
