import Foundation
import SwiftUI
import Testing

@testable import Seasign

/// Task 218: with no calendar the events box says "Add your calendar... ↑",
/// the arrow under the settings button at the top right. The zip prompt
/// (task 205) keeps its rule and wins while no zip is set; the narrow-box
/// rule holds on the iPhone SE.
@Suite struct TodayCalendarPromptTests {
    private let iPhone16 = CGSize(width: 393, height: 852)
    private let iPhone17 = CGSize(width: 402, height: 874)
    private let proMax = CGSize(width: 440, height: 956)
    private let se = CGSize(width: 375, height: 667)
    private let zone = TimeZone(identifier: "America/New_York")!

    private func layout(size: CGSize, zip: Bool = false, calendar: Bool = true, labels: [EventLabel] = []) -> TodayOverlayLayout {
        TodayOverlayLayout(size: size, labels: labels, showsZipPrompt: zip, showsCalendarPrompt: calendar)
    }

    private func label(_ title: String) -> EventLabel {
        let now = Date(timeIntervalSince1970: 1_794_846_960)
        let event = UpcomingEvent(link: UUID(), title: title, start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), allDay: false)
        return EventLabel(event: event, now: now, timeZone: zone, clock: .twelveHour)
    }

    @Test func theTextIsTheUsersWords() {
        #expect(TodayOverlayLayout.calendarPromptText == "Add your calendar... ↑")
    }

    /// The whole text on every phone, the iPhone SE included, never cut:
    /// the arrow is always there.
    @Test func thePromptIsWholeOnEveryScreen() {
        let expected: [(CGSize, String)] = [
            (se, "-- Add your calendar... ↑ /"),
            (iPhone16, "---- Add your calendar... ↑ /"),
            (iPhone17, "----- Add your calendar... ↑ /"),
            (proMax, "--------- Add your calendar... ↑ /"),
        ]
        for (size, text) in expected {
            let layout = layout(size: size)
            #expect(layout.eventRows.map(\.text) == [text], "\(size)")
            #expect(layout.promptIndex == nil)
            let inner = layout.eventsBox.width - 2 * TodayOverlayLayout.Mockup.tileBorder
            #expect(layout.eventRows[0].width <= inner + 0.5, "\(size)")
            #expect(layout.eventRows[0].spoken == TodayOverlayLayout.calendarPromptSpoken)
        }
    }

    /// The arrow stands under the settings button: its middle falls inside
    /// the button's 44-point target (`TodayView` centres the target on
    /// `settingsRect`) and at most 5 points left of the 24-point glyph
    /// (measured: 2 to 4 points left of it, as the row ends in " /"), on
    /// every screen, with the button above it.
    @Test func theArrowPointsAtTheSettingsButton() {
        let style = HUDType.eventRow
        for size in [se, iPhone16, iPhone17, proMax] {
            let layout = layout(size: size)
            let row = layout.eventRows[0]
            let before = String(row.text.prefix { $0 != "↑" })
            let arrowMid = row.origin.x + style.width(before) + style.width("↑") / 2
            let settings = layout.settingsRect
            #expect(settings.midX - 22 <= arrowMid && arrowMid <= settings.midX + 22,
                    "\(size): arrow at \(arrowMid), target \(settings.midX - 22)...\(settings.midX + 22)")
            #expect(arrowMid >= settings.minX - 5 && arrowMid <= settings.maxX,
                    "\(size): arrow at \(arrowMid), glyph \(settings.minX)...\(settings.maxX)")
            #expect(settings.maxY < row.origin.y)
        }
    }

    /// With no zip the zip prompt shows as before (its rule from task 205,
    /// short on a narrow box) and the calendar prompt waits.
    @Test func theZipPromptWinsWhileNoZipIsSet() {
        let expected: [(CGSize, String)] = [
            (se, "- Set zip code in Settings/"),
            (iPhone16, "-- Set zip code in Settings /"),
            (proMax, "-- Set your zip code in Settings /"),
        ]
        for (size, text) in expected {
            let layout = layout(size: size, zip: true)
            #expect(layout.eventRows.map(\.text) == [text], "\(size)")
            #expect(layout.promptIndex == 0)
        }
    }

    /// Without the flag (a calendar is connected) the empty box stays empty.
    @Test func withACalendarTheBoxHasNoPrompt() {
        for size in [se, iPhone16] {
            #expect(layout(size: size, calendar: false).eventRows.isEmpty)
            #expect(TodayOverlayLayout(size: size, labels: [], showsZipPrompt: false).eventRows.isEmpty)
        }
    }

    /// Events always take the rows; the prompt never pushes one out.
    @Test func eventsAreNeverReplacedByThePrompt() {
        let layout = layout(size: iPhone16, labels: [label("Standup")])
        #expect(layout.eventRows.count == 1)
        #expect(!layout.eventRows[0].text.contains("↑"))
    }

    /// When the prompt shows: no calendar link and Google never connected,
    /// and nothing to show. An expired Google connection is a calendar the
    /// person has (Settings asks them to connect again).
    @Test func thePromptShowsOnlyWithNoCalendarAtAll() {
        #expect(TodayOverlayLayout.showsCalendarPrompt(linkCount: 0, google: .notConnected, eventCount: 0))
        #expect(!TodayOverlayLayout.showsCalendarPrompt(linkCount: 1, google: .notConnected, eventCount: 0))
        #expect(!TodayOverlayLayout.showsCalendarPrompt(linkCount: 0, google: .connected, eventCount: 0))
        #expect(!TodayOverlayLayout.showsCalendarPrompt(linkCount: 0, google: .expired, eventCount: 0))
        // The DEBUG mockup events show with no calendar.
        #expect(!TodayOverlayLayout.showsCalendarPrompt(linkCount: 0, google: .notConnected, eventCount: 3))
    }
}
