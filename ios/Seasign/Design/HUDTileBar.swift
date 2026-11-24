import SwiftUI

/// The four tiles along the bottom of the main pages (design v12): `DAY`,
/// `LIST`, `SAVE` and `LISTEN`, each with its label at the top left, a slash
/// at the bottom left and a line icon at the bottom right. The tile of the
/// page showing is filled with the accent; the others are outlined on the
/// dark plate.
///
/// It takes the width it is given (four equal columns, 6 points apart) and
/// is 78 points tall. What each tile does is the caller's (`action`;
/// `MainTabs` switches the page); the SAVE tile can also hand its star to a
/// drag (`starDrag`), which Today uses to save a title by dropping the star
/// on it (`StarDrop`). On the other pages the star does not drag. Every page
/// places the bar at `TodayOverlayLayout.tileBar(screen:)`.
struct HUDTileBar: View {
    enum Tile: CaseIterable, Equatable {
        case day, list, save, listen

        var label: String {
            switch self {
            case .day: "Day"
            case .list: "List"
            case .save: "Save"
            case .listen: "Listen"
            }
        }

        var glyph: HUDGlyph {
            switch self {
            case .day: .day
            case .list: .list
            case .save: .save
            case .listen: .listen
            }
        }

        /// What VoiceOver says for the tile.
        var spoken: String {
            switch self {
            case .day: "Today"
            case .list: "Do and get lists"
            case .save: "Saved"
            case .listen: "Listen"
            }
        }
    }

    /// The star's drag from the SAVE tile, in the coordinate space `space`.
    struct StarDrag {
        var space: String
        /// The finger moved: where it is now.
        var changed: (CGPoint) -> Void
        /// The finger lifted there.
        var ended: (CGPoint) -> Void
        /// The drag's gesture state went back: after `ended` or before it
        /// (SwiftUI does not say which), or alone when the system took the
        /// touch. Put the star back.
        var gestureReset: () -> Void
    }

    /// A VoiceOver action for the page showing, offered on its (filled)
    /// tile, which is on screen even when the page has nothing else to
    /// carry it (Today's headline refresh with an empty plate).
    struct PageAction: Identifiable {
        var name: String
        var perform: () -> Void
        var id: String { name }
    }

    /// The page showing.
    var filled: Tile
    var action: (Tile) -> Void
    var starDrag: StarDrag?
    var pageActions: [PageAction] = []

    /// True while the star's drag is under way; it goes back to false
    /// however the drag ends, cancelled included.
    @GestureState private var isDraggingStar = false

    var body: some View {
        HStack(spacing: TodayOverlayLayout.Mockup.tileGap) {
            ForEach(Tile.allCases, id: \.self) { tile in
                tileButton(tile)
            }
        }
        .frame(height: TodayOverlayLayout.Mockup.tileHeight)
        .onChange(of: isDraggingStar) { _, dragging in
            if !dragging { starDrag?.gestureReset() }
        }
    }

    @ViewBuilder
    private func tileButton(_ tile: Tile) -> some View {
        let button = Button {
            action(tile)
        } label: {
            HUDTileFace(
                label: tile.label.uppercased(),
                glyph: tile.glyph,
                isFilled: tile == filled
            )
            .contentShape(Rectangle())
        }
        // Fires on a tap only, so the star's drag and Today's pull never
        // press a tile; VoiceOver's double-tap is given explicitly.
        .buttonStyle(TapOnlyButtonStyle())
        .accessibilityLabel(tile.spoken)
        .accessibilityAddTraits(tile == filled ? .isSelected : [])
        .accessibilityAction { action(tile) }
        .accessibilityActions {
            if tile == filled {
                ForEach(pageActions) { pageAction in
                    Button(pageAction.name, action: pageAction.perform)
                }
            }
        }

        if tile == .save, let starDrag {
            button
                .accessibilityHint("Opens Saved. Each title also has a Save action.")
                .gesture(
                    DragGesture(minimumDistance: StarDrop.minimumDistance, coordinateSpace: .named(starDrag.space))
                        .updating($isDraggingStar) { _, state, _ in state = true }
                        .onChanged { starDrag.changed($0.location) }
                        .onEnded { starDrag.ended($0.location) }
                )
        } else {
            button
        }
    }
}

/// One tile's face: label at the top left, a slash at the bottom left and
/// the icon at the bottom right. Filled with the accent (dark text), or
/// outlined in the accent on the dark plate.
struct HUDTileFace: View {
    var label: String
    var glyph: HUDGlyph
    var isFilled: Bool

    @Environment(\.hudAccent) private var accent

    var body: some View {
        typealias M = TodayOverlayLayout.Mockup
        let ink = isFilled ? Palette.onAccent : accent
        let inset = M.tileBorder + M.tilePadding
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: M.tileRadius)
                .fill(isFilled ? accent : Palette.hudPlate.opacity(0.92))
            RoundedRectangle(cornerRadius: M.tileRadius)
                .strokeBorder(accent, lineWidth: M.tileBorder)
            Text(hud: label, style: HUDType.tabLabel)
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .frame(height: HUDType.tabLabel.lineHeight)
                .padding(.leading, inset)
                .padding(.top, inset)
            HStack(alignment: .bottom, spacing: 0) {
                Text(hud: "/", style: HUDType.tabFoot)
                    .foregroundStyle(ink)
                    .frame(height: HUDType.tabFoot.lineHeight)
                Spacer(minLength: 0)
                HUDGlyphView(glyph: glyph, color: ink)
            }
            .padding(.horizontal, inset)
            .padding(.bottom, M.tileBorder + M.tileFootBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity)
        .frame(height: M.tileHeight)
    }
}
