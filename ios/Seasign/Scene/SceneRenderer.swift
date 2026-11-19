import SwiftUI

/// Draws the v11 scene for one `SceneState` into a `Canvas`, after `draw(t)` in
/// `design-ideas/v11-artemis/index.html`. It holds only values and makes no
/// decisions: what shows comes from `SceneState` and `SceneMarks`; the colours,
/// alphas and speeds here are the mockup's.
///
/// Everything is drawn in mockup points (393 wide, horizon at 386) under one
/// scale transform, so the numbers read as they do in the mockup.
struct SceneRenderer: Sendable {
    var state: SceneState
    var clock: ClockStyle
    /// Seconds of animation time. The still frame (Reduce Motion) uses
    /// `stillTime`, the time the mockup's stills were rendered at.
    var time: Double
    var grain: Image
    /// The moon's lit face for the state's phase (`SceneImages.moonFace`).
    var moonFace: Image?

    static let stillTime = 19.0

    /// The bloom's gain on the light layer.
    private static let bloomGain: ColorMatrix = {
        var matrix = ColorMatrix()
        matrix.r1 = 1.56
        matrix.g2 = 1.56
        matrix.b3 = 1.56
        return matrix
    }()

    // The mockup's fixed colours.
    private static let silver = SceneRGB(214, 228, 240)
    private static let ice = SceneRGB(150, 200, 222)
    private static let violet = SceneRGB(196, 150, 255)
    private static let white = SceneRGB(255, 255, 255)
    private static let mist = SceneRGB(70, 96, 120)
    /// Fine, sharp light (stars, glints, rain, snow) is drawn inside the
    /// brightened layer but the mockup's blur spreads it rather than
    /// brightening it, so it is drawn this much fainter.
    private static let sharp = 0.68

    /// The mockup's `LOOK` table: the body's colour, the light round it, the
    /// tint of its light on the water, and the overall brightness.
    private struct Paint {
        var body: SceneRGB
        var halo: SceneRGB
        var tint: SceneRGB
        var power: Double

