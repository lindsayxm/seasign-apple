import SwiftUI

/// A two-sided switch with both labels always visible ("Use My List" |
/// "Let AI Search"); the chosen side is filled with the HUD accent, the
/// whole outlined in it (design v12, task 195).
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
    @Environment(\.hudAccent) private var accent

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            segment(left, selected: !isRight) { choose(false) }
            segment(right, selected: isRight) { choose(true) }
        }
        .padding(4)
        .background(HUDShape.rect.strokeBorder(accent, lineWidth: HUDShape.line))
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
                .hudText(.chip)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Palette.onAccent : Palette.dimText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: max(HUDShape.radius - 2, 1)).fill(selected ? accent : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
