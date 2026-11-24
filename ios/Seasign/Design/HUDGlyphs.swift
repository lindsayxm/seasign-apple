import SwiftUI

/// The line drawings of the v12 HUD (`design-ideas/v12-imago/index.html`),
/// each in its SVG `viewBox` units with the SVG's own stroke settings, so a
/// glyph drawn at its viewBox size matches the mockup point for point.
enum HUDGlyph: CaseIterable {
    /// The mark at the top left: a frame with rounded upper-left and
    /// lower-right corners, a middle line and the S curve (viewBox 28).
    case mark
    /// Settings: the app's settings symbol in the mark's frame (viewBox 28).
    case settings
    /// DAY: a square with a ring (18 × 18).
    case day
    /// LIST: a circle with a bar between two arcs (22 × 18).
    case list
    /// SAVE: an eight-point star (20 × 20).
    case save
    /// LISTEN: a wave on a dotted line (36 × 20).
    case listen

    /// The SVG's viewBox size.
    var viewBox: CGSize {
        switch self {
        case .mark, .settings: CGSize(width: 28, height: 28)
        case .day: CGSize(width: 18, height: 18)
        case .list: CGSize(width: 22, height: 18)
        case .save: CGSize(width: 20, height: 20)
        case .listen: CGSize(width: 36, height: 20)
        }
    }

    /// The size it is drawn at in the mockup: the mark and settings at 24,
    /// the tile icons at their viewBox size.
    var drawnSize: CGSize {
        switch self {
        case .mark, .settings: CGSize(width: 24, height: 24)
        default: viewBox
        }
    }

    /// One stroked part: a path in viewBox units and how it is stroked.
    struct Stroke {
        var path: Path
        var style: StrokeStyle
    }

    private static let round = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    private static let miter = StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .miter)

    var strokes: [Stroke] {
        switch self {
        case .mark:
            return [Stroke(path: Self.frame, style: Self.miter), Stroke(path: Self.markInside, style: Self.round)]
        case .settings:
            var inside = Path()
            inside.move(to: CGPoint(x: 14, y: 3.5))
            inside.addLine(to: CGPoint(x: 14, y: 24.5))
            inside.move(to: CGPoint(x: 4, y: 11.5))
            inside.addLine(to: CGPoint(x: 24, y: 11.5))
            inside.addLine(to: CGPoint(x: 4, y: 16.5))
            inside.addLine(to: CGPoint(x: 24, y: 16.5))
            return [Stroke(path: Self.frame, style: Self.miter), Stroke(path: inside, style: Self.round)]
        case .day:
            var path = Path(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), cornerRadius: 1)
            path.addEllipse(in: CGRect(x: 9 - 2.6, y: 9 - 2.6, width: 5.2, height: 5.2))
            return [Stroke(path: path, style: Self.round)]
        case .list:
            var path = Path(ellipseIn: CGRect(x: 11 - 5.2, y: 9 - 5.2, width: 10.4, height: 10.4))
            path.move(to: CGPoint(x: 3.5, y: 9))
            path.addLine(to: CGPoint(x: 18.5, y: 9))
            // `M4.6 2A9.6 9.6 0 0 0 4.6 16` and `M17.4 2A9.6 9.6 0 0 1 17.4 16`:
            // minor arcs of radius 9.6 over a 14-point chord, bulging out.
            let offset = (9.6 * 9.6 - 7 * 7).squareRoot()
            let angle = Angle(radians: atan2(7, offset))
            path.move(to: CGPoint(x: 4.6, y: 2))
            path.addArc(
                center: CGPoint(x: 4.6 + offset, y: 9), radius: 9.6,
                startAngle: .degrees(180) + angle, endAngle: .degrees(180) - angle, clockwise: true
            )
            path.move(to: CGPoint(x: 17.4, y: 2))
            path.addArc(
                center: CGPoint(x: 17.4 - offset, y: 9), radius: 9.6,
                startAngle: .zero - angle, endAngle: angle, clockwise: false
            )
            return [Stroke(path: path, style: Self.round)]
        case .save:
            var path = Path()
            for (from, to) in [((10.0, 1.0), (10.0, 19.0)), ((1, 10), (19, 10)), ((3.6, 3.6), (16.4, 16.4)), ((16.4, 3.6), (3.6, 16.4))] {
                path.move(to: CGPoint(x: from.0, y: from.1))
                path.addLine(to: CGPoint(x: to.0, y: to.1))
            }
            return [Stroke(path: path, style: Self.round)]
        case .listen:
            var dots = Path()
            dots.move(to: CGPoint(x: 1, y: 10))
            dots.addLine(to: CGPoint(x: 35, y: 10))
            var wave = Path()
            wave.move(to: CGPoint(x: 5, y: 10))
            wave.addCurve(to: CGPoint(x: 18, y: 10), control1: CGPoint(x: 8.5, y: -2), control2: CGPoint(x: 14.5, y: -2))
            wave.addCurve(to: CGPoint(x: 31, y: 10), control1: CGPoint(x: 21.5, y: 22), control2: CGPoint(x: 27.5, y: 22))
            return [
                Stroke(path: dots, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [0.1, 2])),
                Stroke(path: wave, style: Self.round),
            ]
        }
    }

    /// `M7 1H27V21A6 6 0 0 1 21 27H1V7A6 6 0 0 1 7 1Z`: rounded at the upper
    /// left and lower right. The day screen's mic and + sit in it too.
    static var frame: Path {
        var path = Path()
        path.move(to: CGPoint(x: 7, y: 1))
        path.addLine(to: CGPoint(x: 27, y: 1))
        path.addLine(to: CGPoint(x: 27, y: 21))
        path.addArc(center: CGPoint(x: 21, y: 21), radius: 6, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: 1, y: 27))
        path.addLine(to: CGPoint(x: 1, y: 7))
        path.addArc(center: CGPoint(x: 7, y: 7), radius: 6, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// `M1 14H27M14 1A6.5 6.5 0 0 0 14 14A6.5 6.5 0 0 1 14 27`: the middle
    /// line, and the S as two half circles, the upper bulging left and the
    /// lower right.
    private static var markInside: Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 14))
        path.addLine(to: CGPoint(x: 27, y: 14))
        path.move(to: CGPoint(x: 14, y: 1))
        path.addArc(center: CGPoint(x: 14, y: 7.5), radius: 6.5, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: true)
        path.addArc(center: CGPoint(x: 14, y: 20.5), radius: 6.5, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: false)
        return path
    }
}

/// A HUD glyph at its mockup size, stroked in `color`.
struct HUDGlyphView: View {
    var glyph: HUDGlyph
    var color: Color

    var body: some View {
        let size = glyph.drawnSize
        Canvas { context, _ in
            context.scaleBy(x: size.width / glyph.viewBox.width, y: size.height / glyph.viewBox.height)
            for stroke in glyph.strokes {
                context.stroke(stroke.path, with: .color(color), style: stroke.style)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
