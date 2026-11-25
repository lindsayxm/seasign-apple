import SwiftUI

/// The events box on Today (design v12): an outline in the accent on a
/// dark panel beside the date tile, with the next three events as rows of
/// mono text (`EventRowText`, laid out by `TodayOverlayLayout`). With no
/// zip saved, the last row is the zip prompt, which opens Settings. With no
/// calendar at all (and a zip) the one row is "Add your calendar... ↑"
/// (task 218), plain text pointing at the settings button. With no
/// events the box stays, empty, so the grid under the top row keeps its
/// shape.
///
/// The whole box is one button that opens the day screen (task 170). It
/// lies under the rows and the zip prompt, so the prompt keeps its own
/// taps. It fires on a tap only (`TapOnlyButtonStyle`), so a pull that
/// starts on the box pulls and never opens the day screen. VoiceOver reads
/// each event as the plain event (`EventLabel.spoken`), never the dashes.
struct EventsColumn: View {
    var layout: TodayOverlayLayout
    /// Set while no zip is saved; opens Settings.
    var zipPrompt: (() -> Void)?
    /// Opens the day screen.
    var openDay: (() -> Void)?

    @Environment(\.hudAccent) private var accent

    /// The panel behind the rows: black at 62 %, as the mockup. Accent text
    /// sits on it over the sky, so it is never lighter than this.
    static let panelOpacity = 0.62

    var body: some View {
        let box = layout.eventsBox
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: layout.size.width, height: layout.size.height)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: TodayOverlayLayout.Mockup.tileRadius)
                .fill(Color.black.opacity(Self.panelOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: TodayOverlayLayout.Mockup.tileRadius)
                        .strokeBorder(accent, lineWidth: TodayOverlayLayout.Mockup.tileBorder)
                }
                .frame(width: box.width, height: box.height)
                .placed(x: box.minX, y: box.minY)
                .accessibilityHidden(true)
            if let openDay {
                dayButton(action: openDay)
            }
            // By position: two identical events would share an id. Taps
            // fall through to the day button under them; VoiceOver still
            // reads each row.
            ForEach(Array(layout.eventRows.enumerated()), id: \.offset) { index, row in
                if index == layout.promptIndex, let zipPrompt {
                    promptRow(row, action: zipPrompt)
                } else if index != layout.promptIndex {
                    rowText(row)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: row.spoken ?? row.text))
                        .placed(x: row.origin.x, y: row.origin.y)
                }
            }
        }
    }

    private func rowText(_ row: TodayOverlayLayout.EventRow) -> some View {
        // Verbatim: titles come from calendars and are never read as markup.
        Text(hud: row.text, style: HUDType.eventRow)
            .foregroundStyle(accent)
            .lineLimit(1)
            .fixedSize()
            .frame(width: row.width, height: HUDType.eventRow.lineHeight, alignment: .leading)
    }

    /// The whole box as one button.
    private func dayButton(action: @escaping () -> Void) -> some View {
        let target = layout.eventsBox
        return Button(action: action) {
            Color.clear
                .frame(width: target.width, height: target.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(TapOnlyButtonStyle())
        .accessibilityLabel("Today's calendar")
        .accessibilityHint("Shows all of today's events")
        // The style fires from a tap gesture, so the default action
        // (VoiceOver's double-tap) is given explicitly.
        .accessibilityAction { action() }
        .placed(x: target.minX, y: target.minY)
    }

    /// The zip prompt row, its target 44 points tall round the 22-point row
    /// and as wide as the box.
    private func promptRow(_ row: TodayOverlayLayout.EventRow, action: @escaping () -> Void) -> some View {
        let box = layout.eventsBox
        let lineHeight = HUDType.eventRow.lineHeight
        let inset = (44 - lineHeight) / 2
        return Button(action: action) {
            rowText(row)
                .padding(.leading, row.origin.x - box.minX)
                .frame(width: box.width, height: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set your zip code in Settings")
        .accessibilityHint("Opens Settings")
        .placed(x: box.minX, y: row.origin.y - inset)
    }
}

/// A button that fires on a tap only: a touch that moves (the pull on
/// Today) fails the tap, whatever the button's size, so a drag that starts
/// and ends inside it does not fire it. It is still a `Button`, so
/// VoiceOver lists it as one with its label; give it an explicit
/// `accessibilityAction` for the default action.
struct TapOnlyButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onTapGesture { configuration.trigger() }
    }
}
