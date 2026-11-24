import Foundation
import Testing
import UIKit
@testable import Seasign

/// The HUD accent's colour rule (`plans/2026-11-23-v12-in-the-app.md`,
/// Colour rule; `HUDAccent`). Since task 206 the 3:1 ceiling from the white
/// date tile holds at lightness 0 only (`rgb(hue:)`); the user asked for
/// the range up to white. The two floors hold at every lightness.
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
        #expect(abs(SRGB(235, 79, 40).relativeLuminance - 0.23407) < 1e-4)
        #expect(abs(SRGB.contrast(SRGB(235, 79, 40), SRGB(8, 9, 12)) - 5.387) < 1e-3)
        #expect(abs(SRGB.contrast(SRGB(235, 79, 40), SRGB(14, 10, 8)) - 5.332) < 1e-3)
        #expect(abs(SRGB.contrast(SRGB(235, 79, 40), SRGB(244, 242, 238)) - 3.306) < 1e-3)
        // The band, from the plan's checks.
        #expect(abs(HUDAccent.luminanceFloor - 0.18976) < 1e-4)
        #expect(abs(HUDAccent.luminanceCeiling - 0.26303) < 1e-4)
    }

    /// The plan's checks, for one colour at lightness 0 (`rgb(hue:)`):
    /// both floors and the ceiling. Above lightness 0 only the floors apply
    /// (`theWholeBlockKeepsTheFloors`).
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
        #expect(HUDAccent.defaultRGB == SRGB(235, 79, 40))
        passes(HUDAccent.defaultRGB, "default")
    }

    /// No hue picked is the default exactly, not the function at its hue.
    @Test func noHueIsTheDefaultExactly() {
        #expect(HUDAccent.rgb(hue: nil) == SRGB(235, 79, 40))
        #expect(HUDAccent.rgb(hue: .nan) == SRGB(235, 79, 40))
        #expect(HUDAccent.rgb(hue: .infinity) == SRGB(235, 79, 40))
    }

    /// At lightness 0 (the bottom edge of the picker) every whole degree
    /// keeps the floors and the ceiling, as in task 192.
    @Test func everyWholeDegreePasses() {
        for degree in 0..<360 {
            passes(HUDAccent.rgb(hue: Double(degree)), "hue \(degree)")
            passes(HUDAccent.rgb(hue: Double(degree), lightness: 0), "hue \(degree) at lightness 0")
        }
    }

    /// Tenths of a degree stay in the band too, at lightness 0.
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
        #expect(abs(accent.green - 79.0 / 255) <= 1.0 / 255)
        #expect(abs(accent.blue - 40.0 / 255) <= 1.0 / 255)
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

    /// Task 206: the picker's whole block, at its own resolution (every
    /// whole degree by every whole percent of lightness, which includes
    /// the 21 steps of 5 percent): both floors hold everywhere, lightness 0
    /// is today's colour exactly, lightness 1 is white, the output is 8-bit,
    /// and the luminance never falls as the lightness rises.
    @Test func theWholeBlockKeepsTheFloors() {
        var failures: [String] = []
        for degree in 0...360 {
            let hue = Double(degree)
            let floor = HUDAccent.rgb(hue: hue)
            var previous = -1.0
            for percent in 0...100 {
                let lightness = Double(percent) / 100
                let accent = HUDAccent.rgb(hue: hue, lightness: lightness)
                let luminance = accent.relativeLuminance
                if SRGB.contrast(accent, plate) < 4.5 { failures.append("\(degree)° \(percent)% on the plate") }
                if SRGB.contrast(onFill, accent) < 4.5 { failures.append("\(degree)° \(percent)% under on-fill text") }
                if luminance < previous { failures.append("\(degree)° \(percent)% darker than \(percent - 1)%") }
                if accent != accent.rounded8Bit { failures.append("\(degree)° \(percent)% not 8-bit") }
                previous = luminance
            }
            if HUDAccent.rgb(hue: hue, lightness: 0) != floor { failures.append("\(degree)° at 0 is not today's colour") }
            if HUDAccent.rgb(hue: hue, lightness: nil) != floor { failures.append("\(degree)° at nil is not today's colour") }
            if HUDAccent.rgb(hue: hue, lightness: 1) != white { failures.append("\(degree)° at 1 is not white") }
        }
        #expect(failures.isEmpty, "\(failures.count) failures, first: \(failures.prefix(5))")
    }

    /// The default (no hue) mixes from the orange-red exactly, not from the
    /// function at its hue; lightness out of range or not a number is held.
    @Test func lightnessEndsAndEdges() {
        #expect(HUDAccent.rgb(hue: nil, lightness: nil) == SRGB(235, 79, 40))
        #expect(HUDAccent.rgb(hue: nil, lightness: 0) == SRGB(235, 79, 40))
        #expect(HUDAccent.rgb(hue: nil, lightness: .nan) == SRGB(235, 79, 40))
        #expect(HUDAccent.rgb(hue: nil, lightness: -2) == SRGB(235, 79, 40))
        #expect(HUDAccent.rgb(hue: nil, lightness: 1) == white)
        #expect(HUDAccent.rgb(hue: nil, lightness: 7) == white)
        #expect(HUDAccent.rgb(hue: nil, lightness: .infinity) == SRGB(235, 79, 40))
        #expect(HUDAccent.clampedLightness(0.25) == 0.25)
        #expect(HUDAccent.clampedLightness(nil) == 0)
        // Just above 0 is already a step lighter or the same, never darker.
        #expect(HUDAccent.rgb(hue: nil, lightness: 0.001).relativeLuminance >= HUDAccent.defaultRGB.relativeLuminance)
    }

    /// The mix, worked by hand outside Swift (Python, the same formulas):
    /// the orange-red's L* is 55.489; lightness t aims at L* 55.489 +
    /// t(100 - 55.489), and each component is mixed toward white in linear
    /// light by the share that reaches that luminance, then rounded.
    @Test func theMixMatchesHandWorkedNumbers() {
        #expect(abs(HUDAccent.cieLightness(luminance: HUDAccent.defaultRGB.relativeLuminance) - 55.4895) < 1e-3)
        #expect(abs(HUDAccent.luminance(cieLightness: 100) - 1) < 1e-12)
        #expect(abs(HUDAccent.luminance(cieLightness: HUDAccent.cieLightness(luminance: 0.4)) - 0.4) < 1e-12)
        #expect(abs(HUDAccent.luminance(cieLightness: HUDAccent.cieLightness(luminance: 0.005)) - 0.005) < 1e-12)
        #expect(HUDAccent.rgb(hue: nil, lightness: 0.25) == SRGB(238, 132, 119))
        #expect(HUDAccent.rgb(hue: nil, lightness: 0.4) == SRGB(241, 159, 150))
        #expect(HUDAccent.rgb(hue: nil, lightness: 0.5) == SRGB(243, 176, 169))
        #expect(HUDAccent.rgb(hue: nil, lightness: 0.75) == SRGB(248, 216, 213))
        // Halfway up is about halfway to white in L*, so the luminance at
        // 0.5 (0.528 before rounding) sits well below a straight luminance
        // halfway (0.617).
        let half = HUDAccent.rgb(hue: nil, lightness: 0.5).relativeLuminance
        #expect(abs(half - 0.5265) < 0.005)
    }

    /// Mixing toward white keeps the hue's character until it is nearly white.
    @Test func lightnessKeepsTheHue() {
        let blue = HUDAccent.rgb(hue: 230, lightness: 0.6)
        #expect(blue.blue > blue.red && blue.blue > blue.green)
        let green = HUDAccent.rgb(hue: 120, lightness: 0.6)
        #expect(green.green > green.red && green.green > green.blue)
        let red = HUDAccent.rgb(hue: 0, lightness: 0.6)
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
        // Task 205: titles at 12 points, still 0.5 points apart.
        #expect(abs(HUDType.title.tracking - 0.5 / 12) < 1e-9)
    }
}

/// Warnings and problems (task 197): one look on every HUD screen that can
/// never be taken for the accent, whatever hue the user picks.
@Suite @MainActor struct HUDWarningTests {
    @Test func aWarningIsWhiteWithAMark() {
        #expect(HUDWarning.colour == SRGB(255, 255, 255))
        #expect(HUDWarning.mark == "!")
        // As readable on the plate as body text.
        #expect(SRGB.contrast(HUDWarning.colour, Palette.hudPlateRGB) >= 7)
    }

    /// The old warning colour (`Palette.sun`, rgb(252, 104, 96)) was about
    /// 1.3:1 from the default accent; white is at least 3:1 from every hue
    /// at lightness 0. Since task 206 the user may pick lighter, up to white
    /// itself, where the accent matches the white parts by the user's choice;
    /// this holds at lightness 0 only.
    @Test func noHueMakesAWarningLookLikeTheAccent() {
        for degree in 0...360 {
            let accent = HUDAccent.rgb(hue: Double(degree), lightness: 0)
            #expect(SRGB.contrast(HUDWarning.colour, accent) >= 3, "hue \(degree)")
        }
        #expect(SRGB.contrast(SRGB(252, 104, 96), HUDAccent.defaultRGB) < 1.5)
    }
}
