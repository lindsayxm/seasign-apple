import SwiftUI

/// A stand-in for a screen a later task builds (Do/Get, Saved, the 7-day
/// history), so the Today buttons lead somewhere.
struct PlaceholderScreen: View {
    var title: String
    var note: String

    var body: some View {
        SheetScaffold(title: title) {
            Text(caps: note)
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)
            Text(caps: "Coming soon")
                .capsRelative(11, medium: true)
                .foregroundStyle(Palette.white)
        }
    }
}

/// The frame shared by the full-screen sheets: charcoal, a caps title, a close
/// button, and scrolling content.
struct SheetScaffold<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    Text(caps: title)
                        .capsRelative(13, medium: true)
                        .foregroundStyle(Palette.white)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text(caps: "Close")
                            .capsRelative(11)
                            .foregroundStyle(Palette.dimText)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
                content
            }
            .padding(.horizontal, 35)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.charcoal.ignoresSafeArea())
        .statusBarCover()
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Covers the status bar area with the sheet's charcoal, so content that
    /// scrolls up goes out of sight under it instead of showing through the
    /// clock and battery.
    func statusBarCover() -> some View {
        overlay(alignment: .top) {
            Palette.charcoal
                .ignoresSafeArea(edges: .top)
                .frame(height: 0)
        }
    }
}
