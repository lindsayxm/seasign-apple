import SwiftUI

/// The frame of a full-screen page in the HUD's look (design v12, task 195):
/// the dark plate, the title in the accent's mono capitals, the close mark,
/// an accent hairline, and scrolling content.
struct SheetScaffold<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hudAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    Text(caps: title)
                        .hudText(.title)
                        .foregroundStyle(accent)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    CloseMark { dismiss() }
                        .padding(.trailing, -12)
                }
                HUDRule(accent: true)
                content
            }
            .padding(.horizontal, 35)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.hudPlate.ignoresSafeArea())
        .statusBarCover(Palette.hudPlate)
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Covers the status bar area with the page's ground (charcoal unless
    /// told), so content that scrolls up goes out of sight under it instead
    /// of showing through the clock and battery.
    func statusBarCover(_ ground: Color = Palette.charcoal) -> some View {
        overlay(alignment: .top) {
            ground
                .ignoresSafeArea(edges: .top)
                .frame(height: 0)
        }
    }
}
