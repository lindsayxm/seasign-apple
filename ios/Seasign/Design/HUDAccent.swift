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
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
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
/// and titles, on every screen. The user picks only a hue
/// (`Settings.hudHue`); this turns it into a colour that is always as easy
/// to see as the default orange-red (`plans/2026-11-23-v12-in-the-app.md`,
/// Colour rule).
///
/// The rule holds the colour's relative luminance inside a band:
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

/// Reads the user's HUD hue from the settings row and hands the accent to
/// everything inside. It must sit inside `.modelContainer`. No settings row
/// yet means the default; this never creates one.
struct HUDAccentRoot<Content: View>: View {
    @Query private var settings: [Settings]
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.hudAccent, HUDAccent.color(hue: Self.hue(stored: settings.first?.hudHue)))
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
}
