import CoreGraphics
import Foundation
import Observation
import SwiftData
import SwiftUI
import Testing

@testable import Seasign

/// The HUD colour in Settings (task 195; the colour picker since task 206):
/// the picker writes `Settings.hudHue` and `Settings.hudLightness` in the
/// main store, every screen's accent follows at once (`HUDAccentRoot`
/// reads that row), the choice survives a relaunch, and Default clears both.
@Suite(.serialized) @MainActor struct HUDColourSettingsTests {
    /// The accent every screen draws with for what is stored, as
    /// `HUDAccentRoot` works it out.
    private func accent(_ context: ModelContext) throws -> SRGB {
        let row = try context.fetch(FetchDescriptor<Settings>()).first
        return HUDAccent.rgb(
            hue: HUDAccentRoot<EmptyView>.hue(stored: row?.hudHue),
            lightness: HUDAccentRoot<EmptyView>.lightness(stored: row?.hudLightness)
        )
    }

    @Test func noRowMeansTheDefaultAndReadingCreatesNothing() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        #expect(try accent(context) == HUDAccent.defaultRGB)
        #expect(try context.fetch(FetchDescriptor<Settings>()).isEmpty)
        #expect(HUDColourField.shownHue(nil) == HUDAccent.defaultHue)
        #expect(HUDColourField.shownLightness(nil) == 0)
    }

    @Test func thePickerCreatesTheRowWhenThereIsNone() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        SkyStore(context: context).setHUDColour(hue: 210, lightness: 0.4)
        let rows = try context.fetch(FetchDescriptor<Settings>())
        #expect(rows.count == 1)
        #expect(rows.first?.hudHue == 210)
        #expect(rows.first?.hudLightness == 0.4)
        // A second change uses the same row.
        SkyStore(context: context).setHUDColour(hue: 75, lightness: 0)
        let again = try context.fetch(FetchDescriptor<Settings>())
        #expect(again.map(\.hudHue) == [75])
        #expect(again.map(\.hudLightness) == [0])
    }

    @Test func thePickerWritesTheRowEveryScreenReads() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setZip("10001")
        store.setHUDColour(hue: 210, lightness: 0.6)
        #expect(store.hudHue == 210)
        #expect(store.hudLightness == 0.6)
        #expect(try accent(context) == HUDAccent.rgb(hue: 210, lightness: 0.6))
        #expect(try accent(context) != HUDAccent.rgb(hue: 210))
        #expect(try accent(context) != HUDAccent.defaultRGB)
        // The other settings in the row are untouched.
        #expect(store.zip == "10001")
    }

    /// A stored lightness outside 0...1 (an older build, a hand-edited
    /// store) is held to the range wherever it is read.
    @Test func aStoredLightnessIsHeldToTheRangeOnRead() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setHUDColour(hue: 120, lightness: 1.7)
        #expect(store.hudLightness == 1)
        #expect(try accent(context) == SRGB(255, 255, 255))
        #expect(HUDColourField.shownLightness(1.7) == 1)
        store.setHUDColour(hue: 120, lightness: -0.3)
        #expect(store.hudLightness == 0)
        #expect(try accent(context) == HUDAccent.rgb(hue: 120))
        // Not a number reads as 0 (SwiftData may hand it back as nil).
        store.setHUDColour(hue: 120, lightness: .nan)
        #expect(HUDAccent.clampedLightness(store.hudLightness) == 0)
        #expect(try accent(context) == HUDAccent.rgb(hue: 120))
        #expect(HUDAccentRoot<EmptyView>.lightness(stored: .nan) == 0)
        #expect(HUDAccentRoot<EmptyView>.lightness(stored: nil) == 0)
        #expect(HUDAccentRoot<EmptyView>.lightness(stored: 0.35) == 0.35)
    }

    /// A drag sets the colour on the row in memory (`save: false`) and its
    /// end saves. The root reads the row through Observation, so it is
    /// told of a change to either value before any save: every screen
    /// follows at once.
    @Test func theAccentFollowsAtOnceWhileDragging() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setHUDColour(hue: 30, lightness: 0.2)
        let row = try #require(try context.fetch(FetchDescriptor<Settings>()).first)
        let told = Told()
        withObservationTracking {
            _ = row.hudHue
            _ = row.hudLightness
        } onChange: {
            told.value = true
        }
        // Only the lightness changes: a drag straight up.
        store.setHUDColour(hue: 30, lightness: 0.5, save: false)
        #expect(told.value)
        #expect(try accent(context) == HUDAccent.rgb(hue: 30, lightness: 0.5))
        #expect(context.hasChanges)
        store.setHUDColour(hue: 31, lightness: 0.5, save: true)
        #expect(!context.hasChanges)
    }

    @Test func defaultClearsHueAndLightness() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setHUDColour(hue: 75, lightness: 0.8)
        #expect(try accent(context) == HUDAccent.rgb(hue: 75, lightness: 0.8))
        store.setHUDColour(hue: nil, lightness: nil)
        #expect(store.hudHue == nil)
        #expect(store.hudLightness == nil)
        let row = try #require(try context.fetch(FetchDescriptor<Settings>()).first)
        #expect(row.hudHue == nil)
        #expect(row.hudLightness == nil)
        #expect(try accent(context) == HUDAccent.defaultRGB)
        #expect(try accent(context) == SRGB(235, 78, 39))
        #expect(HUDColourField.shownHue(store.hudHue) == HUDAccent.defaultHue)
        #expect(HUDColourField.shownLightness(store.hudLightness) == 0)
        #expect(HUDColourField.choiceLabel(hue: nil, lightness: nil) == "Default orange-red")
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
            SkyStore(context: opened.container.mainContext).setHUDColour(hue: 210, lightness: 0.45)
        }
        do {
            let again = try LocalStore.open(files)
            #expect(try accent(again.container.mainContext) == HUDAccent.rgb(hue: 210, lightness: 0.45))
            SkyStore(context: again.container.mainContext).setHUDColour(hue: nil, lightness: nil)
        }
        let third = try LocalStore.open(files)
        let rows = try ModelContext(third.container).fetch(FetchDescriptor<Settings>())
        #expect(rows.map(\.hudHue) == [nil])
        #expect(rows.map(\.hudLightness) == [nil])
        #expect(try accent(third.container.mainContext) == HUDAccent.defaultRGB)
    }

    /// Across is the hue in whole degrees, up is the lightness in whole
    /// percent from the bottom edge (0) to the top edge (1).
    @Test func aTouchPicksAWholeDegreeAndAWholePercent() {
        let size = CGSize(width: 300, height: 200)
        #expect(HUDColourField.pick(at: CGPoint(x: 0, y: 200), size: size) == HUDColourPick(hue: 0, lightness: 0))
        #expect(HUDColourField.pick(at: CGPoint(x: 300, y: 0), size: size) == HUDColourPick(hue: 360, lightness: 1))
        #expect(HUDColourField.pick(at: CGPoint(x: 175, y: 120), size: size) == HUDColourPick(hue: 210, lightness: 0.4))
        #expect(HUDColourField.pick(at: CGPoint(x: 62.5, y: 100), size: size) == HUDColourPick(hue: 75, lightness: 0.5))
        // Past any edge: that edge (a drag that leaves the block keeps going along it).
        #expect(HUDColourField.pick(at: CGPoint(x: -40, y: -90), size: size) == HUDColourPick(hue: 0, lightness: 1))
        #expect(HUDColourField.pick(at: CGPoint(x: 900, y: 900), size: size) == HUDColourPick(hue: 360, lightness: 0))
        // No size, or no position, never gives a broken colour.
        #expect(HUDColourField.pick(at: CGPoint(x: 10, y: 10), size: .zero) == HUDColourPick(hue: 0, lightness: 0))
        #expect(HUDColourField.pick(at: CGPoint(x: CGFloat.nan, y: CGFloat.nan), size: size) == HUDColourPick(hue: 0, lightness: 0))
        // Every touch is a whole step, and the marker goes where the touch was.
        for x in stride(from: CGFloat(0), through: 300, by: 7.3) {
            for y in stride(from: CGFloat(0), through: 200, by: 9.1) {
                let pick = HUDColourField.pick(at: CGPoint(x: x, y: y), size: size)
                #expect(pick.hue == pick.hue.rounded())
                #expect(abs(pick.lightness * 100 - (pick.lightness * 100).rounded()) < 1e-9)
                let marker = HUDColourField.point(hue: pick.hue, lightness: pick.lightness, size: size)
                #expect(abs(marker.x - x) <= 300.0 / 720 + 1e-9)
                #expect(abs(marker.y - y) <= 200.0 / 200 + 1e-9)
            }
        }
    }

    @Test func theMarkerSitsAtTheStoredChoiceOrTheDefaults() {
        #expect(HUDColourField.shownHue(nil) == HUDAccent.defaultHue)
        #expect(HUDColourField.shownHue(.nan) == HUDAccent.defaultHue)
        #expect(HUDColourField.shownHue(210) == 210)
        #expect(HUDColourField.shownHue(400) == 360)
        #expect(HUDColourField.shownHue(-5) == 0)
        #expect(HUDColourField.shownLightness(0.4) == 0.4)
        #expect(HUDColourField.shownLightness(-1) == 0)
        // Default: the default's hue, on the bottom edge.
        let size = CGSize(width: 360, height: 168)
        let marker = HUDColourField.point(hue: nil, lightness: nil, size: size)
        #expect(abs(marker.x - CGFloat(HUDAccent.defaultHue)) < 1e-9)
        #expect(marker.y == 168)
        // White: the top edge.
        #expect(HUDColourField.point(hue: 210, lightness: 1, size: size) == CGPoint(x: 210, y: 0))
    }

    /// VoiceOver: "HUD color hue" with the degrees as its value, swipes in
    /// steps of ten degrees that stay inside the circle.
    @Test func voiceOverReadsAndAdjustsTheHue() {
        #expect(HUDColourField.spokenHue(210) == "210 degrees")
        #expect(HUDColourField.spokenHue(nil) == "default orange-red, 12 degrees")
        #expect(HUDColourField.adjustedHue(210, up: true) == 220)
        #expect(HUDColourField.adjustedHue(210, up: false) == 200)
        // From the default's 11.94°, to the next step either way.
        #expect(HUDColourField.adjustedHue(nil, up: true) == 20)
        #expect(HUDColourField.adjustedHue(nil, up: false) == 10)
        #expect(HUDColourField.adjustedHue(213, up: true) == 220)
        #expect(HUDColourField.adjustedHue(213, up: false) == 210)
        #expect(HUDColourField.adjustedHue(360, up: true) == 360)
        #expect(HUDColourField.adjustedHue(0, up: false) == 0)
    }

    /// VoiceOver: "HUD color lightness" with the percent as its value,
    /// swipes in steps of ten percent that land exactly and stay in 0...1.
    @Test func voiceOverReadsAndAdjustsTheLightness() {
        #expect(HUDColourField.spokenLightness(0.4) == "40 percent")
        #expect(HUDColourField.spokenLightness(nil) == "0 percent")
        #expect(HUDColourField.spokenLightness(1) == "100 percent")
        #expect(HUDColourField.adjustedLightness(nil, up: true) == 0.1)
        #expect(HUDColourField.adjustedLightness(nil, up: false) == 0)
        #expect(HUDColourField.adjustedLightness(0.2, up: true) == 0.3)
        #expect(HUDColourField.adjustedLightness(0.3, up: false) == 0.2)
        #expect(HUDColourField.adjustedLightness(0.43, up: true) == 0.5)
        #expect(HUDColourField.adjustedLightness(0.43, up: false) == 0.4)
        #expect(HUDColourField.adjustedLightness(1, up: true) == 1)
        #expect(HUDColourField.adjustedLightness(0.95, up: true) == 1)
        // Ten swipes up from the bottom reach white exactly.
        var lightness: Double? = nil
        for _ in 0..<10 { lightness = HUDColourField.adjustedLightness(lightness, up: true) }
        #expect(lightness == 1)
        #expect(HUDAccent.rgb(hue: 210, lightness: lightness) == SRGB(255, 255, 255))
    }

    /// The line beside Default says the choice in the section's style.
    @Test func theChoiceLabelSaysTheChoice() {
        #expect(HUDColourField.choiceLabel(hue: nil, lightness: nil) == "Default orange-red")
        #expect(HUDColourField.choiceLabel(hue: 210, lightness: 0.4) == "Hue 210° · lightness 40%")
        #expect(HUDColourField.choiceLabel(hue: 210, lightness: nil) == "Hue 210° · lightness 0%")
        #expect(HUDColourField.choiceLabel(hue: nil, lightness: 0.3) == "Orange-red · lightness 30%")
    }

    /// The block shows exactly what a touch there picks: every pixel of its
    /// picture is `HUDAccent.rgb(hue:lightness:)` at that pixel's degree and
    /// percent, the bitmap handed to the screen holds those bytes, and each
    /// pixel's centre is drawn on the point that picks it.
    @Test func theBlockIsDrawnFromTheColourFunction() throws {
        let columns = HUDColourField.columns
        let rows = HUDColourField.rows
        #expect(columns == 361 && rows == 101)
        let colours = HUDColourField.fieldColours()
        #expect(colours.count == columns * rows)
        var mismatches: [String] = []
        for row in 0..<rows {
            let lightness = Double(rows - 1 - row) / 100
            for column in 0..<columns {
                let expected = HUDAccent.rgb(hue: Double(column), lightness: lightness)
                if colours[row * columns + column] != expected { mismatches.append("\(column)° \(lightness)") }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
        // Bottom row: today's colour of each hue; top row: white.
        #expect(colours[(rows - 1) * columns + 210] == HUDAccent.rgb(hue: 210))
        #expect(colours[0] == SRGB(255, 255, 255))

        let bytes = HUDColourField.fieldBytes()
        #expect(bytes.count == columns * rows * 4)
        let red = colours[(rows - 1) * columns + 12]
        let at = ((rows - 1) * columns + 12) * 4
        #expect(Double(bytes[at]) == (red.red * 255).rounded())
        #expect(bytes[at + 3] == 255)
        let image = try #require(HUDColourField.fieldImage)
        #expect(image.width == columns && image.height == rows)
        #expect((image.colorSpace?.name as String?) == (CGColorSpace.sRGB as String))
        let drawn = try #require(image.dataProvider?.data as Data?)
        #expect([UInt8](drawn) == bytes)

        // Pixel centres on the points they stand for.
        let size = CGSize(width: 360, height: 200)
        let frame = HUDColourField.imageFrame(size: size)
        let columnWidth = frame.width / CGFloat(columns)
        let rowHeight = frame.height / CGFloat(rows)
        for column in [0, 12, 210, 360] {
            let centre = frame.minX + (CGFloat(column) + 0.5) * columnWidth
            #expect(abs(centre - HUDColourField.point(hue: Double(column), lightness: 0, size: size).x) < 1e-9)
        }
        for row in [0, 40, 100] {
            let centre = frame.minY + (CGFloat(row) + 0.5) * rowHeight
            let lightness = Double(rows - 1 - row) / 100
            #expect(abs(centre - HUDColourField.point(hue: 0, lightness: lightness, size: size).y) < 1e-9)
        }
    }
}

/// A touch on the colour block (task 196 for the hue track; task 206 for
/// the block): a drag that starts in the block moves both values as it
/// goes, whichever way, and saves at the end; a tap sets and saves; a
/// cancelled drag, or Settings closing during one, saves what it set.
@Suite(.serialized) @MainActor struct HUDColourTouchTests {
    /// A block 360 by 100 points: one point across is one degree, one point
    /// up is one percent.
    private let size = CGSize(width: 360, height: 100)

    /// One call on a touch (`#expect` cannot hold a mutating call).
    private func step(_ touch: inout HUDColourTouch, _ call: (inout HUDColourTouch) -> HUDColourTouch.Write) -> HUDColourTouch.Write {
        call(&touch)
    }

    private func pick(_ hue: Double, _ lightness: Double) -> HUDColourPick {
        HUDColourPick(hue: hue, lightness: lightness)
    }

    /// A pan that never began (UIKit reports it failed) writes nothing and
    /// owes nothing.
    @Test func aPanThatNeverBeganChangesNothing() {
        var touch = HUDColourTouch()
        #expect(step(&touch) { $0.handle(.cancelled, at: CGPoint(x: 80, y: 40), size: size) } == .none)
        #expect(touch == HUDColourTouch())
    }

    @Test func aDragSetsBothValuesAsItMovesAndSavesAtTheEnd() {
        var touch = HUDColourTouch()
        #expect(step(&touch) { $0.handle(.began, at: CGPoint(x: 100, y: 100), size: size) } == .set(pick(100, 0), save: false))
        #expect(touch.owesSave)
        #expect(step(&touch) { $0.handle(.changed, at: CGPoint(x: 140.4, y: 60.2), size: size) } == .set(pick(140, 0.4), save: false))
        // Past the edges of the block it holds at the edges.
        #expect(step(&touch) { $0.handle(.changed, at: CGPoint(x: 500, y: -50), size: size) } == .set(pick(360, 1), save: false))
        #expect(step(&touch) { $0.handle(.ended, at: CGPoint(x: 210, y: 30), size: size) } == .set(pick(210, 0.7), save: true))
        // The end saved: the touch is reset and owes nothing.
        #expect(touch == HUDColourTouch())
    }

    /// The block's pan has no direction gate (the old hue track had one):
    /// a drag straight up or down moves only the lightness, sideways only
    /// the hue.
    @Test func aDragInAnyDirectionMovesTheMarker() {
        var touch = HUDColourTouch()
        #expect(step(&touch) { $0.handle(.began, at: CGPoint(x: 50, y: 90), size: size) } == .set(pick(50, 0.1), save: false))
        #expect(step(&touch) { $0.handle(.changed, at: CGPoint(x: 50, y: 20), size: size) } == .set(pick(50, 0.8), save: false))
        #expect(step(&touch) { $0.handle(.changed, at: CGPoint(x: 120, y: 20), size: size) } == .set(pick(120, 0.8), save: false))
        #expect(step(&touch) { $0.handle(.ended, at: CGPoint(x: 120, y: 20), size: size) } == .set(pick(120, 0.8), save: true))
    }

    /// A tap is SwiftUI's tap on the block, not the pan: the colour where
    /// it lands, in whole degrees and percent, saved.
    @Test func aTapSetsTheColourWhereItLands() {
        #expect(HUDColourTouch.tap(at: CGPoint(x: 0, y: 100), size: size) == .set(pick(0, 0), save: true))
        #expect(HUDColourTouch.tap(at: CGPoint(x: 89.6, y: 74.6), size: size) == .set(pick(90, 0.25), save: true))
        #expect(HUDColourTouch.tap(at: CGPoint(x: 150, y: 0), size: CGSize(width: 300, height: 168)) == .set(pick(180, 1), save: true))
        #expect(HUDColourTouch.tap(at: CGPoint(x: -5, y: 140), size: size) == .set(pick(0, 0), save: true))
    }

    /// UIKit ends a pan once, with `.ended` or with `.cancelled`/`.failed`;
    /// whichever comes, the colour is saved once and the next touch starts
    /// clean.
    @Test func theEndOrTheCancelSavesOnce() {
        var ended = HUDColourTouch()
        _ = ended.handle(.began, at: CGPoint(x: 30, y: 50), size: size)
        #expect(step(&ended) { $0.handle(.ended, at: CGPoint(x: 30, y: 50), size: size) } == .set(pick(30, 0.5), save: true))
        #expect(step(&ended) { $0.handle(.cancelled, at: CGPoint(x: 30, y: 50), size: size) } == .none)
        var cancelled = HUDColourTouch()
        _ = cancelled.handle(.began, at: CGPoint(x: 30, y: 50), size: size)
        _ = cancelled.handle(.changed, at: CGPoint(x: 60, y: 10), size: size)
        #expect(step(&cancelled) { $0.handle(.cancelled, at: CGPoint(x: 60, y: 10), size: size) } == .saveWaiting)
        #expect(step(&cancelled) { $0.handle(.cancelled, at: CGPoint(x: 60, y: 10), size: size) } == .none)
        #expect(cancelled == HUDColourTouch())
    }

    @Test func aCancelledDragSavesWhatItSet() throws {
        var touch = HUDColourTouch()
        _ = touch.handle(.began, at: CGPoint(x: 15, y: 50), size: size)
        #expect(step(&touch) { $0.handle(.cancelled, at: CGPoint(x: 15, y: 50), size: size) } == .saveWaiting)
        // A pan that never began owes nothing.
        var never = HUDColourTouch()
        #expect(step(&never) { $0.handle(.cancelled, at: CGPoint(x: 15, y: 50), size: size) } == .none)
        // What the view does with it: the colour written during the drag is
        // saved and kept, not undone.
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        store.setHUDColour(hue: 30, lightness: 0)
        store.setHUDColour(hue: 140, lightness: 0.6, save: false)
        #expect(context.hasChanges)
        store.saveHUDColour()
        #expect(!context.hasChanges)
        #expect(store.hudHue == 140)
        #expect(store.hudLightness == 0.6)
        // With nothing waiting it does nothing.
        store.saveHUDColour()
        #expect(store.hudHue == 140)
    }

    /// Settings closing during a drag: the colour reaches the store on disk.
    @Test func closingSettingsMidDragKeepsTheColour() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "HUDColourTouchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = LocalStore.Files(
            user: directory.appending(path: "default.store"),
            cache: directory.appending(path: "SkyCache.store")
        )
        do {
            let opened = try LocalStore.open(files)
            let store = SkyStore(context: opened.container.mainContext)
            store.setHUDColour(hue: 30, lightness: 0)
            store.setHUDColour(hue: 250, lightness: 0.85, save: false)
            // The section's onDisappear.
            store.saveHUDColour()
        }
        let again = try LocalStore.open(files)
        let rows = try ModelContext(again.container).fetch(FetchDescriptor<Settings>())
        #expect(rows.map(\.hudHue) == [250])
        #expect(rows.map(\.hudLightness) == [0.85])
    }
}

/// Set from an Observation `onChange`, which may run off the main actor.
private final class Told: @unchecked Sendable {
    var value = false
}
