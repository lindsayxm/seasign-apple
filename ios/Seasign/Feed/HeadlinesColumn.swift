import SwiftUI

/// The headlines in the water on Today: the newest items since yesterday, as
/// many as fit whole in the space above the `>>` button. It never scrolls.
///
/// How many fit is worked out before anything is laid out: each headline's
/// height is its line count from `CapsWrapper.wrap` (at most two lines)
/// times the line pitch, and `HeadlineFit.count` takes the longest run from
/// the newest that fits with the spacing between them.
///
/// An AI-found headline carries the "AI" mark before its first line and is
/// wrapped in what is left of the width, so the count above stays exact.
///
/// With no site followed and nothing to show, one quiet line points to
/// Settings. With sites but nothing new since yesterday, the water stays empty.
struct HeadlinesColumn: View {
    /// Newest first (`FeedModel.headlines`).
    var candidates: [FeedEntry]
    /// Scale of the Today layout (1 on a 393 pt wide screen).
    var s: CGFloat
    /// The height of the water area the headlines may use.
    var height: CGFloat
    /// No site is followed. The Settings prompt shows only when there are
    /// no candidates either (AI search can fill the water without sites).
    var followsNoSites: Bool
    var open: (FeedEntry) -> Void
    var openSettings: () -> Void

    private var size: CGFloat { 11.2 * s }
    private var pitch: CGFloat { 14.5 * s }
    private var width: CGFloat { 326 * s }
    private var spacing: CGFloat { 28.5 * s }
    private static let tracking: CGFloat = 0.185
    private var markSize: CGFloat { 7.5 * s }
    /// The mark and the gap after it.
    private var markWidth: CGFloat { AIMark.fixedWidth(size: markSize) + 8 * s }

    private func textWidth(_ entry: FeedEntry) -> CGFloat {
        entry.isAI ? max(0, width - markWidth) : width
    }
    private static let maxLines = 2

    var body: some View {
        if followsNoSites && candidates.isEmpty {
            Button(action: openSettings) {
                Text(caps: "Follow sites in Settings to see headlines here")
                    .caps(9.5 * s, tracking: 0.18)
                    .foregroundStyle(Palette.ink.opacity(0.55))
                    .frame(minHeight: 44, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Settings")
        } else {
            let shown = Array(candidates.prefix(fittingCount))
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(shown) { entry in
                    Button {
                        open(entry)
                    } label: {
                        HStack(alignment: .top, spacing: 0) {
                            if entry.isAI {
                                AIMark(size: markSize, color: Palette.ink, fixed: true)
                                    .frame(width: markWidth, height: pitch, alignment: .leading)
                            }
                            WrappedCaps(
                                text: entry.title,
                                size: size,
                                tracking: Self.tracking,
                                linePitch: pitch,
                                width: textWidth(entry),
                                maxLines: Self.maxLines
                            )
                        }
                        .foregroundStyle(Palette.ink)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Plain strings, so nothing a site wrote is read as markup.
                    .accessibilityLabel(AILabel.accessibility(title: entry.title, isAI: entry.isAI) + ", " + entry.source)
                    .accessibilityHint("Opens the article's summary")
                }
            }
        }
    }

    /// How many of the candidates fit in `height`.
    private var fittingCount: Int {
        let heights = candidates.prefix(HeadlineFit.maxCount).map { entry in
            CGFloat(lineCount(entry.title, width: textWidth(entry))) * pitch
        }
        return HeadlineFit.count(heights: Array(heights), spacing: spacing, available: height)
    }

    private func lineCount(_ title: String, width: CGFloat) -> Int {
        CapsWrapper.wrap(title.uppercased(), width: width, maxLines: Self.maxLines) { line in
            CapsWrapper.width(of: line, size: size, tracking: Self.tracking)
        }.count
    }
}
