import SwiftUI

/// The column to the right of the date on Today: the next events, time first
/// and then the title in caps (`ref-img/00-button-meanings.png`).
///
/// How it shares the space with the "set your zip" prompt: events come first.
/// With no events the prompt stands alone; with events it sits under them when
/// there is room and is left out when there is not. If three events do not fit
/// (long titles take two lines each), two or one are shown.
struct EventsColumn: View {
    var labels: [EventLabel]
    /// Scale of the Today layout (1 on a 393 pt wide screen).
    var s: CGFloat
    var width: CGFloat
    /// Set while no zip is saved; opens Settings.
    var zipPrompt: (() -> Void)?

    private var size: CGFloat { 9.5 * s }
    private static let timeTracking: CGFloat = 0.05
    private static let titleTracking: CGFloat = 0.11

    var body: some View {
        if labels.isEmpty {
            if let zipPrompt {
                prompt(zipPrompt)
            }
        } else {
            ViewThatFits(in: .vertical) {
                if let zipPrompt {
                    VStack(alignment: .leading, spacing: 8 * s) {
                        rows(labels.count)
                        prompt(zipPrompt)
                    }
                }
                ForEach(Array(stride(from: labels.count, through: 1, by: -1)), id: \.self) { count in
                    rows(count)
                }
            }
        }
    }

    private func rows(_ count: Int) -> some View {
        let shown = Array(labels.prefix(count))
        // One time column for all rows, as wide as the widest time.
        let timeWidth = shown
            .map { CapsWrapper.width(of: $0.time, size: size, tracking: Self.timeTracking, medium: true) }
            .max() ?? 0
        return VStack(alignment: .leading, spacing: 9 * s) {
            // By position: two identical events would share an id.
            ForEach(Array(shown.enumerated()), id: \.offset) { _, label in
                HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                    Text(label.time)
                        .caps(size, medium: true, tracking: Self.timeTracking)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: ceil(timeWidth) + 1, alignment: .leading)
                    Text(label.title.uppercased())
                        .caps(size, medium: true, tracking: Self.titleTracking)
                        .lineSpacing(2 * s)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.white)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label.spoken)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func prompt(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: "Set your zip code in Settings")
                .caps(9.5, tracking: 0.18)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(Palette.dimText)
                .frame(minHeight: 44, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }
}
