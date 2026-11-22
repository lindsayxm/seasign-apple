import CoreGraphics
import Foundation
import SwiftUI

// What the scene draws from but never changes: the star field and the other
// scattered bits (made once from the mockup's own seeds, so the stars sit
// where they do in the v11 stills), the film grain tile and the moon's face.

/// The mockup's random source (mulberry32), ported bit for bit, so the same
/// seed gives the same sequence as `prng()` in `design-ideas/v11-artemis/index.html`.
struct Mulberry32 {
    private var seed: UInt32

    init(seed: UInt32) {
        self.seed = seed
    }

    mutating func next() -> Double {
        seed = seed &+ 0x6D2B_79F5
        var t = (seed ^ (seed >> 15)) &* (1 | seed)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// The mockup's `hash`: a fixed pseudo-random value in 0..<1 for any number.
func sceneHash(_ n: Double) -> Double {
    let v = sin(n * 127.1) * 43758.5453
    return v - floor(v)
}

/// The scattered bits of the scene, in mockup points.
struct SceneBits: Sendable {
    struct Star: Sendable {
        /// Angle and distance from the middle of the horizon.
        var angle: Double
        var distance: Double
        var size: Double
        var phase: Double
        var violet: Bool
        /// `0.6 + 0.4 * hash(phase * 3.3)`, fixed per star.
        var base: Double
    }

    struct Haze: Sendable { var angle, distance, size, turn: Double }
    struct Cloud: Sendable { var x, y, width, height, speed: Double }
    struct Drop: Sendable { var x, y, speed: Double }
    struct Flake: Sendable { var x, y, speed, radius, phase: Double }
    struct Swell: Sendable { var x, depth, phase, speed: Double }
    struct Glint: Sendable { var x, y, phase, size: Double; var violet: Bool }

    var stars: [Star]
    var haze: [Haze]
    var clouds: [Cloud]
    var rain: [Drop]
    var snow: [Flake]
    var swell: [Swell]
    var glints: [Glint]

    /// From the middle of the horizon to past the top corners.
    static let far = 540.0
    static let starCount = 2600

    static let shared = SceneBits()

    private init() {
        let tau = 2 * Double.pi
        var srnd = Mulberry32(seed: 701)
        var hrnd = Mulberry32(seed: 702)
        var wrnd = Mulberry32(seed: 703)
        var grnd = Mulberry32(seed: 704)

        // Every star is spread evenly over the wheel's disc (task 163). The
        // mockup put 45 % of them in eleven clumps; on the turning wheel a
        // clump passing the moon read as stars gathering round it, so the
        // app's field no longer matches the v11 stills star for star.
        stars = (0..<Self.starCount).map { _ in
            let angle = srnd.next() * tau
            let distance = Self.far * srnd.next().squareRoot()
            let size = 0.6 + srnd.next() * srnd.next() * 2.0
            let phase = srnd.next() * tau
            let violet = srnd.next() < 0.13
            return Star(
                angle: angle, distance: distance,
                size: size, phase: phase, violet: violet, base: 0.6 + 0.4 * sceneHash(phase * 3.3)
            )
        }
        haze = (0..<18).map { _ in
            let a = hrnd.next() * tau
            let d = Self.far * (0.2 + 0.75 * hrnd.next())
            let s = 50 + hrnd.next() * 90
            return Haze(angle: a, distance: d, size: s, turn: 0.4 + hrnd.next() * 0.6)
        }
        clouds = (0..<9).map { _ in
            let x = wrnd.next()
            let y = -0.62 + wrnd.next() * 0.75
            let w = 0.35 + wrnd.next() * 0.45
            let h = 0.07 + wrnd.next() * 0.08
            return Cloud(x: x, y: y, width: w, height: h, speed: 0.006 + wrnd.next() * 0.012)
        }
        rain = (0..<64).map { _ in
            let x = wrnd.next()
            let y = wrnd.next()
            return Drop(x: x, y: y, speed: 0.5 + wrnd.next() * 0.4)
        }
        snow = (0..<56).map { _ in
            let x = wrnd.next()
            let y = wrnd.next()
            let speed = 0.03 + wrnd.next() * 0.04
            let r = 0.6 + wrnd.next() * 0.9
            return Flake(x: x, y: y, speed: speed, radius: r, phase: wrnd.next() * tau)
        }
        swell = (0..<170).map { _ in
            let x = grnd.next()
            let d = grnd.next()
            let ph = grnd.next() * tau
            return Swell(x: x, depth: d, phase: ph, speed: grnd.next())
        }
        glints = (0..<110).map { _ in
            let x = grnd.next()
            let y = pow(grnd.next(), 1.6)
            let ph = grnd.next() * tau
            let s = 0.5 + grnd.next() * 1.2
            return Glint(x: x, y: y, phase: ph, size: s, violet: grnd.next() < 0.08)
        }
    }
}

/// Images the scene draws but never changes, made once on the main actor.
@MainActor
enum SceneImages {
    /// Side of the grain tile, in pixels (drawn as as many points).
    nonisolated static let grainSide = 180

    /// The mockup's film grain tile: grey noise skewed dark, a little blue.
    static let grain: Image = makeGrainTile(inverted: false).map { Image(decorative: $0, scale: 1) } ?? Image(systemName: "circle")

    private static var moonFaces: [Int: Image] = [:]

    /// The lit face of the moon at `phase`: the lit shape with its plains,
    /// craters, pitting, edge shade and grain, drawn once per phase step on a
    /// 2R square and scaled to the moon's size when drawn.
    static func moonFace(phase: MoonPhase) -> Image? {
        let key = Int((phase.fraction * 200).rounded())
        if let image = moonFaces[key] { return image }
        guard let cgImage = MoonFaceDrawing.make(phase: MoonPhase(fraction: Double(key) / 200)) else { return nil }
        let image = Image(decorative: cgImage, scale: 1)
        if moonFaces.count > 8 { moonFaces.removeAll() }
        moonFaces[key] = image
        return image
    }

}

/// The mockup's grain tile as pixels; inverted for the moon's multiply pass.
func makeGrainTile(inverted: Bool) -> CGImage? {
    let side = SceneImages.grainSide
    var random = Mulberry32(seed: 77)
    var bytes = [UInt8](repeating: 255, count: side * side * 4)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        let v = random.next() * random.next() * 255
        let channel = { (value: Double) -> UInt8 in
            let clamped = min(255, max(0, value.rounded()))
            return UInt8(inverted ? 255 - clamped : clamped)
        }
        bytes[index] = channel(v)
        bytes[index + 1] = channel(v)
        bytes[index + 2] = channel(v * 1.08)
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
}

/// Draws the moon's lit face with Core Graphics, after the mockup's
/// `draw(t)`. Nothing in it moves, so it is drawn once per phase.
enum MoonFaceDrawing {
    /// The face's radius in pixels: the largest moon (50 pt) at 3x.
    static let radius: CGFloat = 150

    static func make(phase: MoonPhase) -> CGImage? {
        let r = radius
        let side = Int(2 * r)
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // y down, origin at the centre, as in the mockup.
        context.translateBy(x: r, y: r)
        context.scaleBy(x: 1, y: -1)

        let lit = SceneRenderer.litMoonPath(phase: phase, center: .zero, radius: r).cgPath
        context.addPath(lit)
        context.setFillColor(rgb(244, 248, 255, 1))
        context.fillPath()
        context.addPath(lit)
        context.clip()

        let sx: CGFloat = phase.isWaxing ? 1 : -1
        let u = r / 12
        let h = sceneHash
        // Plains: each a few overlapping soft patches.
        for k in 0..<9 {
            let kd = Double(k)
            let ang = h(kd * 2.3 + 1) * 2 * .pi
            let rad = r * 0.75 * CGFloat(h(kd * 5.9 + 2).squareRoot())
            let size = r * CGFloat(0.22 + 0.34 * h(kd * 8.1 + 3))
            for j in 0..<3 {
                let jd = Double(j)
                let ox = CGFloat(h(kd * 4.7 + jd * 2.1) - 0.5) * size * 1.3
                let oy = CGFloat(h(kd * 6.1 + jd * 3.3) - 0.5) * size * 1.1
                let sz = size * CGFloat(0.55 + 0.5 * h(kd * 1.9 + jd * 5.7))
                glow(
                    context, x: sx * (rad * CGFloat(cos(ang)) + ox), y: rad * CGFloat(sin(ang)) + oy,
                    rx: sz, ry: sz * CGFloat(0.55 + 0.5 * h(kd * 1.1 + jd)), (58, 72, 98), 0.2, mid: 0.6
                )
            }
        }
        // Craters: lumpy outlines, each tilted and squashed differently.
        for k in 0..<17 {
            let kd = Double(k)
            let ang = h(kd * 3.7 + 9) * 2 * .pi
            let rad = r * 0.9 * CGFloat(h(kd * 6.3 + 5).squareRoot())
            let cr = CGFloat(0.45 + h(kd * 4.4) * 1.25) * u
            let alpha = 0.1 + 0.16 * h(kd * 7.3)
            context.saveGState()
            context.translateBy(x: sx * rad * CGFloat(cos(ang)), y: rad * CGFloat(sin(ang)))
            context.rotate(by: CGFloat(h(kd * 2.9) * .pi))
            context.scaleBy(x: 1, y: CGFloat(0.55 + 0.45 * h(kd * 9.1)))
            func point(_ j: Int) -> CGPoint {
                let q = Double(j) / 8 * 2 * .pi
                let rr = cr * CGFloat(0.62 + 0.7 * h(kd * 13.7 + Double(j % 8) * 4.1))
                return CGPoint(x: rr * CGFloat(cos(q)), y: rr * CGFloat(sin(q)))
            }
            func mid(_ j: Int) -> CGPoint {
                let a = point(j)
                let b = point(j + 1)
                return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            context.move(to: mid(0))
            for j in 1...8 { context.addQuadCurve(to: mid(j), control: point(j)) }
            context.setFillColor(rgb(46, 58, 84, alpha))
            context.fillPath()
            glow(context, x: 0, y: 0, rx: cr * 1.7, ry: cr * 1.7, (46, 58, 84), alpha * 0.7, mid: 0.55)
            context.restoreGState()
        }
        // Fine pitting and pale flecks.
        for k in 0..<70 {
            let kd = Double(k)
            let ang = h(kd * 1.37 + 40) * 2 * .pi
            let rad = r * CGFloat(h(kd * 2.71 + 41).squareRoot())
            let sz = CGFloat(0.14 + 0.3 * h(kd * 3.9 + 42)) * u
            let dark = h(kd * 5.5 + 43) < 0.65
            let color = dark ? rgb(40, 52, 78, 0.16 + 0.22 * h(kd * 6.7)) : rgb(255, 255, 255, 0.12 + 0.2 * h(kd * 6.7))
            context.saveGState()
            context.translateBy(x: sx * rad * CGFloat(cos(ang)), y: rad * CGFloat(sin(ang)))
            context.rotate(by: CGFloat(h(kd * 9.3) * .pi))
            let ry = sz * CGFloat(0.5 + 0.5 * h(kd * 7.9))
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: -sz, y: -ry, width: 2 * sz, height: 2 * ry))
            context.restoreGState()
        }
        // Shade toward the edge.
        if let shade = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [rgb(30, 40, 64, 0), rgb(30, 40, 64, 0.16), rgb(30, 40, 64, 0.45)] as CFArray,
            locations: [0, 0.7, 1]
        ) {
            context.drawRadialGradient(
                shade, startCenter: CGPoint(x: -sx * r * 0.2, y: -r * 0.25), startRadius: r * 0.35,
                endCenter: .zero, endRadius: r, options: [.drawsBeforeStartLocation]
            )
        }
        // Grain at two scales, multiplied in inverted: fine, and a coarser blotch.
        if let grain = makeGrainTile(inverted: true) {
            context.setBlendMode(.multiply)
            let gs = 170
            let fineSource = grain.cropping(to: CGRect(x: 10, y: 10, width: gs, height: gs))
            let coarseSource = grain.cropping(to: CGRect(x: 96, y: 60, width: 22, height: 22))
            let rect = CGRect(x: -r - 3, y: -r - 3, width: 2 * r + 6, height: 2 * r + 6)
            context.interpolationQuality = .medium
            if let fineSource {
                context.setAlpha(0.34)
                context.draw(fineSource, in: rect)
            }
            if let coarseSource {
                context.setAlpha(0.26)
                context.draw(coarseSource, in: rect)
            }
        }
        return context.makeImage()
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: min(1, max(0, a)))
    }

    /// The mockup's `glow`: a soft radial spot, strongest at the centre.
    private static func glow(
        _ context: CGContext, x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat,
        _ color: (Double, Double, Double), _ alpha: Double, mid: CGFloat
    ) {
        guard rx > 0, ry > 0, let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                rgb(color.0, color.1, color.2, alpha),
                rgb(color.0, color.1, color.2, alpha * 0.35),
                rgb(color.0, color.1, color.2, 0),
            ] as CFArray,
            locations: [0, mid, 1]
        ) else { return }
        context.saveGState()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: rx, y: ry)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }
}
