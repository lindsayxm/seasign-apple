import SwiftUI

/// The line icons from the mockups, drawn as paths in a unit square and stroked
/// with round caps. See `ref-img/00-button-meanings.png` for what each one opens.
enum LineIcon: CaseIterable {
    /// A vertical stroke through a "Z": opens Settings.
    case settings
    /// A ring on a horizontal line between two arcs: opens the Do/Get list.
    case doGet
    /// An eight-armed asterisk: opens Saved.
    case saved
    /// `>>`: opens the 7-day history.
    case history

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }
        var path = Path()
        switch self {
        case .settings:
            path.move(to: point(0.5, 0.0))
            path.addLine(to: point(0.5, 1.0))
            path.move(to: point(0.02, 0.31))
            path.addLine(to: point(0.98, 0.31))
            path.addLine(to: point(0.02, 0.69))
            path.addLine(to: point(0.98, 0.69))
        case .doGet:
            let center = point(0.5, 0.5)
            path.addEllipse(in: CGRect(
                x: center.x - 0.29 * side, y: center.y - 0.29 * side,
                width: 0.58 * side, height: 0.58 * side
            ))
            path.move(to: point(0.0, 0.5))
            path.addLine(to: point(1.0, 0.5))
            path.move(to: point(0.5 + 0.5 * cos(.pi * 50 / 180), 0.5 - 0.5 * sin(.pi * 50 / 180)))
            path.addArc(
                center: center, radius: 0.5 * side,
                startAngle: .degrees(-50), endAngle: .degrees(50), clockwise: false
            )
            path.move(to: point(0.5 - 0.5 * cos(.pi * 50 / 180), 0.5 + 0.5 * sin(.pi * 50 / 180)))
            path.addArc(
                center: center, radius: 0.5 * side,
                startAngle: .degrees(130), endAngle: .degrees(230), clockwise: false
            )
        case .saved:
            let diagonal: CGFloat = 0.5 * 0.86 * 0.7071
            path.move(to: point(0.5, 0.0))
            path.addLine(to: point(0.5, 1.0))
            path.move(to: point(0.0, 0.5))
            path.addLine(to: point(1.0, 0.5))
            path.move(to: point(0.5 - diagonal, 0.5 - diagonal))
            path.addLine(to: point(0.5 + diagonal, 0.5 + diagonal))
            path.move(to: point(0.5 + diagonal, 0.5 - diagonal))
            path.addLine(to: point(0.5 - diagonal, 0.5 + diagonal))
        case .history:
            path.move(to: point(0.02, 0.1))
            path.addLine(to: point(0.42, 0.5))
            path.addLine(to: point(0.02, 0.9))
            path.move(to: point(0.52, 0.1))
            path.addLine(to: point(0.92, 0.5))
            path.addLine(to: point(0.52, 0.9))
        }
        return path
    }
}

/// One of the line icons, stroked in the current foreground style.
struct LineIconView: View {
    var icon: LineIcon
    var size: CGFloat = 19
    var lineWidth: CGFloat = 1.6

    var body: some View {
        IconShape(icon: icon)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct IconShape: Shape {
        var icon: LineIcon
        func path(in rect: CGRect) -> Path { icon.path(in: rect) }
    }
}
