import SwiftUI

/// The four main pages (design v12) and the tile bar that switches them in
/// place (`MainTabs`): Today, List (Do / Get), Saved and Listen. Settings,
/// the day screen, the read view and History open over them as covers with
/// a close mark.
///
/// Today stays mounted the whole time, hidden while another page shows, so
/// its scene never restarts or flashes on return; it pauses itself
/// (`TodayActivity`). The other pages are built when they show and let go
/// when they hide (Saved writes its notes as it goes). Today draws its own
/// tile bar (its SAVE star drags onto a title); the others get theirs here,
/// without the drag, at the same place on the screen
/// (`TodayOverlayLayout.tileBar(screen:)`), with their page's ground behind
/// it so rows scroll out of sight under the tiles.
struct MainTabsView: View {
    @State private var tabs = MainTabs()

    @Environment(TodayModel.self) private var today
    @Environment(SavedModel.self) private var saved

    #if DEBUG
    /// `-debugTab list` (or `save`, `listen`): that page shows at launch,
    /// for screenshots.
    @AppStorage("debugTab") private var debugTab = ""
    #endif

    /// Between the last row of a page and the top of the tiles.
    static let gapAboveTiles: CGFloat = 12

    var body: some View {
        let todayShowing = tabs.showing == .day
        ZStack {
            TodayView()
                .opacity(todayShowing ? 1 : 0)
                .allowsHitTesting(todayShowing)
                .accessibilityHidden(!todayShowing)

            if !todayShowing {
                GeometryReader { proxy in
                    page(tabs.showing)
                        // Room under the last row for the tiles; none while
                        // the keyboard is up, as it covers them.
                        .contentMargins(.bottom, Self.roomForTiles(bottomInset: proxy.safeAreaInsets.bottom), for: .scrollContent)
                }
                .overlay { tileBar(on: tabs.showing) }
            }
        }
        .environment(tabs)
        .alert(
            Text(verbatim: "Your notes aren't saved yet"),
            isPresented: Binding(get: { tabs.heldBack != nil }, set: { _ in })
        ) {
            Button(role: .cancel) {
                if saved.flushNotes() { tabs.leaveAnyway() } else { tabs.stay() }
            } label: {
                Text(verbatim: "Try again")
            }
            Button {
                // The drafts stay in memory and show again when Saved opens.
                tabs.leaveAnyway()
            } label: {
                Text(verbatim: "Leave anyway")
            }
        } message: {
            Text(verbatim: "They couldn't be written to this phone. They're kept while Seasign is open, and saving is tried again each time you open Saved.")
        }
        #if DEBUG
        .onAppear {
            switch debugTab {
            case "list": tabs.select(.list)
            case "save": tabs.select(.save)
            case "listen": tabs.select(.listen)
            default: break
            }
        }
        #endif
    }

    @ViewBuilder
    private func page(_ tile: HUDTileBar.Tile) -> some View {
        switch tile {
        case .day: EmptyView()
        case .list: DoGetView()
        case .save: SavedView(timeZone: headlineZone)
        case .listen: ListenView()
        }
    }

    /// The bar, on the page's own ground from a little above the tiles to
    /// the bottom of the screen. It ignores every safe area, the keyboard's
    /// included, so it never moves.
    private func tileBar(on tile: HUDTileBar.Tile) -> some View {
        GeometryReader { proxy in
            let bar = TodayOverlayLayout.tileBar(screen: proxy.size)
            let ground = Self.ground(tile)
            let groundTop = bar.minY - Self.gapAboveTiles
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: proxy.size.width, height: proxy.size.height)
                // Rows fade out over a few points as they reach the tiles.
                LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)
                    .frame(width: proxy.size.width, height: Self.fade)
                    .placed(x: 0, y: groundTop - Self.fade)
                ground
                    .frame(width: proxy.size.width, height: max(0, proxy.size.height - groundTop))
                    .placed(x: 0, y: groundTop)
                HUDTileBar(filled: tile, action: select)
                    .frame(width: bar.width)
                    .placed(x: bar.minX, y: bar.minY)
            }
        }
        .ignoresSafeArea()
    }

    /// Leaving Saved writes its notes first (`MainTabs.select`).
    private func select(_ tile: HUDTileBar.Tile) {
        tabs.select(tile) { saved.flushNotes() }
    }

    /// The extra room at the end of a page's scrolling content so its last
    /// row can be scrolled clear of the tiles, given the page's bottom safe
    /// area (the home indicator, or the keyboard while it is up).
    static func roomForTiles(bottomInset: CGFloat) -> CGFloat {
        max(0, TodayOverlayLayout.Mockup.bottomTilesFromBottom + gapAboveTiles - bottomInset)
    }

    /// How far above the ground rows fade out.
    static let fade: CGFloat = 16

    /// The colour each page is drawn on.
    static func ground(_ tile: HUDTileBar.Tile) -> Color {
        switch tile {
        case .day, .listen: Palette.hudPlate
        case .list, .save: Palette.charcoal
        }
    }

    /// The day "since yesterday" is counted in, as on Today.
    private var headlineZone: TimeZone {
        EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: .autoupdatingCurrent)
    }
}
