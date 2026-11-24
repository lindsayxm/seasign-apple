import SwiftData
import SwiftUI

/// An opaque sRGB colour with components from 0 to 1, for colour arithmetic
/// that tests can check without resolving a `Color`.
struct SRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 8-bit components, as the mockups give them (`rgb(235, 78, 39)`).
    init(_ red: Int, _ green: Int, _ blue: Int) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// Each component rounded to the nearest of 256 steps, as it is drawn.
    var rounded8Bit: SRGB {
        func step(_ value: Double) -> Double { (min(max(value, 0), 1) * 255).rounded() / 255 }
        return SRGB(red: step(red), green: step(green), blue: step(blue))
    }

    /// WCAG 2 relative luminance: 0 for black, 1 for white.
    var relativeLuminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    /// One sRGB component (0 to 1) as linear light (0 to 1).
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Linear light (0 to 1) back to an sRGB component (0 to 1).
    static func encoded(_ linear: Double) -> Double {
        let value = min(max(linear, 0), 1)
        return value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// WCAG 2 contrast ratio between two colours, from 1 to 21.
    static func contrast(_ first: SRGB, _ second: SRGB) -> Double {
        let a = first.relativeLuminance
        let b = second.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The colour of `hue` (degrees, 0 to 360) at `saturation` and `value`
    /// (each 0 to 1) in the HSV model.
    static func hsv(hue: Double, saturation: Double, value: Double) -> SRGB {
        let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
        let chroma = value * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let low = value - chroma
        let (r, g, b): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        return SRGB(red: r + low, green: g + low, blue: b + low)
    }
}

/// The HUD's accent (design v12): the colour of the tiles, outlines, labels
/// and titles, on every screen. The user picks a hue (`Settings.hudHue`)
/// and, since task 206, a lightness (`Settings.hudLightness`, 0 to 1); this
/// turns them into the colour (`plans/2026-11-23-v12-in-the-app.md`,
/// Colour rule).
///
/// At lightness 0 (`rgb(hue:)`, the colour of task 192) the rule holds the
/// colour's relative luminance inside a band:
///
/// - floor: at least 4.5:1 for small accent text on the dark plate
///   (`Palette.hudPlateRGB`), and at least 4.5:1 for the dark text on a
///   filled tile (`Palette.onAccentRGB` on the accent). Both say the accent
///   must not be too dark; the higher of the two is the floor (L ≥ 0.190).
/// - ceiling: at least 3:1 (WCAG's figure for non-text contrast) against the
///   white date tile (`Palette.dateTileRGB`), so a filled tile never looks
///   like the date tile (L ≤ 0.263). Pure white is brighter than the date
///   tile, so this also keeps the accent at least 3:1 from white.
///
/// Every hue is aimed at the default's own luminance (about 0.233), in the
/// band with room either side, so every hue reads exactly as strongly
/// against any background as the orange-red the user approved. The
/// saturation is the default's too; a hue that cannot reach the luminance at
/// that saturation (blue, violet, red) is mixed toward white until it does,
/// and a hue that is brighter (yellow, green, cyan) is darkened.
///
/// Lightness (task 206) mixes that colour toward white, up to white itself
/// at 1 (`rgb(hue:lightness:)`). The user asked for the whole range, so the
/// ceiling holds only at lightness 0; mixing toward white only raises the
/// luminance, so both floors hold everywhere.
enum HUDAccent {
    /// The orange-red sampled from the v12 reference, `rgb(235, 78, 39)`.
    static let defaultRGB = SRGB(235, 78, 39)
    /// The default's hue in degrees (about 11.94), where a hue slider starts.
    static let defaultHue: Double = 60 * (78.0 - 39.0) / (235.0 - 39.0)

    /// The smallest contrast allowed on the plate and for text on a filled tile.
    static let minimumTextContrast = 4.5
    /// The smallest contrast allowed against the white date tile.
    static let minimumDateTileContrast = 3.0

    /// The lowest relative luminance that passes both 4.5:1 checks.
    static let luminanceFloor: Double = max(
        minimumTextContrast * (Palette.hudPlateRGB.relativeLuminance + 0.05) - 0.05,
        minimumTextContrast * (Palette.onAccentRGB.relativeLuminance + 0.05) - 0.05
    )
    /// The highest relative luminance that keeps 3:1 from the date tile.
    static let luminanceCeiling: Double =
        (Palette.dateTileRGB.relativeLuminance + 0.05) / minimumDateTileContrast - 0.05

    /// The luminance every hue is set to: the default's.
    static let targetLuminance = defaultRGB.relativeLuminance
    /// The HSV saturation every hue starts from: the default's (about 0.83).
    static let saturation: Double = (235.0 - 39.0) / 235.0

    /// The accent for a stored hue; nil, or a hue that is not a finite
    /// number, is the default orange-red exactly.
    static func rgb(hue: Double?) -> SRGB {
        guard let hue, hue.isFinite else { return defaultRGB }
        let degrees = hue.truncatingRemainder(dividingBy: 360)
        let normalized = degrees < 0 ? degrees + 360 : degrees
        let full = SRGB.hsv(hue: normalized, saturation: saturation, value: 1)
        let solved: SRGB
        if full.relativeLuminance >= targetLuminance {
            // Too bright at full value: darken until the luminance is reached.
            let value = bisect { SRGB.hsv(hue: normalized, saturation: saturation, value: $0).relativeLuminance }
            solved = SRGB.hsv(hue: normalized, saturation: saturation, value: value)
        } else {
            // Too dark even at full value: mix toward white instead.
            let mix = bisect { SRGB.hsv(hue: normalized, saturation: saturation * (1 - $0), value: 1).relativeLuminance }
            solved = SRGB.hsv(hue: normalized, saturation: saturation * (1 - mix), value: 1)
        }
        return solved.rounded8Bit
    }

    static func color(hue: Double?) -> Color {
        rgb(hue: hue).color
    }

    /// A stored lightness as the colour uses it: nil, or not a finite
    /// number, is 0 (the colour of the hue); anything else held to 0...1.
    static func clampedLightness(_ lightness: Double?) -> Double {
        guard let lightness, lightness.isFinite else { return 0 }
        return min(max(lightness, 0), 1)
    }

    /// The accent for a stored hue and lightness: the colour of the hue
    /// (`rgb(hue:)`, exactly) at lightness 0 or nil, white at 1, and in
    /// between that colour mixed toward white.
    ///
    /// The mix is a straight line toward white in linear light, one
    /// component at a time (each linear value `c` becomes `c + s(1 - c)`),
    /// then rounded to 8 bits. In linear light the line keeps the colour's
    /// chromaticity on the way to the white point, so the hue does not
    /// drift, and the luminance is `L0 + s(1 - L0)`. How far along the line
    /// (`s`) is set so that CIE lightness L* rises in equal steps from the
    /// colour's L* to white's 100: lightness 0.5 looks halfway to white,
    /// where a mix by luminance would already look nearly white. Every step
    /// (`s` from lightness, each component from `s`, the sRGB encoding and
    /// the rounding) never goes down, so neither does the luminance; and the
    /// mix only adds light, so the floors hold at every lightness.
    static func rgb(hue: Double?, lightness: Double?) -> SRGB {
        mix(rgb(hue: hue), toWhite: clampedLightness(lightness))
    }

    static func color(hue: Double?, lightness: Double?) -> Color {
        rgb(hue: hue, lightness: lightness).color
    }

    /// `floor` mixed toward white by `lightness` (0...1), as described at
    /// `rgb(hue:lightness:)`. Kept apart so the Settings picker can solve
    /// each hue's floor once and mix it many times.
    static func mix(_ floor: SRGB, toWhite lightness: Double) -> SRGB {
        guard lightness.isFinite, lightness > 0 else { return floor }
        guard lightness < 1 else { return SRGB(255, 255, 255) }
        let floorLuminance = floor.relativeLuminance
        guard floorLuminance < 1 else { return SRGB(255, 255, 255) }
        let floorLStar = cieLightness(luminance: floorLuminance)
        let target = luminance(cieLightness: floorLStar + lightness * (100 - floorLStar))
        let along = min(max((target - floorLuminance) / (1 - floorLuminance), 0), 1)
        func component(_ value: Double) -> Double {
            let linear = SRGB.linear(value)
            return SRGB.encoded(linear + along * (1 - linear))
        }
        return SRGB(red: component(floor.red), green: component(floor.green), blue: component(floor.blue)).rounded8Bit
    }

    /// CIE 1976 lightness L* (0 to 100) of a relative luminance (0 to 1).
    static func cieLightness(luminance: Double) -> Double {
        let delta: Double = 6.0 / 29
        let f: Double = luminance > delta * delta * delta
            ? cbrt(luminance)
            : luminance / (3 * delta * delta) + 4.0 / 29
        return 116 * f - 16
    }

    /// The relative luminance (0 to 1) of a CIE lightness L* (0 to 100).
    static func luminance(cieLightness lightness: Double) -> Double {
        let delta: Double = 6.0 / 29
        let f: Double = (lightness + 16) / 116
        return f > delta ? f * f * f : 3 * delta * delta * (f - 4.0 / 29)
    }

    /// The point in 0...1 where `luminance`, which rises with its argument,
    /// reaches `targetLuminance`.
    private static func bisect(_ luminance: (Double) -> Double) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if luminance(middle) < targetLuminance { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}

extension EnvironmentValues {
    /// The HUD accent every view draws its accent parts in. The app root
    /// sets it from `Settings.hudHue` (`HUDAccentRoot`); anywhere it is not
    /// set, it is the default orange-red.
    @Entry var hudAccent: Color = Palette.hudAccent
}

/// Reads the user's HUD hue and lightness from the settings row and hands
/// the accent to everything inside. It must sit inside `.modelContainer`.
/// No settings row yet means the default; this never creates one.
struct HUDAccentRoot<Content: View>: View {
    @Query private var settings: [Settings]
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // Both fields are read here, so a change to either redraws.
        let row = settings.first
        content.environment(\.hudAccent, HUDAccent.color(
            hue: Self.hue(stored: row?.hudHue),
            lightness: Self.lightness(stored: row?.hudLightness)
        ))
    }

    /// The hue every screen draws with: the stored one. In DEBUG builds
    /// `-debugHue <degrees>` stands in for it without writing the store
    /// (screenshots); the Settings slider still shows the stored hue.
    static func hue(stored: Double?) -> Double? {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "debugHue"), let debug = Double(text) {
            return debug
        }
        #endif
        return stored
    }

    /// The lightness every screen draws with: the stored one, held to 0...1.
    /// In DEBUG builds `-debugLightness <0…1>` stands in for it without
    /// writing the store (screenshots); the Settings picker still shows the
    /// stored choice.
    static func lightness(stored: Double?) -> Double {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "debugLightness"), let debug = Double(text) {
            return HUDAccent.clampedLightness(debug)
        }
        #endif
        return HUDAccent.clampedLightness(stored)
    }
}
