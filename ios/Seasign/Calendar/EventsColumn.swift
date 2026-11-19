import SwiftUI

/// The events box on Today (design v11): up to three next events on a dark
/// ground, each with a thin rule in the ink colour at its left, the time in
/// two fixed columns in the ink colour, and the title in caps.
///
/// Where everything goes is worked out by `TodayOverlayLayout`: how many
/// events fit, how titles wrap, and where the zip prompt sits. With no zip the
/// prompt is a one-line row under the events. The rows together never take
/// more than five lines: the last two-line titles are cut to one line, which
/// always makes room, so no event is dropped. A word wider than the title
/// column (a pasted link, a title in a language written without spaces) is
/// broken between characters, and every drawn line is also held to the
/// column's width. With no events and no prompt there is no box. This view
/// fills the screen and draws at the layout's positions.
struct EventsColumn: View {
    var layout: TodayOverlayLayout
    var ink: Color
    /// Set while no zip is saved; opens Settings.
    var zipPrompt: (() -> Void)?

    private var s: CGFloat { layout.scale }
    private var line: CGFloat { TodayOverlayLayout.Mockup.line * s }
    private var boxX: CGFloat { layout.box?.minX ?? TodayOverlayLayout.Mockup.boxLeft * s }
    private var boxWidth: CGFloat {
        layout.box?.width ?? (TodayOverlayLayout.Mockup.boxRight - TodayOverlayLayout.Mockup.boxLeft) * s
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: layout.size.width, height: layout.size.height)
                .allowsHitTesting(false)
            if let box = layout.box {
                Rectangle()
                    .fill(Palette.todayEventsBox)
                    .frame(width: box.width, height: box.height)
                    .placed(x: box.minX, y: box.minY)
                    .accessibilityHidden(true)
            }
            // By position: two identical events would share an id.
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                eventRow(row)
                    .placed(x: boxX, y: row.top)
            }
            if let prompt = layout.prompt, let zipPrompt {
                // The 44-point target is centred on the 16-point row.
                promptRow(prompt, action: zipPrompt)
                    .placed(x: boxX, y: prompt.top - promptInset(prompt))
            }
        }
    }

    /// One event, in coordinates local to its row (x from the box's left).
    private func eventRow(_ row: TodayOverlayLayout.EventRow) -> some View {
        let fonts = layout.fonts
        typealias F = TodayOverlayLayout.Fonts
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: boxWidth, height: row.height)
            rule(height: row.height)
            Text(today: row.label.timeLead, font: fonts.time, tracking: F.timeTracking)
                .foregroundStyle(ink)
                .fixedSize()
                .placed(x: layout.timeX - boxX, baseline: layout.timeBaseline)
            if let tail = row.label.timeTail {
                Text(today: tail, font: fonts.time, tracking: F.timeTracking)
                    .foregroundStyle(ink)
                    .fixedSize()
                    .placed(x: layout.tailX - boxX, baseline: layout.timeBaseline)
            }
            ForEach(Array(row.lines.enumerated()), id: \.offset) { index, text in
                // Verbatim: titles come from calendars and are never read as markup.
                Text(today: text, font: fonts.event, tracking: F.eventTracking)
                    .foregroundStyle(Palette.todayText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    // A backstop: the wrap already keeps lines this narrow;
                    // the 2 points are within the box's padding.
                    .frame(width: layout.titleWidth + 2 * s, alignment: .leading)
                    .placed(x: layout.titleX - boxX, baseline: CGFloat(index) * line + layout.eventBaseline)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.label.spoken))
    }

    /// How far the prompt's 44-point target reaches above its row.
    private func promptInset(_ prompt: TodayOverlayLayout.PromptRow) -> CGFloat {
        max(0, (44 - prompt.height) / 2)
    }

    private func promptRow(_ prompt: TodayOverlayLayout.PromptRow, action: @escaping () -> Void) -> some View {
        let inset = promptInset(prompt)
        // From the time column to the box's right padding.
        let textWidth = boxX + boxWidth - TodayOverlayLayout.Mockup.boxPadding * s - layout.timeX
        return Button(action: action) {
            ZStack(alignment: .topLeading) {
                // A 44-point tall target with the row in its middle.
                Color.clear.frame(width: boxWidth, height: prompt.height + 2 * inset)
                rule(height: prompt.height)
                    .offset(y: inset)
                ForEach(Array(prompt.lines.enumerated()), id: \.offset) { index, text in
                    Text(today: text, font: layout.fonts.event, tracking: TodayOverlayLayout.Fonts.eventTracking)
                        .foregroundStyle(Palette.todayText.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: max(0, textWidth) + 2 * s, alignment: .leading)
                        .placed(x: layout.timeX - boxX, baseline: inset + CGFloat(index) * line + layout.eventBaseline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set your zip code in Settings")
        .accessibilityHint("Opens Settings")
    }

    private func rule(height: CGFloat) -> some View {
        Rectangle()
            .fill(ink.opacity(0.6))
            .frame(width: 1, height: height)
            .placed(x: layout.ruleX - boxX, y: 0)
    }
}
