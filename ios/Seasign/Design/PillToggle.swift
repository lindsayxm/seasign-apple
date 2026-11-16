import SwiftUI

/// A two-sided pill switch with both labels always visible ("Use My List" |
/// "Let AI Search"); the chosen side is filled.
///
/// To VoiceOver it is one control: its label, the chosen side as its value,
/// double-tap to switch sides and swipe up or down to adjust. It follows
/// Dynamic Type, and at accessibility sizes the two sides stack.
struct PillToggle: View {
    var label: String
    var left: String
    var right: String
    /// True when the right side is chosen.
    var isRight: Bool
    /// Asked to choose a side; the owner decides whether it moves.
    var choose: (Bool) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            segment(left, selected: !isRight) { choose(false) }
            segment(right, selected: isRight) { choose(true) }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: typeSize.isAccessibilitySize ? 24 : 40, style: .continuous)
                .strokeBorder(Palette.rule, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isRight ? right : left)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to switch")
        .accessibilityAction { choose(!isRight) }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: choose(true)
            case .decrement: choose(false)
            @unknown default: break
            }
        }
    }

    private func segment(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: text)
                .capsRelative(10.5, medium: selected, tracking: 0.12)
                .foregroundStyle(selected ? Palette.charcoal : Palette.dimText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    Capsule().fill(selected ? Palette.white : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
