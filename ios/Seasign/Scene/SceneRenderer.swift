import SwiftUI

/// Where things sit in the scene for a given screen size. Measured from the
/// mockups, which are 393 pt wide; everything scales with the width.
struct SceneLayout: Equatable, Sendable {
    var size: CGSize

    /// Points per mockup point.
    var scale: CGFloat { size.width / 393 }
    /// The waterline. Sky above, water below.
    var horizonY: CGFloat { size.height * 0.507 }
    /// How far above the horizon a body's centre is at the top of its arc.
    var peakRise: CGFloat { 194 * scale }

    var skyRect: CGRect { CGRect(x: 0, y: 0, width: size.width, height: horizonY) }
    var waterRect: CGRect {
        CGRect(x: 0, y: horizonY, width: size.width, height: size.height - horizonY)
    }

    /// Centre of the sun or moon at `progress` along its arc.
    func bodyCenter(progress: Double) -> CGPoint {
        CGPoint(
            x: size.width * SkyArc.horizontal(progress: progress),
            y: horizonY - peakRise * SkyArc.altitude(progress: progress)
        )
    }

    /// The sun is large on the horizon (141 pt radius in the mockups) and small
    /// at midday (29.5 pt).
    func sunRadius(progress: Double) -> CGFloat {
        let shrink = SkyArc.shrink(altitude: SkyArc.altitude(progress: progress))
        return (141 + (29.5 - 141) * shrink) * scale
    }

    var moonRadius: CGFloat { 24 * scale }
}

/// Draws the scene for one `SceneState` into a `Canvas`. Holds only values, so
/// the Canvas closure captures no observable object.
struct SceneRenderer: Sendable {
    var state: SceneState
    /// Seconds of animation time; 0 for a still scene (Reduce Motion).
    var phase: Double

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let layout = SceneLayout(size: size)

        context.fill(Path(layout.skyRect), with: .color(Palette.charcoal))

        var sky = context
        sky.clip(to: Path(layout.skyRect))
        if state.showsStars { drawStars(in: &sky, layout: layout) }
        drawSunOrMoon(in: &sky, layout: layout)
        drawClouds(in: &sky, layout: layout)

