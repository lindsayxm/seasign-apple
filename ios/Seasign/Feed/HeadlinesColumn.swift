import SwiftUI

/// The article titles in the sea on Today (design v11): the items since
/// yesterday, the followed sites' and the AI-found every other
/// (`HeadlinePicker.everyOther`), numbered 01, 02, …, on rows 57 points apart,
/// as many as fit above the `∀` button and never more than five. It never
/// scrolls.
///
/// How many fit is worked out before anything is laid out: each title is
/// broken into at most two lines of Iowan Old Style with `CapsWrapper.wrap`
/// (the same lines that are drawn), and `HeadlineFit.count(textHeights:…)`
/// takes the longest run from the first whose last row's text ends above
/// `∀`'s target.
///
/// An AI-found title looks like any other here (no "AI" mark, the same
/// width); VoiceOver still says it was AI-found.
///
/// With no site followed and nothing to show, one quiet line points to
/// Settings. With sites but nothing new since yesterday, the sea stays empty.
struct HeadlinesColumn: View {
    /// In Today's order (`FeedModel.headlines`).
    var candidates: [FeedEntry]
    var layout: TodayOverlayLayout
    /// No site is followed. The Settings prompt shows only when there are
    /// no candidates either (AI search can fill the sea without sites).
    var followsNoSites: Bool
    /// The screen's ink colour, for the numbers.
    var ink: Color
    var open: (FeedEntry) -> Void
    var openSettings: () -> Void

    private static let maxLines = 2
    private var s: CGFloat { layout.scale }
    private var color: Color { Palette.seaText }
    private var rowWidth: CGFloat { TodayOverlayLayout.Mockup.feedWidth * s }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: layout.size.width, height: layout.size.height)
                .allowsHitTesting(false)
            if followsNoSites && candidates.isEmpty {
                Button(action: openSettings) {
                    Text(caps: "Follow sites in Settings to see headlines here")
                        .caps(9.5 * s, tracking: 0.18)
                        .foregroundStyle(color.opacity(0.62))
                        .frame(minHeight: 44, alignment: .topLeading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Settings")
                .placed(x: layout.leftX, y: layout.headlinesTop)
            } else {
                let rows = fittingRows
                ForEach(Array(rows.enumerated()), id: \.element.entry.id) { index, row in
                    headline(row, index: index)
                        .placed(x: layout.leftX, y: layout.headlineRowTop(index))
                }
            }
        }
    }

    private struct Row {
        var entry: FeedEntry
        var lines: [String]
    }

    private func headline(_ row: Row, index: Int) -> some View {
        let textHeight = CGFloat(max(1, row.lines.count)) * layout.titleLineHeight
        // The row's whole height is the target, at least 44 points.
        let height = min(layout.headlinePitch, max(44, textHeight))
        let titleX = layout.headlineTitleX - layout.leftX
        let font = layout.fonts.title
        return Button {
            open(row.entry)
        } label: {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: rowWidth, height: height)
                Text(today: String(format: "%02d", index + 1), font: layout.fonts.number,
                     tracking: TodayOverlayLayout.Fonts.numberTracking)
                    .foregroundStyle(ink.opacity(0.85))
                    .fixedSize()
                    .placed(x: 0, baseline: layout.numberBaseline)
                ForEach(Array(row.lines.enumerated()), id: \.offset) { lineIndex, text in
                    // Verbatim: titles come from websites and are never read as markup.
                    Text(today: text, font: font, tracking: TodayOverlayLayout.Fonts.titleTracking)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        // A backstop: the wrap already keeps lines this narrow.
                        .frame(width: textWidth + 2 * s, alignment: .leading)
                        .placed(x: titleX, baseline: CGFloat(lineIndex) * layout.titleLineHeight + layout.titleBaseline)
                }
            }
            .shadow(color: .black.opacity(0.9), radius: 3)
            .shadow(color: .black.opacity(0.7), radius: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Plain strings, so nothing a site wrote is read as markup.
        .accessibilityLabel(AILabel.accessibility(title: row.entry.title, isAI: row.entry.isAI) + ", " + row.entry.source)
        .accessibilityHint("Opens the article's summary")
    }

    /// The width a title's lines may take: the column, for every title.
    private var textWidth: CGFloat {
        max(0, layout.headlineTitleWidth)
    }

    /// The candidates that fit, with their lines. A word wider than the
    /// column (a pasted link, a title written without spaces) is broken
    /// between characters, so no line runs past it.
    private var fittingRows: [Row] {
        let font = layout.fonts.title
        let measure: (String) -> CGFloat = {
            TodayType.width($0, font: font, tracking: TodayOverlayLayout.Fonts.titleTracking)
        }
        let rows = candidates.prefix(HeadlineFit.maxCount).map { entry in
            Row(entry: entry, lines: CapsWrapper.wrap(
                entry.title, width: textWidth, maxLines: Self.maxLines, breakingLongWords: true, measure: measure
            ))
        }
        let count = HeadlineFit.count(
            textHeights: rows.map { CGFloat(max(1, $0.lines.count)) * layout.titleLineHeight },
            pitch: layout.headlinePitch,
            available: layout.headlinesBottom - layout.headlinesTop
        )
        return Array(rows.prefix(count))
    }
}
