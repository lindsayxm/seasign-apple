import CoreGraphics
import Foundation
import Observation
import SwiftData
import SwiftUI
import Testing

@testable import Seasign

/// The HUD colour in Settings (task 195): the slider writes `Settings.hudHue`
/// in the main store, every screen's accent follows at once
/// (`HUDAccentRoot` reads that row), the choice survives a relaunch, and
/// Default goes back to the orange-red.
@Suite(.serialized) @MainActor struct HUDColourSettingsTests {
    /// The accent every screen draws with for what is stored, as
    /// `HUDAccentRoot` works it out.
    private func accent(_ context: ModelContext) throws -> SRGB {
        let stored = try context.fetch(FetchDescriptor<Settings>()).first?.hudHue
        return HUDAccent.rgb(hue: HUDAccentRoot<EmptyView>.hue(stored: stored))
    }

    @Test func noRowMeansTheDefaultAndReadingCreatesNothing() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        #expect(try accent(context) == HUDAccent.defaultRGB)
        #expect(try context.fetch(FetchDescriptor<Settings>()).isEmpty)
        #expect(HUDHueSlider.shownHue(nil) == HUDAccent.defaultHue)
    }

    @Test func theSliderCreatesTheRowWhenThereIsNone() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        SkyStore(context: context).setHUDHue(210)
        let rows = try context.fetch(FetchDescriptor<Settings>())
        #expect(rows.count == 1)
        #expect(rows.first?.hudHue == 210)
        // A second change uses the same row.
        SkyStore(context: context).setHUDHue(75)
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.hudHue) == [75])
    }

    @Test func theSliderWritesTheRowEveryScreenReads() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setZip("10001")
        store.setHUDHue(210)
        #expect(store.hudHue == 210)
        #expect(try accent(context) == HUDAccent.rgb(hue: 210))
        #expect(try accent(context) != HUDAccent.defaultRGB)
        // The other settings in the row are untouched.
        #expect(store.zip == "10001")
    }

    /// A drag sets the hue on the row in memory (`save: false`) and its
    /// end saves. The root reads the row through Observation, so it is
    /// told of the change before any save: every screen follows at once.
    @Test func theAccentFollowsAtOnceWhileDragging() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setHUDHue(30)
        let row = try #require(try context.fetch(FetchDescriptor<Settings>()).first)
        let told = Told()
        withObservationTracking {
            _ = row.hudHue
        } onChange: {
            told.value = true
        }
        store.setHUDHue(120, save: false)
        #expect(told.value)
        #expect(try accent(context) == HUDAccent.rgb(hue: 120))
        #expect(context.hasChanges)
        store.setHUDHue(121, save: true)
        #expect(!context.hasChanges)
    }

    @Test func defaultGoesBackToTheOrangeRed() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setHUDHue(75)
        #expect(try accent(context) == HUDAccent.rgb(hue: 75))
        store.setHUDHue(nil)
        #expect(store.hudHue == nil)
        #expect(try accent(context) == HUDAccent.defaultRGB)
        #expect(try accent(context) == SRGB(235, 78, 39))
        #expect(HUDHueSlider.shownHue(store.hudHue) == HUDAccent.defaultHue)
    }

    @Test func theChoiceSurvivesARelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "HUDColourSettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = LocalStore.Files(
            user: directory.appending(path: "default.store"),
            cache: directory.appending(path: "SkyCache.store")
        )
        do {
            let opened = try LocalStore.open(files)
            SkyStore(context: opened.container.mainContext).setHUDHue(210)
        }
        do {
            let again = try LocalStore.open(files)
            #expect(try accent(again.container.mainContext) == HUDAccent.rgb(hue: 210))
            SkyStore(context: again.container.mainContext).setHUDHue(nil)
        }
        let third = try LocalStore.open(files)
        #expect(try ModelContext(third.container).fetch(FetchDescriptor<Settings>()).map(\.hudHue) == [nil])
        #expect(try accent(third.container.mainContext) == HUDAccent.defaultRGB)
    }

    @Test func aTouchSetsAWholeDegreeAlongTheTrack() {
        #expect(HUDHueSlider.hue(atX: 0, width: 300) == 0)
        #expect(HUDHueSlider.hue(atX: 300, width: 300) == 360)
        #expect(HUDHueSlider.hue(atX: 175, width: 300) == 210)
        #expect(HUDHueSlider.hue(atX: 62.5, width: 300) == 75)
        // Past either end: that end.
        #expect(HUDHueSlider.hue(atX: -40, width: 300) == 0)
        #expect(HUDHueSlider.hue(atX: 900, width: 300) == 360)
        // No width, or no position, never gives a broken hue.
        #expect(HUDHueSlider.hue(atX: 10, width: 0) == 0)
        #expect(HUDHueSlider.hue(atX: .nan, width: 300) == 0)
        // Every touch is a whole degree, and the thumb goes where the touch was.
        for x in stride(from: CGFloat(0), through: 300, by: 7.3) {
            let hue = HUDHueSlider.hue(atX: x, width: 300)
            #expect(hue == hue.rounded())
            #expect(abs(HUDHueSlider.x(forHue: hue, width: 300) - x) <= 300.0 / 720 + 1e-9)
        }
    }

    @Test func theThumbSitsAtTheStoredHueOrTheDefaults() {
        #expect(HUDHueSlider.shownHue(nil) == HUDAccent.defaultHue)
        #expect(HUDHueSlider.shownHue(.nan) == HUDAccent.defaultHue)
        #expect(HUDHueSlider.shownHue(210) == 210)
        #expect(HUDHueSlider.shownHue(400) == 360)
        #expect(HUDHueSlider.shownHue(-5) == 0)
        #expect(abs(HUDHueSlider.x(forHue: HUDHueSlider.shownHue(nil), width: 360) - CGFloat(HUDAccent.defaultHue)) < 1e-9)
    }

    /// VoiceOver: "HUD colour", the hue as the value, swipes in steps of
    /// ten degrees that stay inside the slider.
    @Test func voiceOverReadsAndAdjustsTheHue() {
        #expect(HUDHueSlider.spokenValue(210) == "hue 210 degrees")
        #expect(HUDHueSlider.spokenValue(nil) == "default orange-red, hue 12 degrees")
        #expect(HUDHueSlider.adjusted(210, up: true) == 220)
        #expect(HUDHueSlider.adjusted(210, up: false) == 200)
        // From the default's 11.94°, to the next step either way.
        #expect(HUDHueSlider.adjusted(nil, up: true) == 20)
        #expect(HUDHueSlider.adjusted(nil, up: false) == 10)
        #expect(HUDHueSlider.adjusted(213, up: true) == 220)
        #expect(HUDHueSlider.adjusted(213, up: false) == 210)
        #expect(HUDHueSlider.adjusted(360, up: true) == 360)
        #expect(HUDHueSlider.adjusted(0, up: false) == 0)
    }

    /// The track shows the accent the app would use at each hue, not the
    /// raw hue circle: every colour on it passes the colour rule.
    @Test func theTrackIsDrawnFromTheAccentRule() {
        let colours = HUDHueSlider.trackColours
        #expect(colours.count == 360 / HUDHueSlider.trackSpacing + 1)
        for (index, colour) in colours.enumerated() {
            let hue = Double(index * HUDHueSlider.trackSpacing)
            #expect(colour == HUDAccent.rgb(hue: hue), "\(hue)")
            #expect(SRGB.contrast(colour, Palette.hudPlateRGB) >= HUDAccent.minimumTextContrast, "\(hue)")
        }
        #expect(colours.first == colours.last)
    }
}

/// Set from an Observation `onChange`, which may run off the main actor.
private final class Told: @unchecked Sendable {
    var value = false
}
