import SwiftUI

/// Where things sit in the scene for a given screen size. Measured in the v11
/// mockup's points (393 wide, `design-ideas/v11-artemis/`); everything scales
/// with the width, so the horizon and the path keep their place relative to
/// the header on every phone.
struct SceneLayout: Equatable, Sendable {
    var size: CGSize

    /// The mockup's width, in points.
    static let mockupWidth: CGFloat = 393
    /// The horizon in the mockup, in points from the top.
    static let mockupHorizon: CGFloat = 386

    /// Points per mockup point.
    var scale: CGFloat { size.width / Self.mockupWidth }
    /// The horizon: sky above, sea below. Task 146 hangs the article titles
    /// from it.
    var horizonY: CGFloat { Self.mockupHorizon * scale }
    /// The top of the first article title: 100 points under the horizon.
    var headlinesTop: CGFloat { horizonY + 100 * scale }
    /// The middle of the path, where it is centred.
    var centerX: CGFloat { size.width / 2 }

    var skyRect: CGRect { CGRect(x: 0, y: 0, width: size.width, height: horizonY) }

    /// A point on the path at `progress` (0 rising at x 62, 1 setting at x 331
    /// on a 393 pt screen), on the horizon at either end.
    func pathPoint(progress: Double) -> CGPoint {
        let offset = SkyPath.offset(progress: progress)
        return CGPoint(x: centerX + CGFloat(offset.x) * scale, y: horizonY - CGFloat(offset.height) * scale)
    }

    /// The body's radius at `progress`: 12 high in the sky, about 50 on the
    /// horizon (mockup points, scaled).
    func bodyRadius(progress: Double) -> CGFloat {
        CGFloat(SkyPath.bodyRadius(progress: progress)) * scale
    }

    /// Centre of a disc of `radius` at `placement`: on the path, lowered by
    /// the sunk share of its radius while it crosses the waterline.
    func bodyCenter(_ placement: SkyPlacement, radius: CGFloat) -> CGPoint {
        let onPath = pathPoint(progress: placement.progress)
        return CGPoint(x: onPath.x, y: onPath.y + radius * CGFloat(placement.sunk))
    }

    /// Where the drawn body is, in this layout.
    func drawnBody(_ body: SceneBody) -> DrawnBody {
        let progress = body.placement.progress
        let radius = bodyRadius(progress: progress)
        return DrawnBody(
            kind: body.kind,
            center: bodyCenter(body.placement, radius: radius),
            radius: radius,
            lowness: SkyPath.lowness(progress: progress),
            progress: progress
        )
    }

    /// The centre the weather gathers round with no body up: the top of the
    /// path.
    var pathTop: CGPoint { pathPoint(progress: 0.5) }

    /// Whether the dotted drop line shows: when the body's lower edge is more
    /// than 14 points above the horizon.
    func showsDropLine(_ body: DrawnBody) -> Bool {
        body.center.y + body.radius < horizonY - 14 * scale
    }
}

/// The sun or moon as placed in a layout.
struct DrawnBody: Equatable, Sendable {
    var kind: SceneBody.Kind
    var center: CGPoint
    var radius: CGFloat
    /// 1 on the horizon, 0 at the top of the path.
    var lowness: Double
    var progress: Double
}

/// Everything drawn from the sun, moon or horizon, resolved to positions and
/// text so the renderer only draws. Built by `SceneMarks.init`, which holds
/// the rules (see the plan's "Marks" section).
struct SceneMarks: Equatable, Sendable {
    struct Tick: Equatable, Sendable {
        var x: CGFloat
        /// The two end ticks are longer and brighter.
        var isEnd: Bool
    }

    struct Label: Equatable, Sendable {
        /// Centre of the text.
        var center: CGPoint
        var text: String
    }

    struct Tag: Equatable, Sendable {
        var title: String
        var wind: String?
        /// The text's outer top corner: its top-left, or its top-right when
        /// `flipped` (a setting body, whose tag stands to its left).
        var corner: CGPoint
        var flipped: Bool
        /// The bent leader from the body up and out to the tag.
        var leader: [CGPoint]
    }

    var ticks: [Tick] = []
    var riseTime: Label?
    var setTime: Label?
    /// The 4 x 4 square on the horizon under the body.
    var square: CGRect?
    /// The dotted drop line from just under the body to the horizon.
    var dropLine: DropLine?
    var tag: Tag?

    struct DropLine: Equatable, Sendable {
        var x: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    init(state: SceneState, layout: SceneLayout, clock: ClockStyle) {
        guard let sceneBody = state.body else { return }
        let body = layout.drawnBody(sceneBody)
        let s = layout.scale
        let horizon = layout.horizonY
        let pass = state.markedPass

        // One tick an hour between the rise and set points; with the span
        // unknown, only the known ends.
        if let count = state.tickCount {
            ticks = (0...count).map { index in
                Tick(
                    x: layout.pathPoint(progress: Double(index) / Double(count)).x,
                    isEnd: index == 0 || index == count
                )
            }
        } else {
            if pass.rise != nil { ticks.append(Tick(x: layout.pathPoint(progress: 0).x, isEnd: true)) }
            if pass.set != nil { ticks.append(Tick(x: layout.pathPoint(progress: 1).x, isEnd: true)) }
        }

        // Times centred under the end ticks, the middle of the text 18 points
        // under the horizon (the mockup's 10 pt line, 13 points down).
        if let rise = state.riseMark {
            riseTime = Label(
                center: CGPoint(x: layout.pathPoint(progress: 0).x, y: horizon + 18 * s),
                text: SceneState.markTime(rise, timeZone: state.timeZone, clock: clock)
            )
        }
        if let set = state.setMark {
            setTime = Label(
                center: CGPoint(x: layout.pathPoint(progress: 1).x, y: horizon + 18 * s),
                text: SceneState.markTime(set, timeZone: state.timeZone, clock: clock)
            )
        }

        if state.showsSquare {
            square = CGRect(x: body.center.x - 2 * s, y: horizon + 1.5 * s, width: 4 * s, height: 4 * s)
        }

        // `reach` is the mockup's `hb`: the body's radius and 8 points.
        let reach = body.radius + 8 * s
        if layout.showsDropLine(body) {
            dropLine = DropLine(x: body.center.x, top: body.center.y + reach + 3 * s, bottom: horizon - 1 * s)
        }

        if let lines = state.tagLines(clock: clock) {
            // To the right of a body at the left of the path, to the left of
            // one at the right.
            let flip: CGFloat = body.center.x > layout.centerX + 1 * s ? -1 : 1
            let lx = body.center.x + flip * reach
            let ly = body.center.y - reach
            tag = Tag(
                title: lines.title,
                wind: lines.wind,
                corner: CGPoint(x: body.center.x + flip * (reach + 23 * s), y: ly - 20 * s),
                flipped: flip < 0,
                leader: [
                    CGPoint(x: lx + flip * 3 * s, y: ly - 3 * s),
                    CGPoint(x: lx + flip * 11 * s, y: ly - 11 * s),
                    CGPoint(x: lx + flip * 19 * s, y: ly - 11 * s),
                ]
            )
        }
    }
}

extension SceneRGB {
    var color: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }

    func color(_ opacity: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: min(1, max(0, opacity)))
    }
}

extension SceneState {
    /// The ink colour as a SwiftUI colour, for the overlay (task 146).
    var inkColor: Color { ink.color }
}
