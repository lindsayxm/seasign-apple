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
        /// The top row: the mark, the place name and settings.
        static let topRowY: CGFloat = 52
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
        static let tilesTop: CGFloat = 91
        /// The bottom tiles' top, from the bottom of the screen (734 on 852).
        static let bottomTilesFromBottom: CGFloat = 118
        /// The events box's first line box starts 3.6 points under its border.
        static let eventsPaddingTop: CGFloat = 3.6
        static let eventRows = 4
        /// The frame round the view: from 180 down to 40 under the horizon.
        static let frameTop: CGFloat = 180
        static let frameBelowHorizon: CGFloat = 40
        static let bracket: CGFloat = 10
        static let bracketLine: CGFloat = 1.2
        /// The labels inside the frame's top corners.
        static let frameLabelTop: CGFloat = 187.5
        static let frameLabelLeft: CGFloat = 42
        static let frameLabelFromRight: CGFloat = 44
        /// The rim: 7 in from the edge, broken from 176 to 54 under the horizon.
        static let rimInset: CGFloat = 7
        static let rimRadius: CGFloat = 39
        static let rimLine: CGFloat = 1.4
        static let rimGapTop: CGFloat = 176
        static let rimGapBelowHorizon: CGFloat = 54
        /// The plate: from 42 under the horizon to the rim's bottom.
        static let plateBelowHorizon: CGFloat = 42
        /// Its top fades in over this many points (the CSS gradient's stops).
        static let plateFade: CGFloat = 36
        /// The titles: first row 75 under the horizon, numbers at x 32,
        /// titles at x 68 and 290 wide, two 17-point lines on a 51 pitch.
        static let titlesBelowHorizon: CGFloat = 75
        static let numberX: CGFloat = 32
        static let titleX: CGFloat = 68
        /// The title column ends 35 in from the right edge (358 on 393).
        static let titleFromRight: CGFloat = 35
        static let titleLine: CGFloat = 17
        static let titleRowHeight: CGFloat = 34
        static let titlePitch: CGFloat = 51
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
    /// How many characters a row of the box holds (34 on the mockup).
    let eventColumns: Int
    /// The rows as drawn, at most four: events, then the zip prompt.
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

    // Bottom tiles.
    let tiles: [CGRect]

    struct EventRow: Equatable {
        /// What is drawn, one line of mono text.
        var text: String
        /// What VoiceOver says; nil for the zip prompt (its button speaks).
        var spoken: String?
        /// The left of the text (each row centred in the box, as CSS does)
        /// and the top of its 17-point line box.
        var origin: CGPoint
        var width: CGFloat
    }

    /// - Parameters:
    ///   - labels: the next events, soonest first; at most four are shown,
    ///     three when the zip prompt takes the last row.
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
        tiles = (0..<4).map { index in
            CGRect(
                x: M.margin + CGFloat(index) * (tileWidth + M.tileGap),
                y: size.height - M.bottomTilesFromBottom,
                width: tileWidth, height: M.tileHeight
            )
        }

        // The rows: as many characters as fit inside the border with at
        // least half a character free at each side (34 on the mockup, whose
        // rows stand about 4 points in from the border).
        let style = HUDType.eventRow
        let inner = eventsBox.width - 2 * M.tileBorder
        let columns = EventRowText.columns(width: inner - style.cell, cell: style.cell)
        eventColumns = columns
        let measure: (String) -> CGFloat = { style.width($0) }
        let shown = Array(labels.prefix(showsZipPrompt ? M.eventRows - 1 : M.eventRows))
        var texts: [(String, String?)] = shown.map {
            (EventRowText.row($0, columns: columns, maxWidth: inner, measure: measure), $0.spoken)
        }
        if showsZipPrompt {
            promptIndex = texts.count
            texts.append((EventRowText.message(Self.zipPromptText, columns: columns, maxWidth: inner, measure: measure), nil))
        } else {
            promptIndex = nil
        }
        let firstLine = eventsBox.minY + M.tileBorder + M.eventsPaddingTop
        let box = eventsBox
        eventRows = texts.enumerated().map { index, entry in
            let textWidth = measure(entry.0)
            return EventRow(
                text: entry.0,
                spoken: entry.1,
                origin: CGPoint(x: box.midX - textWidth / 2, y: firstLine + CGFloat(index) * style.lineHeight),
                width: textWidth
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
        titleCapacity = Self.titleRows(fitting: room)
    }

    /// One column of the four-column grid on a screen `screenWidth` wide.
    static func tileWidth(screenWidth: CGFloat) -> CGFloat {
        max(0, (screenWidth - 2 * Mockup.margin - 3 * Mockup.tileGap) / 4)
    }

    /// How many whole two-line rows fit in `room` points, never more than five.
    static func titleRows(fitting room: CGFloat) -> Int {
        var count = 0
        // A hair of tolerance for rounding.
        while count < HeadlineFit.maxCount,
              CGFloat(count) * Mockup.titlePitch + Mockup.titleRowHeight <= room + 0.5 {
            count += 1
        }
        return count
    }

    // MARK: Titles

    /// The top of title row `index`.
    func titleRowTop(_ index: Int) -> CGFloat {
        titlesTop + CGFloat(index) * Mockup.titlePitch
    }

    /// Title row `index` as a band from the number to the column's end, half
    /// a gap above and below, so the bands of neighbouring rows meet and a
    /// drop between two titles still lands on one.
    func titleBand(_ index: Int) -> CGRect {
        let half = (Mockup.titlePitch - Mockup.titleRowHeight) / 2
        return CGRect(
            x: Mockup.numberX,
            y: titleRowTop(index) - half,
            width: Mockup.titleX + titleWidth - Mockup.numberX,
            height: Mockup.titlePitch
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
