import SwiftUI

/// LISTEN, the fourth main page (design v12): a placeholder until what it
/// will be is decided (`memory/decisions/2026-11-23-v12-replaces-v11.md`).
/// Its title sits where Saved's does, in the same accent mono capitals
/// (task 197), on the dark plate; the tile bar is `MainTabsView`'s.
struct ListenView: View {
    @Environment(\.hudAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caps: "Listen")
                .hudText(.title)
                .foregroundStyle(accent)
                .frame(minHeight: 44)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: "Coming later.")
                .hudText(.note)
                .foregroundStyle(accent)
        }
        // Saved's header row: 20 in from the sides, 8 under the status bar.
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.hudPlate.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
