import SwiftUI

/// The Seasign colours. Named values come from `ref-img/palette.png`; the rest
/// were sampled from the mockups (`ref-img/01`–`11`).
enum Palette {
    /// The sky, day and night. Sampled from the mockups (#302F2C).
    static let charcoal = Color(hex: 0x302F2C)
    /// SUN-07, the sun disc.
    static let sun = Color(hex: 0xFC6860)
    /// SKY-06, the water by day.
    static let dayWater = Color(hex: 0xB5DCE6)
    /// The water at night, sampled from the night mockups (#93BCC9).
    static let nightWater = Color(hex: 0x93BCC9)
    /// SEA-07. Not used by the scene yet; kept as the accent blue.
    static let sea = Color(hex: 0x4E8DB5)
    /// NIGHT-08.
    static let night = Color(hex: 0x0C0D12)
    /// WHTE-05, primary text on the sky and the lit moon.
    static let white = Color.white
    /// SLTE-04.
    static let slate = Color(hex: 0x8A8F99)
    /// Thin rules and the line icons on the sky, sampled from the mockups (#676663).
    static let rule = Color(hex: 0x676663)
    /// Secondary text on the sky ("NOV"), sampled from the mockups.
    static let dimText = Color(hex: 0xA9A8A4)
    /// The unlit part of the moon, sampled from the mockups (#41403C).
    static let moonShadow = Color(hex: 0x41403C)
    /// Text over the water.
    static let ink = charcoal
    /// Text over the dark v11 sea on Today (the mockup's 244, 242, 236).
    static let seaText = Color(.sRGB, red: 244 / 255, green: 242 / 255, blue: 236 / 255, opacity: 1)
    /// Today's white (design v11): the date, day name, temperature and
    /// event titles (the mockup's 238, 240, 240).
    static let todayText = Color(.sRGB, red: 238 / 255, green: 240 / 255, blue: 240 / 255, opacity: 1)
    /// The wind line under Today's hairline: 244, 246, 246 at 92 %.
    static let todayWind = Color(.sRGB, red: 244 / 255, green: 246 / 255, blue: 246 / 255, opacity: 0.92)
    /// The hairline that closes Today's header: white at 34 %.
    static let todayHairline = Color.white.opacity(0.34)
    /// The ground of Today's events box: black at 55 %.
    static let todayEventsBox = Color.black.opacity(0.55)
}

extension Color {
    /// An opaque sRGB colour from `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
