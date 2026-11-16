import SwiftUI

/// Shown instead of Today when the store that holds the user's lists and
/// settings will not open. The app deletes nothing in that case; this screen
/// says so and lets the user try again.
struct StoreErrorView: View {
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Seasign can't open your saved data")
                .capsRelative(13, medium: true)
                .foregroundStyle(Palette.white)
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)
            Text("Your lists and settings are still on this iPhone. Nothing has been deleted.")
                .capsRelative(11, tracking: 0.12)
                .lineSpacing(4)
                .foregroundStyle(Palette.white)
            Text("Restart your iPhone or free up some storage, then try again.")
                .capsRelative(11, tracking: 0.12)
                .lineSpacing(4)
                .foregroundStyle(Palette.dimText)
            Button(action: retry) {
                Text("Try again")
                    .capsRelative(11, medium: true)
                    .foregroundStyle(Palette.charcoal)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Palette.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 35)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Palette.charcoal.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
