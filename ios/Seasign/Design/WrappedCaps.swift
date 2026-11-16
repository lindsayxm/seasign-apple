import SwiftUI
import UIKit

/// Letter-spaced capitals set on a tight, exact line pitch, as the headlines in
/// the mockups are (11 pt type on 14.5 pt lines).
///
/// SwiftUI's `Text` cannot set lines closer than the font's own line height on
/// iOS 18, so this view breaks the text into lines itself and stacks one
/// single-line `Text` per line.
struct WrappedCaps: View {
    var text: String
    var size: CGFloat
    /// Extra space between letters, as a fraction of the font size.
    var tracking: CGFloat = 0.2
    /// Distance from one baseline to the next.
    var linePitch: CGFloat
    var width: CGFloat
    var maxLines = 2

    var body: some View {
        let lines = CapsWrapper.wrap(text.uppercased(), width: width, maxLines: maxLines) { line in
            CapsWrapper.width(of: line, size: size, tracking: tracking)
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                // Verbatim: headlines come from websites and are never read as markup.
                Text(verbatim: line)
                    .caps(size, tracking: tracking)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: linePitch)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// Greedy line breaking for `WrappedCaps`, separate from the view so it can be tested.
enum CapsWrapper {
    /// Breaks `text` at spaces into at most `maxLines` lines no wider than
    /// `width`, as measured by `measure`. Text that does not fit ends in "…".
    /// A single word wider than the line is kept whole on its own line.
    static func wrap(
        _ text: String,
        width: CGFloat,
        maxLines: Int,
        measure: (String) -> CGFloat
    ) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard maxLines > 0, !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""
        var index = 0
        while index < words.count {
            let word = words[index]
            let candidate = current.isEmpty ? word : current + " " + word
            if current.isEmpty || measure(candidate) <= width {
                current = candidate
                index += 1
            } else if lines.count == maxLines - 1 {
                break
            } else {
                lines.append(current)
                current = ""
            }
        }
        if index < words.count {
            // Out of lines with words left over: end the last line in an ellipsis.
            var kept = current.split(separator: " ").map(String.init)
            while kept.count > 1, measure(kept.joined(separator: " ") + "…") > width {
                kept.removeLast()
            }
            current = kept.joined(separator: " ") + "…"
        }
        lines.append(current)
        return lines
    }

    /// Width of one line of Jost Book (or Medium) at `size` with the given tracking.
    static func width(of line: String, size: CGFloat, tracking: CGFloat, medium: Bool = false) -> CGFloat {
        let font = UIFont(name: medium ? FontName.capsMedium : FontName.caps, size: size) ?? .systemFont(ofSize: size)
        let kern = size * tracking
        let measured = NSAttributedString(string: line, attributes: [.font: font, .kern: kern]).size().width
        // The kern after the last letter takes no visible space.
        return max(0, measured - kern)
    }
}