        init(_ look: SceneLook) {
            switch look {
            case .sunrise: (body, halo, tint, power) = (SceneRGB(255, 150, 70), SceneRGB(255, 176, 84), SceneRGB(255, 196, 150), 0.75)
            case .day: (body, halo, tint, power) = (SceneRGB(255, 196, 96), SceneRGB(255, 224, 130), SceneRGB(255, 250, 232), 1)
            case .sunset: (body, halo, tint, power) = (SceneRGB(255, 128, 64), SceneRGB(255, 150, 70), SceneRGB(255, 180, 140), 0.8)
            case .cloudy: (body, halo, tint, power) = (SceneRGB(255, 200, 120), SceneRGB(255, 222, 150), SceneRGB(226, 230, 232), 0.62)
            case .rain: (body, halo, tint, power) = (SceneRGB(236, 196, 150), SceneRGB(220, 196, 160), SceneRGB(190, 204, 214), 0.48)
            case .snow: (body, halo, tint, power) = (SceneRGB(255, 214, 150), SceneRGB(255, 236, 196), SceneRGB(244, 248, 255), 0.8)
            case .dusk: (body, halo, tint, power) = (SceneRGB(236, 242, 255), SceneRGB(150, 190, 236), SceneRGB(170, 196, 230), 0.55)
            case .night: (body, halo, tint, power) = (SceneRGB(244, 248, 255), SceneRGB(170, 206, 246), SceneRGB(206, 226, 250), 0.8)
            case .full: (body, halo, tint, power) = (SceneRGB(255, 255, 255), SceneRGB(200, 226, 255), SceneRGB(236, 244, 255), 1)
            }
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let s = size.width / SceneLayout.mockupWidth
        context.scaleBy(x: s, y: s)
        let w = Double(SceneLayout.mockupWidth)
        let h = Double(size.height / s)
        let hz = Double(SceneLayout.mockupHorizon)
        let layout = SceneLayout(size: CGSize(width: w, height: h))
        let marks = SceneMarks(state: state, layout: layout, clock: clock)
        let body = state.body.map(layout.drawnBody)
        let look = state.look
        let paint = Paint(look)
        let t = time
        let power = paint.power * (0.96 + 0.04 * sin(t * 1.3))
        let wheel = t * 0.0015
        let cx = w / 2
        let bx = body.map { Double($0.center.x) }
        let by = body.map { Double($0.center.y) }
        let radius = body.map { Double($0.radius) } ?? 12
        let lowness = body?.lowness ?? 0
        let light = body?.light ?? 1
        let clouds = state.cloudAmount
        let raining = state.isRaining
        let veil = raining ? 0.7 : clouds > 0 ? 0.85 : 1
        let skyRect = CGRect(x: 0, y: 0, width: w, height: hz)

        // Everything that gives light, in one layer brightened by the
        // mockup's bloom: its two blurred copies of the frame, added back at
        // .26 and .24, make smooth light about 1.56 times as bright.
        context.drawLayer { glowing in
            glowing.addFilter(.colorMatrix(Self.bloomGain))
            glowing.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(.black))
            let context = glowing
            var add = context
            add.blendMode = .plusLighter

            // By day the sky is blue: lightest on the horizon, falling quickly to
            // near black above the top of the path.
            if !look.isNight {
                // It fades with the light of a sun going under the water.
                var warmth = add
                warmth.opacity = light
                let warm = look == .sunrise || look == .sunset
                let k = (0.45 + 0.55 * paint.power) * (warm ? 0.16 : 0.5)
                let grey = raining ? 0.55 : clouds > 0 ? 0.25 : 0
                func blue(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> (SceneRGB, Double) {
                    let mean = (r + g + b) / 3
                    return (SceneRGB(r + (mean - r) * grey, g + (mean - g) * grey, b + (mean - b) * grey), a * k)
                }
                vertical(&warmth, from: hz, to: hz - 290, width: w, stops: [
                    (blue(70, 128, 214, 0.8), 0), (blue(56, 110, 200, 0.68), 0.1), (blue(40, 84, 160, 0.5), 0.26),
                    (blue(20, 48, 112, 0.32), 0.42), (blue(8, 20, 56, 0.14), 0.7), (blue(4, 8, 24, 0), 1),
                ])
                vertical(&warmth, from: hz, to: hz + 96, width: w, stops: [(blue(64, 112, 176, 0.42), 0), (blue(20, 40, 90, 0), 1)])
                if look == .sunrise, let bx {
                    // Yellow on the horizon, peach and a little pink above, then light blue.
                    vertical(&warmth, from: hz, to: hz - 230, width: w, stops: [
                        ((SceneRGB(255, 218, 96), 0.34), 0), ((SceneRGB(255, 180, 92), 0.25), 0.13),
                        ((SceneRGB(244, 140, 150), 0.13), 0.3), ((SceneRGB(120, 184, 240), 0.2), 0.5),
                        ((SceneRGB(70, 130, 214), 0.1), 0.75), ((SceneRGB(40, 80, 170), 0), 1),
                    ])
                    glow(&warmth, bx, hz, 250, 70, SceneRGB(255, 214, 70), 0.22, mid: 0.45)
                    glow(&warmth, bx, hz - 30, 280, 120, SceneRGB(255, 170, 90), 0.12, mid: 0.5)
                    glow(&warmth, cx + 40, hz - 120, 330, 120, SceneRGB(130, 196, 250), 0.14, mid: 0.55)
                    glow(&warmth, bx, hz + 22, 230, 56, SceneRGB(255, 206, 110), 0.1, mid: 0.45)
                } else if look == .sunset, let bx {
                    // Orange on the horizon, red and pink above, strongest on the sun's side.
                    vertical(&warmth, from: hz, to: hz - 190, width: w, stops: [
                        ((SceneRGB(255, 134, 40), 0.3), 0), ((SceneRGB(250, 92, 44), 0.26), 0.16),
                        ((SceneRGB(232, 60, 84), 0.17), 0.4), ((SceneRGB(200, 84, 130), 0.07), 0.7),
                        ((SceneRGB(120, 70, 150), 0), 1),
                    ])
                    glow(&warmth, bx, hz, 250, 70, SceneRGB(255, 124, 30), 0.2, mid: 0.45)
                    glow(&warmth, bx, hz - 34, 290, 130, SceneRGB(244, 62, 56), 0.15, mid: 0.5)
                    glow(&warmth, bx + (bx < cx ? 70 : -70), hz - 86, 300, 120, SceneRGB(236, 90, 150), 0.1, mid: 0.55)
                    glow(&warmth, bx, hz + 22, 230, 56, SceneRGB(255, 120, 76), 0.1, mid: 0.45)
                }
            }

            // Light in the sky: a wide haze round the body and a low one along the horizon.
            if let bx, let by {
                glow(&add, bx, by, 210, 210, Self.mist, 0.46 * (0.5 + 0.5 * power) * light, mid: 0.5)
            }
            glow(&add, cx, hz, w * 0.95, 130, Self.mist, 0.3 * (0.5 + 0.5 * power), mid: 0.5)

            // The sea: a hazy plane under the horizon, lit from below the body.
            vertical(&add, from: hz, to: hz + 120, width: w, stops: [
                ((SceneRGB(120, 140, 160), 0.34), 0), ((SceneRGB(90, 108, 128), 0.16), 0.25), ((SceneRGB(60, 70, 90), 0), 1),
            ])
            glow(&add, cx, hz, w * 0.75, 5, Self.silver, 0.5 * power, mid: 0.3)
            if let bx {
                glow(&add, bx, hz + 30, 120, 60, paint.tint, 0.2 * power * light, mid: 0.4)
                glow(&add, bx, hz + 16, 18 + radius * 0.7, 40 + radius * 0.6, paint.halo, 0.55 * power * lowness * light, mid: 0.4)
            }
            let glintCenter = Double(layout.glintCenterX(body))
            for g in SceneBits.shared.glints {
                let gy = hz + 3 + g.y * 78
                let spread = 40 + g.y * 220
                let gx = glintCenter + (g.x - 0.5) * 2 * spread
                let a = pow(0.5 + 0.5 * sin(t * 1.7 + g.phase), 3) * (1 - g.y * 0.7)
                add.fill(
                    Path(CGRect(x: gx, y: gy, width: g.size * 2.2, height: 0.7)),
                    with: .color((g.violet ? Self.violet : Self.silver).color(a * 0.9 * Self.sharp))
                )
            }

            // The firmament: thin haze and stars on one wheel that turns very
            // slowly about the middle of the horizon.
            var firmament = add
            firmament.clip(to: Path(skyRect))
            for m in SceneBits.shared.haze {
                let a = m.angle + wheel * m.turn
                glow(&firmament, cx + m.distance * cos(a), hz + m.distance * sin(a), m.size, m.size, Self.ice, 0.075 * (0.5 + 0.5 * power), mid: 0.5)
            }
            if state.starStrength > 0 {
                drawStars(in: &firmament, cx: cx, hz: hz, w: w, t: t, wheel: wheel)
            }

            // Weather, gathered round the body (or the top of the path).
            let weatherCenter = layout.weatherCenter(body)
            let wx = Double(weatherCenter.x)
            let wy = Double(weatherCenter.y)
            drawWeather(in: &firmament, wx: wx, wy: wy, t: t)

            // The sun or the moon; the horizon hides whatever part is under the water.
            if let body, let bx, let by {
                let spread = radius * (4.2 - 2.2 * lowness)
                glow(&add, bx, by, spread, spread, paint.halo, 0.55 * power * veil * light, mid: 0.3)

                // Soft light round the bright body and the horizon line (the
                // mockup's whole-frame bloom, kept to what is bright).
                add.drawLayer { layer in
                    layer.addFilter(.blur(radius: 9 * s))
                    layer.opacity = 0.45 * veil * light
                    var clipped = layer
                    clipped.clip(to: Path(skyRect))
                    let lit = body.kind == .sun ? 1 : 0.35 + 0.5 * state.moonPhase.illuminatedFraction
                    clipped.fill(Path(circleAt: CGPoint(x: bx, y: by), radius: radius * 0.95), with: .color(paint.body.color(lit)))
                }
            }
            add.drawLayer { layer in
                layer.addFilter(.blur(radius: 3 * s))
                layer.opacity = 0.6
                layer.fill(Path(CGRect(x: 0, y: hz - 0.6, width: w, height: 1.2)), with: .color(Self.silver.color(0.5 * power)))
            }

        }
        var add = context
        add.blendMode = .plusLighter

        // The disc itself, outside the brightened layer: the bloom spreads
        // round it but does not wash it out.
        if let body, let bx, let by {
            var sky = context
            sky.clip(to: Path(skyRect))
            if body.kind == .sun {
                drawSun(in: &sky, x: bx, y: by, r: radius, lowness: lowness, paint: paint, veil: veil, t: t)
                // The bloom over the disc itself: its blurred copies brighten
                // the middle of the disc much more than its edge.
                var over = sky
                over.blendMode = .plusLighter
                glow(&over, bx, by, radius * 1.3 + 5, radius * 1.3 + 5, SceneRGB(255, 236, 200), 0.6 * veil, mid: 0.6)
            } else {
                drawMoon(in: &sky, x: bx, y: by, r: radius)
                // The bloom over the lit face.
                var over = sky
                over.blendMode = .plusLighter
                over.clip(to: Self.litMoonPath(phase: state.moonPhase, center: CGPoint(x: bx, y: by), radius: radius))
                glow(&over, bx, by, radius * 1.4, radius * 1.4, paint.body, 0.5, mid: 0.7)
            }
        }

        // The marks, crisp, before the veils and grain.
        drawMarks(marks, in: &context, hz: hz)

        // Dark over the top of the sky and over the sea so the words read.
        vertical(&context, from: 0, to: 290, width: w, stops: [
            ((SceneRGB(0, 0, 0), 0.92), 0), ((SceneRGB(0, 0, 0), 0.74), 0.4), ((SceneRGB(0, 0, 0), 0.46), 0.62),
            ((SceneRGB(0, 0, 0), 0.2), 0.8), ((SceneRGB(0, 0, 0), 0.05), 0.92), ((SceneRGB(0, 0, 0), 0), 1),
        ])
        context.fill(
            Path(CGRect(x: 0, y: hz + 30, width: w, height: h - hz - 30)),
            with: .linearGradient(
                Gradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.9), location: 1)]),
                startPoint: CGPoint(x: 0, y: hz + 30), endPoint: CGPoint(x: 0, y: hz + 110)
            )
        )
        // Faint wave lights all the way down, brighter in the lane under the body.
        vertical(&add, from: hz + 60, to: h, width: w, stops: [
            ((paint.tint, 0), 0), ((look.isNight ? SceneRGB(40, 60, 90) : SceneRGB(30, 50, 84), 0.16), 0.3), ((SceneRGB(10, 20, 40), 0.1), 1),
        ])
        for g in SceneBits.shared.swell {
            let d = g.depth
            let gy = hz + 44 + pow(d, 1.5) * (h - hz - 44)
            let length = 3 + d * 15
            let gx = (g.x + t * 0.003 * (0.4 + d)).truncatingRemainder(dividingBy: 1) * (w + 40) - 30
            var lane = 0.0
            if let bx {
                let off: Double = (gx + length / 2 - bx) / (50 + d * 150)
                lane = exp(-off * off) * light
            }
            let wave: Double = 0.5 + 0.5 * sin(t * (0.9 + g.speed) + g.phase)
            let a: Double = wave * wave * (0.1 + 0.24 * lane * (1 - 0.6 * d)) * (0.5 + 0.5 * power)
            add.fill(
                Path(CGRect(x: gx, y: gy, width: length, height: 0.5 + d * 0.5)),
                with: .color((lane > 0.4 ? paint.tint : Self.silver).color(a))
            )
        }

        // Film grain over the whole view, a little finer under the titles.
        let step = floor(t * 24)
        let side = Double(SceneImages.grainSide)
        let nx = floor(sceneHash(step) * side)
        let ny = floor(sceneHash(step + 9.1) * side)
        let resolved = add.resolve(grain)
        for (y0, y1, alpha) in [(0.0, hz + 110, 0.11), (hz + 110, h, 0.07)] {
            var band = add
            band.clip(to: Path(CGRect(x: 0, y: y0, width: w, height: y1 - y0)))
            band.opacity = alpha
            var yy = -ny
            while yy < h {
                if yy + side > y0 && yy < y1 {
                    var xx = -nx
                    while xx < w {
                        band.draw(resolved, in: CGRect(x: xx, y: yy, width: side, height: side))
                        xx += side
                    }
                }
                yy += side
            }
        }
    }

    // MARK: Stars

    private func drawStars(in context: inout GraphicsContext, cx: Double, hz: Double, w: Double, t: Double, wheel: Double) {
        let strength = state.starStrength
        // Small stars are filled in batches by colour and brightness step.
        let steps = 12
        var dots = [Path](repeating: Path(), count: 2 * steps)
        for star in SceneBits.shared.stars {
            let a = star.angle + wheel
            let px = cx + star.distance * cos(a)
            let py = hz + star.distance * sin(a)
            if py > hz - 2 || py < -4 || px < -4 || px > w + 4 { continue }
            let twinkle = 0.55 + 0.45 * sin(t * 1.4 + star.phase)
            let alpha = min(1, (hz - py) / 26) * twinkle * strength * star.base * Self.sharp
            guard alpha > 0.01 else { continue }
            if star.size > 1.45 {
                glow(&context, px, py, star.size * 1.8, star.size * 1.8, star.violet ? Self.violet : SceneRGB(236, 244, 255), alpha, mid: 0.22)
            } else {
                let r = star.size * 0.55
                let level = min(steps - 1, Int(alpha * Double(steps)))
                dots[(star.violet ? steps : 0) + level].addEllipse(in: CGRect(x: px - r, y: py - r, width: 2 * r, height: 2 * r))
            }
        }
        for (index, path) in dots.enumerated() where !path.isEmpty {
            let level = index % steps
            let rgb = index >= steps ? Self.violet : Self.silver
            context.fill(path, with: .color(rgb.color((Double(level) + 0.5) / Double(steps))))
        }
    }

    // MARK: Weather

    private func drawWeather(in context: inout GraphicsContext, wx: Double, wy: Double, t: Double) {
        let near = 96.0
        let clouds = state.cloudAmount
        let bits = SceneBits.shared
        if clouds > 0 {
            for c in bits.clouds {
                let f = (c.x + t * c.speed).truncatingRemainder(dividingBy: 1)
                let x = wx + (f * 2.6 - 1.3) * near
                let y = wy + c.y * near + 14
                let edge = pow(sin(.pi * f), 0.7)
                glow(&context, x, y, c.width * near * 1.5, c.height * near * 0.7,
                     state.isRaining ? SceneRGB(150, 164, 180) : Self.silver, 0.24 * clouds * edge, mid: 0.6)
                glow(&context, x + c.width * near * 0.25, y - c.height * near * 0.3, c.width * near * 0.8, c.height * near * 0.4,
                     Self.silver, 0.18 * clouds * edge, mid: 0.6)
            }
        }
        if state.isRaining {
            for p in bits.rain {
                let f = (p.y + t * p.speed).truncatingRemainder(dividingBy: 1)
                let side = (p.x - 0.5) * 2
                let px = wx + side * near * 1.15 - f * 22 + 8
                let py = wy - 34 + f * 190
                var path = Path()
                path.move(to: CGPoint(x: px, y: py))
                path.addLine(to: CGPoint(x: px - 3.6, y: py + 13))
                context.stroke(path, with: .color(Self.silver.color(0.6 * Self.sharp * pow(sin(.pi * f), 0.6) * (1 - side * side))), lineWidth: 0.5)
            }
        }
        if state.isSnowing {
            for flake in bits.snow {
                let fall = (flake.y + t * flake.speed).truncatingRemainder(dividingBy: 1)
                let side = (flake.x - 0.5) * 2
                let fy = wy - 60 + fall * 210
                let fx = wx + side * near * 1.2 + sin(t * 0.6 + flake.phase) * 4
                context.fill(
                    Path(circleAt: CGPoint(x: fx, y: fy), radius: flake.radius * 0.7),
                    with: .color(Self.white.color(0.9 * Self.sharp * pow(sin(.pi * fall), 0.6) * (1 - side * side)))
                )
            }
        }
    }

    // MARK: Sun and moon

    /// The sun as burning gas: a hot centre, a deeper edge, bright and dark
    /// cells that churn, grain, and near the horizon a rippling dark orange
    /// line just outside its edge.
    private func drawSun(
        in context: inout GraphicsContext, x: Double, y: Double, r: Double,
        lowness: Double, paint: Paint, veil: Double, t: Double
    ) {
        let center = CGPoint(x: x, y: y)
        let disc = Path(circleAt: center, radius: r)
        context.fill(disc, with: .color(SceneRGB(2, 3, 6).color))
        context.fill(disc, with: radial(center: center, radius: r, [(paint.body, veil, 0), (paint.body, 0.9 * veil, 1)]))
        var face = context
        face.clip(to: disc)
        face.fill(disc, with: radial(center: center, radius: r, [
            (SceneRGB(255, 253, 240), veil, 0), (SceneRGB(255, 244, 206), 0.9 * veil, 0.42),
            (paint.halo, 0.45 * veil, 0.8), (SceneRGB(206, 84, 24), 0.34, 1),
        ]))
        var light = face
        light.blendMode = .plusLighter
        for k in 0..<16 {
            let kd = Double(k)
            let ang = kd * 2.4 + t * (0.22 + sceneHash(kd * 1.7) * 0.3) * (k % 2 == 1 ? 1 : -1)
            let rad = r * (0.1 + 0.8 * sceneHash(kd * 3.1)) * (0.85 + 0.15 * sin(t * 0.9 + kd))
            let size = r * (0.24 + 0.3 * sceneHash(kd * 7.7)) * (0.8 + 0.3 * sin(t * 1.7 + kd * 2.1))
            let px = x + rad * cos(ang)
            let py = y + rad * sin(ang)
            if k % 3 == 0 {
                glow(&face, px, py, size * 0.8, size * 0.8, SceneRGB(206, 96, 30), 0.2 * veil, mid: 0.5)
            } else {
                glow(&light, px, py, size, size, SceneRGB(255, 246, 214), 0.34 * veil * (0.55 + 0.45 * sin(t * 2.3 + kd * 1.3)), mid: 0.4)
            }
        }
        // Grain over the face, a fresh patch ten times a second.
        let grainSize = min(170, (r * 2 + 2) * 3)
        let side = Double(SceneImages.grainSide)
        let go = floor(t * 10)
        let ox = floor(sceneHash(go) * (side - grainSize))
        let oy = floor(sceneHash(go + 4.2) * (side - grainSize))
        let zoom = (r * 2 + 2) / grainSize
        var grained = face
        grained.blendMode = .softLight
        grained.opacity = 0.55
        grained.draw(grain, in: CGRect(x: x - r - 1 - ox * zoom, y: y - r - 1 - oy * zoom, width: side * zoom, height: side * zoom))

        guard lowness > 0.02 else { return }
        let tick = floor(t * 12)
        let segments = 120
        for (gap, wide, strength, speed) in [(3.2, 1.0, 0.5, 1.0), (6.4, 0.6, 0.26, -1.4)] {
            func point(_ j: Int) -> CGPoint {
                let q = Double(j) / Double(segments) * 2 * .pi
                let ripple = 0.5 * sin(5 * q + t * 1.1 * speed) + 0.3 * sin(11 * q - t * 1.9 * speed + 1)
                    + 0.2 * sin(19 * q + t * 2.9 * speed + 2)
                let rr = r + gap + ripple * (1.5 + gap * 0.12) * lowness
                return CGPoint(x: x + rr * cos(q), y: y + rr * sin(q))
            }
            var ring = Path()
            ring.move(to: point(0))
            for j in 1...segments { ring.addLine(to: point(j)) }
            ring.closeSubpath()
            var soft = context
            soft.blendMode = .plusLighter
            for (width, alpha) in [(wide * 6, 0.1), (wide * 3, 0.16)] {
                soft.stroke(ring, with: .color(SceneRGB(255, 112, 30).color(alpha * strength * lowness * veil)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            // The line itself, uneven: each short piece has its own strength
            // and width, and they flicker. Batched by strength and width step.
            var pieces = [Path](repeating: Path(), count: 5 * 3)
            for j in 0..<segments {
                let n1 = sceneHash(Double(j) * 1.7 + gap * 9 + tick * 0.23)
                let n2 = sceneHash(Double(j) * 3.1 + gap * 5)
                let index = min(4, Int(n1 * 5)) * 3 + min(2, Int(n2 * 3))
                pieces[index].move(to: point(j))
                pieces[index].addLine(to: point(j + 1))
            }
            for (index, path) in pieces.enumerated() where !path.isEmpty {
                let n1 = (Double(index / 3) + 0.5) / 5
                let n2 = (Double(index % 3) + 0.5) / 3
                context.stroke(path, with: .color(SceneRGB(236, 120, 44).color(strength * (0.35 + 0.65 * n1) * lowness * veil)),
                               style: StrokeStyle(lineWidth: wide * (0.6 + 0.7 * n2), lineCap: .round))
            }
        }
    }

    /// The moon: a dark disc, the lit face drawn once per phase, and a faint rim.
    private func drawMoon(in context: inout GraphicsContext, x: Double, y: Double, r: Double) {
        let center = CGPoint(x: x, y: y)
        let disc = Path(circleAt: center, radius: r)
        context.fill(disc, with: .color(SceneRGB(11, 16, 24).color))
        if let moonFace {
            context.draw(moonFace, in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        var rim = context
        rim.blendMode = .plusLighter
        rim.stroke(disc, with: .color(Self.silver.color(0.22)), lineWidth: 0.6)
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

    // MARK: Marks

    private func drawMarks(_ marks: SceneMarks, in context: inout GraphicsContext, hz: Double) {
        let hairWidth = 0.6
        for tick in marks.ticks {
            var path = Path()
            path.move(to: CGPoint(x: tick.x, y: hz + 2))
            path.addLine(to: CGPoint(x: tick.x, y: hz + (tick.isEnd ? 9 : 5)))
            context.stroke(path, with: .color(Self.white.color(tick.isEnd ? 0.7 : 0.42)), lineWidth: hairWidth)
        }
        if let square = marks.square {
            context.fill(Path(square), with: .color(state.ink.color(0.95)))
        }
        if let drop = marks.dropLine {
            var path = Path()
            var y = drop.top
            while y < drop.bottom {
                path.move(to: CGPoint(x: drop.x, y: y))
                path.addLine(to: CGPoint(x: drop.x, y: y + 1.6))
                y += 4
            }
            context.stroke(path, with: .color(Self.white.color(0.4)), lineWidth: hairWidth)
        }

        // Text: small mono type with a dark shadow.
        var text = context
        text.addFilter(.shadow(color: .black, radius: 2.2))
        text.addFilter(.shadow(color: .black.opacity(0.9), radius: 0.8))
        func mono(_ string: String, tracking: Double, color: Color) -> Text {
            Text(verbatim: string)
                .font(.system(size: 8.5, design: .monospaced))
                .tracking(8.5 * tracking)
                .foregroundStyle(color)
        }
        let markColor = SceneRGB(244, 246, 246).color(0.95)
        for label in [marks.riseTime, marks.setTime].compactMap({ $0 }) {
            text.draw(mono(label.text, tracking: 0.1, color: markColor), at: label.center, anchor: .center)
        }
    }

    // MARK: Drawing helpers

    /// The mockup's `glow`: a soft radial spot of `rgb`, `alpha` at its
    /// centre, a third of that at `mid`, gone at the edge of the ellipse.
    private func glow(
        _ context: inout GraphicsContext, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double,
        _ rgb: SceneRGB, _ alpha: Double, mid: Double = 0.4
    ) {
        guard alpha > 0.002, rx > 0, ry > 0 else { return }
        var spot = context
        spot.translateBy(x: x, y: y)
        spot.scaleBy(x: rx, y: ry)
        spot.fill(
            Path(CGRect(x: -1, y: -1, width: 2, height: 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: rgb.color(alpha), location: 0),
                    .init(color: rgb.color(alpha * 0.35), location: mid),
                    .init(color: rgb.color(0), location: 1),
                ]),
                center: .zero, startRadius: 0, endRadius: 1
            )
        )
    }

    private func radial(center: CGPoint, radius: Double, _ stops: [(SceneRGB, Double, Double)]) -> GraphicsContext.Shading {
        .radialGradient(
            Gradient(stops: stops.map { .init(color: $0.0.color($0.1), location: $0.2) }),
            center: center, startRadius: 0, endRadius: radius
        )
    }

    /// A full-width band filled with a vertical gradient from `y0` to `y1`
    /// (either way up), the stops given as colour, alpha and location.
    private func vertical(
        _ context: inout GraphicsContext, from y0: Double, to y1: Double, width: Double,
        stops: [((SceneRGB, Double), Double)]
    ) {
        let rect = CGRect(x: 0, y: min(y0, y1), width: width, height: abs(y1 - y0))
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: stops.map { .init(color: $0.0.0.color($0.0.1), location: $0.1) }),
                startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: y1)
            )
        )
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
