import SwiftUI

/// The article titles on Today's dark plate (design v12): the items since
/// yesterday, the followed sites' and the AI-found every other
/// (`HeadlinePicker.everyOther`), numbered 01, 02, … at x 32 with the title
/// at x 68 on up to two lines of mono type, on rows 54 points apart. As many
/// whole rows as fit above the tiles (`TodayOverlayLayout.titleCapacity`),
/// never more than five. It never scrolls.
///
/// Every row takes two lines' room, so how many fit does not depend on the
/// titles. A title is broken at spaces with `CapsWrapper.wrap` (a word wider
/// than the column, such as a pasted link, is broken between characters);
/// one longer than two lines ends in "…".
///
/// An AI-found title looks like any other here; VoiceOver still says it was
/// AI-found. With no site followed and nothing to show, one quiet line
/// points to Settings. With sites but nothing new since yesterday, the
/// plate stays empty.
struct HeadlinesColumn: View {
    /// In Today's order (`FeedModel.headlines`).
    var candidates: [FeedEntry]
    var layout: TodayOverlayLayout
    /// No site is followed. The Settings prompt shows only when there are
    /// no candidates either (AI search can fill the plate without sites).
    var followsNoSites: Bool
    /// The row the dragged star is over, outlined while it is there.
    var starTarget: Int?
    var open: (FeedEntry) -> Void
    var openSettings: () -> Void
    /// VoiceOver's stand-in for dropping the star on a title.
    var save: (FeedEntry) -> Void = { _ in }
    /// The headline pull, offered to VoiceOver on each row (VoiceOver keeps
    /// drags for itself).
    var refresh: () -> Void = {}

    @Environment(\.hudAccent) private var accent

    private static let maxLines = 2
    private var style: MonoStyle { HUDType.title }

    /// The titles shown, in order.
    static func shown(_ candidates: [FeedEntry], layout: TodayOverlayLayout) -> [FeedEntry] {
        Array(candidates.prefix(layout.titleCapacity))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: layout.size.width, height: layout.size.height)
                .allowsHitTesting(false)
            if followsNoSites && candidates.isEmpty {
                Button(action: openSettings) {
                    Text(hud: "Follow sites in Settings to see headlines here /", style: style)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        // Held to the titles' band, so the line shrinks
                        // rather than running off the screen (task 205: at 12
                        // points it is wider than the band).
                        .frame(width: layout.titleBand(0).width, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow sites in Settings to see headlines here")
                .accessibilityHint("Opens Settings")
                .accessibilityAction(named: Text(TodayPull.headlinesActionName), refresh)
                .placed(x: TodayOverlayLayout.Mockup.numberX, y: layout.titlesTop + style.lineHeight / 2 - 22)
            } else {
                ForEach(Array(Self.shown(candidates, layout: layout).enumerated()), id: \.element.id) { index, entry in
                    headline(entry, index: index)
                        .placed(x: TodayOverlayLayout.Mockup.numberX, y: layout.titleRowTop(index))
                }
                if let starTarget, starTarget < Self.shown(candidates, layout: layout).count {
                    let band = layout.titleBand(starTarget)
                    RoundedRectangle(cornerRadius: TodayOverlayLayout.Mockup.tileRadius)
                        .strokeBorder(accent, lineWidth: 1)
                        .frame(width: band.width + 12, height: TodayOverlayLayout.Mockup.titleRowHeight + 10)
                        .placed(x: band.minX - 6, y: layout.titleRowTop(starTarget) - 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func headline(_ entry: FeedEntry, index: Int) -> some View {
        typealias M = TodayOverlayLayout.Mockup
        let lines = Self.lines(entry.title, width: layout.titleWidth)
        return Button {
            open(entry)
        } label: {
            ZStack(alignment: .topLeading) {
                // The row's whole height is the target, at least 44 points.
                Color.clear.frame(width: layout.titleBand(index).width, height: max(44, M.titleRowHeight))
                Text(hud: String(format: "%02d", index + 1), style: style)
                    .foregroundStyle(accent)
                    .fixedSize()
                    .frame(height: style.lineHeight)
                ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, text in
                    // Verbatim: titles come from websites and are never read as markup.
                    Text(hud: text, style: style)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: style.lineHeight)
                        .placed(x: M.titleX - M.numberX, y: CGFloat(lineIndex) * M.titleLine)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Plain strings, so nothing a site wrote is read as markup.
        .accessibilityLabel(AILabel.accessibility(title: entry.title, isAI: entry.isAI) + ", " + entry.source)
        .accessibilityHint("Opens the article's summary")
        .accessibilityAction(named: Text(verbatim: "Save")) { save(entry) }
        .accessibilityAction(named: Text(TodayPull.headlinesActionName), refresh)
    }

    /// A title broken into at most two lines of the column's width, as drawn.
    static func lines(_ title: String, width: CGFloat) -> [String] {
        let style = HUDType.title
        return CapsWrapper.wrap(title, width: width, maxLines: maxLines, breakingLongWords: true) { style.width($0) }
    }
}