        context.fill(Path(layout.waterRect), with: .color(Palette.dayWater))
        if state.nightness > 0 {
            context.fill(
                Path(layout.waterRect),
                with: .color(Palette.nightWater.opacity(state.nightness))
            )
        }
        drawReflection(in: &context, layout: layout)
        if state.wind != .calm { drawWaterDashes(in: &context, layout: layout) }
        drawPrecipitation(in: &context, layout: layout)
    }

    // MARK: Sun and moon

    private func drawSunOrMoon(in context: inout GraphicsContext, layout: SceneLayout) {
        if let progress = state.sun.progress {
            let center = layout.bodyCenter(progress: progress)
            let radius = layout.sunRadius(progress: progress)
            context.fill(Path(circleAt: center, radius: radius), with: .color(Palette.sun))
        } else if state.showsMoon, let progress = state.moon.progress {
            let center = layout.bodyCenter(progress: progress)
            let radius = layout.moonRadius
            context.fill(Path(circleAt: center, radius: radius), with: .color(Palette.moonShadow))
            context.fill(
                Self.litMoonPath(phase: state.moonPhase, center: center, radius: radius),
                with: .color(Palette.white)
            )
        }
    }

    /// The lit part of the moon: the limb on the lit side, closed by the
    /// terminator, which is half an ellipse whose width follows the phase.
    static func litMoonPath(phase: MoonPhase, center: CGPoint, radius: CGFloat) -> Path {
        // +1 draws the lit limb on the right (waxing), -1 on the left (waning).
        let side: CGFloat = phase.isWaxing ? 1 : -1
        let terminator = CGFloat(phase.terminator)
        let steps = 48
        var path = Path()
        // Down the lit limb, top to bottom.
        for step in 0...steps {
            let angle = -CGFloat.pi / 2 + CGFloat.pi * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: center.x + side * radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        // Back up the terminator, bottom to top.
        for step in 0...steps {
            let angle = CGFloat.pi / 2 - CGFloat.pi * CGFloat(step) / CGFloat(steps)
            path.addLine(to: CGPoint(
                x: center.x + side * radius * terminator * cos(angle),
                y: center.y + radius * sin(angle)
            ))
        }
        path.closeSubpath()
        return path
    }

    // MARK: Reflection

    private func drawReflection(in context: inout GraphicsContext, layout: SceneLayout) {
        let x: CGFloat
        let radius: CGFloat
        let color: Color
        let strength: Double
        if let progress = state.sun.progress {
            x = layout.bodyCenter(progress: progress).x
            radius = layout.sunRadius(progress: progress)
            color = Palette.sun
            // Nearly solid when the sun sits on the water, a soft glow at midday.
            strength = 0.96 - 0.4 * SkyArc.shrink(altitude: SkyArc.altitude(progress: progress))
        } else if state.showsMoon, let progress = state.moon.progress {
            x = layout.bodyCenter(progress: progress).x
            radius = layout.moonRadius
            color = Palette.white
            strength = 0.55 * max(0.25, state.moonPhase.illuminatedFraction)
        } else {
            return
        }
        let center = CGPoint(x: x, y: layout.horizonY)

        if state.wind == .calm {
            // A soft blurred disc centred on the waterline; only its lower half
            // shows, in the water.
            context.drawLayer { layer in
                layer.clip(to: Path(layout.waterRect))
                layer.opacity = strength
                layer.addFilter(.blur(radius: max(4, radius * 0.24)))
                layer.fill(Path(circleAt: center, radius: radius * 1.06), with: .color(color))
            }
        } else {
            // Wind breaks the reflection into horizontal streaks.
            var random = SeededRandom(seed: 0x5EA5)
            let scale = layout.scale
            let count = 18
            let depth = max(34 * scale, radius * 0.9)
            let reach = max(radius, 28 * scale)
            for index in 0..<count {
                let t = CGFloat(index) / CGFloat(count - 1)
                let width = reach * CGFloat(random.next(in: 1.0...2.5)) * (1 - 0.35 * t)
                let jitter = reach * CGFloat(random.next(in: -0.45...0.45))
                let sway = CGFloat(sin(phase * 1.1 + Double(index) * 1.7)) * 3 * scale
                let rect = CGRect(
                    x: center.x + jitter + sway - width / 2,
                    y: center.y + 1.5 * scale + t * depth,
                    width: width,
                    height: 2.8 * scale
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: rect.height / 2),
                    with: .color(color.opacity(min(1, strength * (0.85 - 0.4 * Double(t)))))
                )
            }
        }
    }

    // MARK: Stars

    private func drawStars(in context: inout GraphicsContext, layout: SceneLayout) {
        var random = SeededRandom(seed: 0x57A125)
        // Cloud dims the stars; overcast nearly hides them.
        let visibility: Double =
            switch state.clouds {
            case .clear, .few: 1
            case .scattered: 0.6
            case .overcast: 0.22
            }
        let scale = layout.scale
        for index in 0..<84 {
            let x = CGFloat(random.next(in: 0...1)) * layout.size.width
            let y = CGFloat(random.next(in: 0...1)) * (layout.horizonY - 6 * scale)
            let big = random.next(in: 0...1) > 0.8
            let side = (big ? 1.9 : CGFloat(random.next(in: 0.7...1.2))) * scale
            let base = random.next(in: 0.35...0.9)
            let twinkle = phase == 0 ? 1 : 0.8 + 0.2 * sin(phase * 0.9 + Double(index) * 2.3)
            let rect = CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
            context.fill(
                big ? Path(ellipseIn: rect) : Path(rect),
                with: .color(Palette.white.opacity(base * twinkle * visibility * state.nightness))
            )
        }
    }

    // MARK: Clouds

    /// One flat cloud: a wide pill with one taller rounded bump. Coordinates are
    /// mockup pixels (1179 wide, horizon at 1296), from `ref-img/10-cloudy-day.png`.
    private struct CloudShape {
        var base: (x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat)
        var bump: (x0: CGFloat, x1: CGFloat, top: CGFloat)
    }

    private static let cloudShapes: [CloudShape] = [
        CloudShape(base: (-60, 650, 723, 812), bump: (99, 423, 666)),
        CloudShape(base: (560, 1250, 340, 458), bump: (560, 942, 267)),
        CloudShape(base: (5, 403, 233, 288), bump: (92, 278, 201)),
        CloudShape(base: (-60, 517, 1029, 1136), bump: (-60, 265, 963)),
        CloudShape(base: (130, 895, 402, 521), bump: (375, 652, 327)),
        CloudShape(base: (847, 1250, 840, 908), bump: (955, 1250, 798)),
        CloudShape(base: (927, 1250, 435, 512), bump: (1062, 1250, 387)),
    ]

    private func drawClouds(in context: inout GraphicsContext, layout: SceneLayout) {
        let count: Int =
            switch state.clouds {
            case .clear: 0
            case .few: 2
            case .scattered: 4
            case .overcast: Self.cloudShapes.count
            }
        guard count > 0 else { return }
        let unit = layout.size.width / 1179
        let vertical = layout.horizonY / 1296
        let drift: Double = state.wind == .calm ? 6 : 14
        for (index, shape) in Self.cloudShapes.prefix(count).enumerated() {
            let offset = CGFloat(sin(phase / 9 + Double(index) * 1.3) * drift) * layout.scale
            let base = CGRect(
                x: shape.base.x0 * unit + offset,
                y: shape.base.y0 * vertical,
                width: (shape.base.x1 - shape.base.x0) * unit,
                height: (shape.base.y1 - shape.base.y0) * vertical
            )
            let bump = CGRect(
                x: shape.bump.x0 * unit + offset,
                y: shape.bump.top * vertical,
                width: (shape.bump.x1 - shape.bump.x0) * unit,
                height: base.midY - shape.bump.top * vertical
            )
            var path = Path(roundedRect: base, cornerRadius: base.height / 2)
            // The bump's corners are as round as it is tall above the pill.
            let radius = min(bump.width / 2, max(0, base.minY - bump.minY))
            path.addRoundedRect(
                in: bump,
                cornerRadii: RectangleCornerRadii(topLeading: radius, topTrailing: radius)
            )
            // Over the sky a cloud is a slightly lighter charcoal; over the sun
            // or moon it dims what is behind it. Charcoal first, then a white veil.
            context.fill(path, with: .color(Palette.charcoal.opacity(0.44)))
            context.fill(path, with: .color(Palette.white.opacity(0.06)))
        }
    }

    // MARK: Wind on the water

    private func drawWaterDashes(in context: inout GraphicsContext, layout: SceneLayout) {
        let scale = layout.scale
        let rowHeight = 11.4 * scale
        let period = 71.7 * scale
        let length = 12.5 * scale
        // Rows are staggered the way the mockup staggers them.
        let stagger: [CGFloat] = [0.74, 0.09, 0.74, 0.5, 0.24, 0.9, 0.4]
        let speed: Double = state.wind == .gale ? 16 : 8
        var path = Path()
        var row = 0
        var y = layout.horizonY + 7 * scale
        while y < layout.size.height {
            let travel = CGFloat(phase * speed * (row.isMultiple(of: 2) ? 1 : 0.7)) * scale
            let start = (stagger[row % stagger.count] * period + travel)
                .truncatingRemainder(dividingBy: period) - period
            var x = start
            while x < layout.size.width {
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + length, y: y))
                x += period
            }
            y += rowHeight
            row += 1
        }
        context.stroke(path, with: .color(.black.opacity(0.1)), lineWidth: 1.1 * scale)
    }

    // MARK: Rain and snow

    private func drawPrecipitation(in context: inout GraphicsContext, layout: SceneLayout) {
        let scale = layout.scale
        let size = layout.size
        switch state.precipitation {
        case .none:
            return
        case .rain(let intensity):
            var random = SeededRandom(seed: 0x12A1)
            let count = [70, 110, 160][intensity.rawValue - 1]
            let slant = (state.wind == .calm ? -2.5 : -6) * scale
            let length = 10 * scale
            var overSky = Path()
            var overWater = Path()
            for _ in 0..<count {
                let x0 = random.next(in: 0...1)
                let y0 = random.next(in: 0...1)
                let speed = random.next(in: 0.75...1.15)
                let fall = (y0 + phase * speed).truncatingRemainder(dividingBy: 1)
                let y = CGFloat(fall) * (size.height + length) - length
                let x = CGFloat(x0) * (size.width + 30 * scale) + slant * CGFloat(fall) * 8
                let top = CGPoint(x: x, y: y)
                let bottom = CGPoint(x: x + slant, y: y + length)
                if bottom.y < layout.horizonY {
                    overSky.move(to: top)
                    overSky.addLine(to: bottom)
                } else if top.y > layout.horizonY {
                    overWater.move(to: top)
                    overWater.addLine(to: bottom)
                }
            }
            let style = StrokeStyle(lineWidth: 1.1 * scale, lineCap: .round)
            context.stroke(overSky, with: .color(Palette.white.opacity(0.3)), style: style)
            context.stroke(overWater, with: .color(Palette.ink.opacity(0.16)), style: style)
        case .snow(let intensity):
            var random = SeededRandom(seed: 0x5109)
            let count = [60, 95, 140][intensity.rawValue - 1]
            for index in 0..<count {
                let x0 = random.next(in: 0...1)
                let y0 = random.next(in: 0...1)
                let speed = random.next(in: 0.035...0.07)
                let radius = CGFloat(random.next(in: 0.9...2.1)) * scale
                let fall = (y0 + phase * speed).truncatingRemainder(dividingBy: 1)
                let sway = CGFloat(sin(phase * 0.7 + Double(index))) * 5 * scale
                let center = CGPoint(
                    x: CGFloat(x0) * size.width + sway,
                    y: CGFloat(fall) * (size.height + 8) - 4
                )
                let opacity = center.y < layout.horizonY ? 0.75 : 0.9
                context.fill(
                    Path(circleAt: center, radius: radius),
                    with: .color(Palette.white.opacity(opacity))
                )
            }
        }
    }
}

extension Path {
    init(circleAt center: CGPoint, radius: CGFloat) {
        self.init(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
}

/// A small deterministic generator (SplitMix64), so stars and raindrops sit in
/// the same places on every frame and every launch.
struct SeededRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value spread evenly over `range`.
    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
