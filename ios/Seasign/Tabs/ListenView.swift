import SwiftUI

/// LISTEN, the fourth main page (design v12): a placeholder until what it
/// will be is decided (`memory/decisions/2026-11-23-v12-replaces-v11.md`).
/// The title sits where Today's top row does, in the HUD's mono type and
/// accent on the dark plate; the tile bar is `MainTabsView`'s.
struct ListenView: View {
    @Environment(\.hudAccent) private var accent

    private typealias M = TodayOverlayLayout.Mockup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hud: "LISTEN", style: HUDType.place)
                .foregroundStyle(accent)
                .frame(height: HUDType.place.lineHeight)
                .accessibilityLabel("Listen")
                .accessibilityAddTraits(.isHeader)
            Text(hud: "Coming later.", style: HUDType.frameLabel)
                .foregroundStyle(accent)
                .frame(height: HUDType.frameLabel.lineHeight)
        }
        .padding(.leading, M.margin)
        .padding(.top, M.topRowY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.hudPlate)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
