import SwiftUI

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

/// Letter-spaced capitals, the app's text voice ("A SHORT EXPLAINER ON …").
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
            .textCase(.uppercase)
    }
}

extension View {
    /// Letter-spaced capitals in Jost at a fixed size.
    func caps(_ size: CGFloat, medium: Bool = false, tracking: CGFloat = 0.2) -> some View {
        modifier(CapsStyle(size: size, medium: medium, tracking: tracking))
    }

    /// Letter-spaced capitals in Jost that follow Dynamic Type.
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
