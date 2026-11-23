import Foundation
import Testing
import UIKit
@testable import Seasign

/// The HUD accent's colour rule (`plans/2026-11-23-v12-in-the-app.md`,
/// Colour rule; `HUDAccent`).
@Suite struct HUDAccentTests {
    private let plate = Palette.hudPlateRGB
    private let onFill = Palette.onAccentRGB
    private let dateTile = Palette.dateTileRGB
    private let white = SRGB(255, 255, 255)

    /// Fixed numbers worked out by hand, so a mistake in the shared
    /// luminance code cannot cancel out between the app and the test.
    @Test func luminanceAndContrastMatchWCAG() {
        #expect(SRGB(255, 255, 255).relativeLuminance == 1)
        #expect(SRGB(0, 0, 0).relativeLuminance == 0)
        #expect(abs(SRGB.contrast(SRGB(255, 255, 255), SRGB(0, 0, 0)) - 21) < 1e-9)
        #expect(abs(SRGB(235, 78, 39).relativeLuminance - 0.23257) < 1e-4)
        #expect(abs(SRGB.contrast(SRGB(235, 78, 39), SRGB(8, 9, 12)) - 5.358) < 1e-3)
        #expect(abs(SRGB.contrast(SRGB(235, 78, 39), SRGB(14, 10, 8)) - 5.304) < 1e-3)
        #expect(abs(SRGB.contrast(SRGB(235, 78, 39), SRGB(244, 242, 238)) - 3.323) < 1e-3)
        // The band, from the plan's checks.
        #expect(abs(HUDAccent.luminanceFloor - 0.18976) < 1e-4)
        #expect(abs(HUDAccent.luminanceCeiling - 0.26303) < 1e-4)
    }

    /// The plan's checks, for one colour.
    private func passes(_ accent: SRGB, _ label: String) {
        #expect(SRGB.contrast(accent, plate) >= 4.5, "\(label) \(accent) on the plate")
        #expect(SRGB.contrast(onFill, accent) >= 4.5, "\(label) \(accent) under on-fill text")
        #expect(SRGB.contrast(accent, dateTile) >= HUDAccent.minimumDateTileContrast, "\(label) \(accent) near the date tile")
        #expect(SRGB.contrast(accent, white) >= HUDAccent.minimumDateTileContrast, "\(label) \(accent) near white")
        let luminance = accent.relativeLuminance
        #expect(luminance >= HUDAccent.luminanceFloor && luminance <= HUDAccent.luminanceCeiling, "\(label) \(accent) L \(luminance)")
    }

    /// The default passes its own rule; if it did not, the band would be wrong.
    @Test func theDefaultPassesTheRule() {
        #expect(HUDAccent.defaultRGB == SRGB(235, 78, 39))
        passes(HUDAccent.defaultRGB, "default")
    }

    /// No hue picked is the default exactly, not the function at its hue.
    @Test func noHueIsTheDefaultExactly() {
        #expect(HUDAccent.rgb(hue: nil) == SRGB(235, 78, 39))
        #expect(HUDAccent.rgb(hue: .nan) == SRGB(235, 78, 39))
        #expect(HUDAccent.rgb(hue: .infinity) == SRGB(235, 78, 39))
    }

    @Test func everyWholeDegreePasses() {
        for degree in 0..<360 {
            passes(HUDAccent.rgb(hue: Double(degree)), "hue \(degree)")
        }
    }

    /// The slider is continuous: tenths of a degree pass too.
    @Test func everyTenthOfADegreePasses() {
        for tenth in 0..<3600 {
            let accent = HUDAccent.rgb(hue: Double(tenth) / 10)
            let luminance = accent.relativeLuminance
            #expect(luminance >= HUDAccent.luminanceFloor && luminance <= HUDAccent.luminanceCeiling, "hue \(Double(tenth) / 10)")
        }
    }

    /// Every hue lands at the default's luminance, give or take 8-bit rounding.
    @Test func everyHueIsAsBrightAsTheDefault() {
        for degree in 0..<360 {
            let luminance = HUDAccent.rgb(hue: Double(degree)).relativeLuminance
            #expect(abs(luminance - HUDAccent.targetLuminance) < 0.005, "hue \(degree) L \(luminance)")
        }
    }

    /// Output is whole 8-bit steps, as drawn.
    @Test func outputIsEightBit() {
        for degree in stride(from: 0, to: 360, by: 7) {
            let accent = HUDAccent.rgb(hue: Double(degree))
            #expect(accent == accent.rounded8Bit)
        }
    }

    /// The default's hue gives back the default, so a slider that starts
    /// there does not jump.
    @Test func theDefaultsHueGivesTheDefault() {
        let accent = HUDAccent.rgb(hue: HUDAccent.defaultHue)
        #expect(abs(accent.red - 235.0 / 255) <= 1.0 / 255)
        #expect(abs(accent.green - 78.0 / 255) <= 1.0 / 255)
        #expect(abs(accent.blue - 39.0 / 255) <= 1.0 / 255)
    }

    /// Hues wrap: 360 is 0, -90 is 270.
    @Test func huesWrap() {
        #expect(HUDAccent.rgb(hue: 360) == HUDAccent.rgb(hue: 0))
        #expect(HUDAccent.rgb(hue: 725) == HUDAccent.rgb(hue: 5))
        #expect(HUDAccent.rgb(hue: -90) == HUDAccent.rgb(hue: 270))
    }

    /// Hues keep their character: the dominant component follows the hue.
    @Test func huesStayRecognisable() {
        let blue = HUDAccent.rgb(hue: 230)
        #expect(blue.blue > blue.red && blue.blue > blue.green)
        let green = HUDAccent.rgb(hue: 120)
        #expect(green.green > green.red && green.green > green.blue)
        let red = HUDAccent.rgb(hue: 0)
        #expect(red.red > red.green && red.red > red.blue)
    }

    /// The HUD's mono sizes are the system monospaced face.
    @Test func monoStylesAreMonospaced() {
        for style in HUDType.all {
            let font = style.uiFont
            #expect(font.pointSize == style.size)
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), "\(style.size) is \(font.fontName)")
            // Same advance for a narrow and a wide letter.
            let narrow = TodayType.width("i", font: font, tracking: 0)
            let wide = TodayType.width("W", font: font, tracking: 0)
            #expect(abs(narrow - wide) < 0.01)
        }
        #expect(abs(HUDType.title.tracking - 0.5 / 10.5) < 1e-9)
    }
}
