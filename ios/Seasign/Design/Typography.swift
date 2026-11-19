import SwiftUI
import UIKit

/// The bundled fonts, by PostScript name. The files and their OFL licences are in
/// `Seasign/Resources/Fonts`; `ios/project.yml` lists them under `UIAppFonts`.
/// A wrong name falls back to the system font without an error, so
/// `DesignTests` checks that each of these loads.
enum FontName {
    /// Jost Book (400): headlines and other letter-spaced caps.
    static let caps = "Jost-Book"
    /// Jost Medium (500): date number, temperature, emphasised caps.
    static let capsMedium = "Jost-Medium"
    /// PT Sans Narrow Bold: the day name.
    static let dayName = "PTSans-NarrowBold"

    static let all = [caps, capsMedium, dayName]

    /// Avenir Next Condensed Regular, which ships with iOS: the day name on
    /// Today (design v11).
    static let todayDayName = "AvenirNextCondensed-Regular"
    /// Iowan Old Style Roman, which ships with iOS: the article titles on
    /// Today (design v11).
    static let todayTitle = "IowanOldStyle-Roman"

    /// Faces the app uses from iOS itself rather than bundling. `DesignTests`
    /// checks they resolve on each runtime.
    static let system = [todayDayName, todayTitle]
}

/// The type of Today's fixed overlay (design v11), as UIFonts so the same
/// font is measured for layout and drawn. Sizes are in screen points.
enum TodayType {
    /// Jost Book: the date, temperature and event titles.
    static func jost(_ size: CGFloat) -> UIFont {
        UIFont(name: FontName.caps, size: size) ?? .systemFont(ofSize: size)
    }

    /// The system monospaced face (SF Mono): event times, the wind line and
    /// the title numbers, like the scene's rise and set marks.
    static func mono(_ size: CGFloat) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func dayName(_ size: CGFloat) -> UIFont {
        UIFont(name: FontName.todayDayName, size: size) ?? .systemFont(ofSize: size)
    }

    static func title(_ size: CGFloat) -> UIFont {
        UIFont(name: FontName.todayTitle, size: size) ?? .systemFont(ofSize: size)
    }

    /// Width of `text` set in `font` with `tracking` (a fraction of the
    /// size), without the letter-space after the last letter.
    static func width(_ text: String, font: UIFont, tracking: CGFloat) -> CGFloat {
        let kern = font.pointSize * tracking
        let measured = NSAttributedString(string: text, attributes: [.font: font, .kern: kern]).size().width
        return max(0, measured - kern)
    }

    /// Where the baseline sits in a line box of `lineHeight`, the way CSS
    /// places it: the font's ascent and descent centred in the box.
    static func baseline(in lineHeight: CGFloat, font: UIFont) -> CGFloat {
        (lineHeight - (font.ascender - font.descender)) / 2 + font.ascender
    }
}

extension Text {
    /// A verbatim string in one of `TodayType`'s fonts with `tracking` (a
    /// fraction of the size).
    init(today string: String, font: UIFont, tracking: CGFloat) {
        self = Text(verbatim: string)
            .font(Font(font as CTFont))
            .tracking(font.pointSize * tracking)
    }
}

extension Font {
    /// Jost at a fixed size. Today is a fixed, non-scrolling composition, so its
    /// type does not follow Dynamic Type; screens that scroll use `capsRelative`.
    static func caps(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? FontName.capsMedium : FontName.caps, fixedSize: size)
    }

    /// Jost that scales with Dynamic Type, for screens that can scroll.
    static func capsRelative(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? FontName.capsMedium : FontName.caps, size: size, relativeTo: .body)
    }

    /// The condensed bold face of the day name.
    static func dayName(_ size: CGFloat) -> Font {
        .custom(FontName.dayName, fixedSize: size)
    }
}

extension Text {
    /// Text shown in capitals and spoken as it was written.
    ///
    /// The capitals are made in the string, with the original kept as the
    /// accessibility label. `textCase(.uppercase)` is not used anywhere: it
    /// also capitalises accessibility labels, including explicit ones on an
    /// enclosing button, and VoiceOver may then spell a word out ("C-L-O-S-E").
    ///
    /// The string is taken verbatim, never as Markdown or a localization key,
    /// so it is safe for text that came from a website.
    init(caps string: String) {
        self = Text(verbatim: string.uppercased()).accessibilityLabel(Text(verbatim: string))
    }
}

/// The type of the app's text voice, letter-spaced Jost ("A SHORT EXPLAINER
/// ON …"). It sets the font and spacing only; the capitals come from
/// `Text(caps:)`.
struct CapsStyle: ViewModifier {
    var size: CGFloat
    var medium = false
    /// Extra space between letters, as a fraction of the font size.
    var tracking: CGFloat = 0.2
    var scales = false

    func body(content: Content) -> some View {
        content
            .font(scales ? .capsRelative(size, medium: medium) : .caps(size, medium: medium))
            .tracking(size * tracking)
    }
}

extension View {
    /// Letter-spaced Jost at a fixed size, for `Text(caps:)`.
    func caps(_ size: CGFloat, medium: Bool = false, tracking: CGFloat = 0.2) -> some View {
        modifier(CapsStyle(size: size, medium: medium, tracking: tracking))
    }

    /// Letter-spaced Jost that follows Dynamic Type, for `Text(caps:)`.
    func capsRelative(_ size: CGFloat, medium: Bool = false, tracking: CGFloat = 0.2) -> some View {
        modifier(CapsStyle(size: size, medium: medium, tracking: tracking, scales: true))
    }
}

/// White display text with its corners rounded off, the way the day name is
/// drawn in the mockups (PT Sans Narrow Bold with soft terminals).
///
/// The glyphs are blurred slightly and then cut back to a hard edge, which
/// rounds corners without making the letters heavier. The hidden `Text` gives
/// the view its size and baseline.
struct SoftenedText: View {
    var text: String
    var font: Font
    /// Blur radius in points; about the radius of the rounded corners.
    var softness: CGFloat

    var body: some View {
        let label = Text(text).font(font)
        let margin = softness * 3
        label
            .fixedSize()
            .hidden()
            .overlay {
                Canvas { context, _ in
                    context.addFilter(.alphaThreshold(min: 0.5, color: Palette.white))
                    context.addFilter(.blur(radius: softness))
                    context.drawLayer { layer in
                        layer.draw(
                            layer.resolve(label.foregroundStyle(Palette.white)),
                            at: CGPoint(x: margin, y: margin),
                            anchor: .topLeading
                        )
                    }
                }
                .padding(-margin)
                .allowsHitTesting(false)
            }
    }
}
