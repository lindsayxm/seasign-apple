import SwiftUI

/// The visible "AI" mark on every AI-found item: Today's headlines, History
/// and Saved rows, and the reading view. It is hidden from VoiceOver because
/// the item's own label begins with "AI-found" (`AILabel.accessibility`).
struct AIMark: View {
    /// Point size of the letters.
    var size: CGFloat
    var color: Color
    /// Fixed size on Today (whose layout does not follow Dynamic Type),
    /// relative elsewhere.
    var fixed = false

    var body: some View {
        Text(verbatim: AILabel.mark)
            .font(fixed ? .caps(size, medium: true) : .capsRelative(size, medium: true))
            .tracking(size * 0.12)
            .foregroundStyle(color)
            .padding(.horizontal, size * 0.45)
            .padding(.vertical, size * 0.1)
            .overlay(Capsule().strokeBorder(color, lineWidth: max(0.8, size * 0.09)))
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// The mark's width on Today, for working out how much of the line the
    /// headline beside it may use. Measured the same way as the headline.
    static func fixedWidth(size: CGFloat) -> CGFloat {
        CapsWrapper.width(of: AILabel.mark, size: size, tracking: 0.12, medium: true) + size * 0.9
    }
}
