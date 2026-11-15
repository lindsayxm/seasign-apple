import Foundation
import Testing

@testable import Seasign

/// A UTC instant from an ISO 8601 string, for readable fixtures.
func instant(_ text: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: text) else {
        fatalError("bad test instant \(text)")
    }
    return date
}

private let hour: TimeInterval = 3600

@Suite struct RiseSetTimelineTests {
    @Test func sunIsUpBetweenRiseAndSet() {
        let timeline = RiseSetTimeline(
            rises: [instant("2026-11-15T11:42:00Z")],
            sets: [instant("2026-11-15T21:42:00Z")],
            typicalTimeUp: RiseSetTimeline.sunTimeUp
        )
        #expect(timeline.state(at: instant("2026-11-15T11:42:00Z")) == .up(progress: 0))
        #expect(timeline.state(at: instant("2026-11-15T16:42:00Z")) == .up(progress: 0.5))
        let late = timeline.state(at: instant("2026-11-15T21:12:00Z"))
        #expect(abs((late.progress ?? 0) - 0.95) < 1e-9)
    }

    @Test func sunIsDownBeforeRiseAndAfterSet() {
        let timeline = RiseSetTimeline(
            rises: [instant("2026-11-15T11:42:00Z"), instant("2026-11-16T11:43:00Z")],
            sets: [instant("2026-11-15T21:42:00Z"), instant("2026-11-16T21:41:00Z")],
            typicalTimeUp: RiseSetTimeline.sunTimeUp
        )
        #expect(
            timeline.state(at: instant("2026-11-15T10:42:00Z"))
                == .down(sinceSet: nil, untilRise: hour)
        )
        #expect(
            timeline.state(at: instant("2026-11-15T22:42:00Z"))
                == .down(sinceSet: hour, untilRise: 13 * hour + 60)
        )
        // Exactly at sunset the sun has set.
        #expect(!timeline.state(at: instant("2026-11-15T21:42:00Z")).isUp)
    }

    /// Anchorage in June: the sun sets after local midnight, so "today's" sunset
    /// is an instant on the next local date and "tomorrow's" sunrise comes soon
    /// after it. The order of the instants decides, not the calendar date.
    @Test func sunsetOnTheNextLocalDate() {
        let timeline = RiseSetTimeline(
            // Local (UTC-8): rises 04:20 on the 20th and 21st.
            rises: [instant("2026-06-20T12:20:00Z"), instant("2026-06-21T12:20:00Z")],
            // Local: sets 00:10 on the 21st and 22nd.
            sets: [instant("2026-06-21T08:10:00Z"), instant("2026-06-22T08:10:00Z")],
            typicalTimeUp: RiseSetTimeline.sunTimeUp
        )
        // 23:50 local on the 20th: still up, close to setting.
        let beforeMidnight = timeline.state(at: instant("2026-06-21T07:50:00Z"))
        #expect(beforeMidnight.isUp)
        #expect((beforeMidnight.progress ?? 0) > 0.98)
        // 00:05 local on the 21st: the same arc, five minutes from setting.
        #expect(timeline.state(at: instant("2026-06-21T08:05:00Z")).isUp)
        // 02:00 local on the 21st: down, between the set and the next rise.
        #expect(
            timeline.state(at: instant("2026-06-21T10:00:00Z"))
                == .down(sinceSet: 110 * 60, untilRise: 140 * 60)
        )
    }

    /// The moon commonly sets in the morning and rises in the evening of the
    /// same date. Pairing that date's moonrise with its moonset would be wrong.
    @Test func moonThatSetsBeforeItRisesOnTheSameDate() {
        let timeline = RiseSetTimeline(
            rises: [instant("2026-11-15T22:00:00Z"), instant("2026-11-16T22:50:00Z")],
            sets: [instant("2026-11-15T11:00:00Z"), instant("2026-11-16T12:00:00Z")],
            typicalTimeUp: RiseSetTimeline.moonTimeUp
        )
        // Before the morning set: up, on an arc whose rise was the day before.
        let early = timeline.state(at: instant("2026-11-15T09:00:00Z"))
        #expect(early.isUp)
        // Up for 12.4 h ending at 11:00, so at 09:00 it is 10.4 h in.
        #expect(abs((early.progress ?? 0) - 10.4 / 12.4) < 1e-9)
        // Midday: down.
        #expect(!timeline.state(at: instant("2026-11-15T16:00:00Z")).isUp)
        // Evening: up again, between the evening rise and the next morning's set.
        let evening = timeline.state(at: instant("2026-11-16T05:00:00Z"))
        #expect(abs((evening.progress ?? 0) - 0.5) < 1e-9)
    }

    @Test func nullMoonsetIsEstimated() {
        // The moon rises today and does not set until after the data ends.
        let timeline = RiseSetTimeline(
            rises: [instant("2026-11-15T20:00:00Z"), nil],
            sets: [nil, nil],
            typicalTimeUp: RiseSetTimeline.moonTimeUp
        )
        let state = timeline.state(at: instant("2026-11-16T02:12:00Z"))
        #expect(abs((state.progress ?? 0) - 0.5) < 1e-9)
        // Long past the estimated set it is no longer shown as up.
        #expect(!timeline.state(at: instant("2026-11-16T12:00:00Z")).isUp)
    }

    @Test func nullMoonriseIsEstimated() {
        // No moonrise in the data; it sets this evening.
        let timeline = RiseSetTimeline(
            rises: [nil],
            sets: [instant("2026-11-15T20:00:00Z")],
            typicalTimeUp: RiseSetTimeline.moonTimeUp
        )
        let state = timeline.state(at: instant("2026-11-15T13:48:00Z"))
        #expect(abs((state.progress ?? 0) - 0.5) < 1e-9)
        #expect(!timeline.state(at: instant("2026-11-15T21:00:00Z")).isUp)
    }

    @Test func missingRiseBetweenTwoSets() {
        let timeline = RiseSetTimeline(
            rises: [nil, nil],
            sets: [instant("2026-11-15T06:00:00Z"), instant("2026-11-16T07:00:00Z")],
            typicalTimeUp: RiseSetTimeline.moonTimeUp
        )
        #expect(!timeline.state(at: instant("2026-11-15T08:00:00Z")).isUp)
        #expect(timeline.state(at: instant("2026-11-16T03:00:00Z")).isUp)
    }

    @Test func noEventsFollowsTheHint() {
        let timeline = RiseSetTimeline(rises: [nil], sets: [nil], typicalTimeUp: RiseSetTimeline.sunTimeUp)
        let now = instant("2026-06-21T12:00:00Z")
        #expect(timeline.state(at: now, upWhenUnknown: true) == .up(progress: 0.5))
        #expect(timeline.state(at: now, upWhenUnknown: false) == .down(sinceSet: nil, untilRise: nil))
    }
}

@Suite struct SkyArcTests {
    @Test func arcRunsFromHorizonToPeakAndBack() {
        #expect(SkyArc.altitude(progress: 0) == 0)
        #expect(abs(SkyArc.altitude(progress: 0.5) - 1) < 1e-12)
        #expect(abs(SkyArc.altitude(progress: 1)) < 1e-12)
        #expect(SkyArc.altitude(progress: 0.25) > SkyArc.altitude(progress: 0.1))
    }

    @Test func sunMovesLeftToRightAsInTheMockups() {
        #expect(abs(SkyArc.horizontal(progress: 0) - 0.4) < 1e-12)
        #expect(abs(SkyArc.horizontal(progress: 0.5) - 0.5) < 1e-12)
        #expect(abs(SkyArc.horizontal(progress: 1) - 0.6) < 1e-12)
    }

    @Test func layoutMatchesTheMockupMeasurements() {
        // iPhone 16: 393 x 852 pt, the size of the mockups.
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        // Sunrise: a 141 pt sun centred on the waterline at 40 % of the width.
        let sunrise = layout.bodyCenter(progress: 0)
        #expect(abs(sunrise.x - 157.2) < 0.01)
        #expect(abs(sunrise.y - layout.horizonY) < 0.01)
        #expect(abs(layout.sunRadius(progress: 0) - 141) < 0.01)
        // Midday: a 29.5 pt sun at the centre, 194 pt above the water.
        let midday = layout.bodyCenter(progress: 0.5)
        #expect(abs(midday.x - 196.5) < 0.01)
        #expect(abs(midday.y - (layout.horizonY - 194)) < 0.01)
        #expect(abs(layout.sunRadius(progress: 0.5) - 29.5) < 0.01)
        // The horizon sits just below the middle of the screen (1296 / 2556).
        #expect(abs(layout.horizonY / 852 - 0.507) < 0.001)
    }
}

@Suite struct MoonPhaseTests {
    @Test func illuminationFollowsTheCycle() {
        #expect(abs(MoonPhase(fraction: 0).illuminatedFraction) < 1e-12)
        #expect(abs(MoonPhase(fraction: 0.25).illuminatedFraction - 0.5) < 1e-12)
        #expect(abs(MoonPhase(fraction: 0.5).illuminatedFraction - 1) < 1e-12)
        #expect(abs(MoonPhase(fraction: 0.75).illuminatedFraction - 0.5) < 1e-12)
    }

    @Test func litSideIsRightWhenWaxingAndLeftWhenWaning() {
        #expect(MoonPhase(fraction: 0.196).isWaxing)
        #expect(MoonPhase(fraction: 0.35).isWaxing)
        #expect(!MoonPhase(fraction: 0.65).isWaxing)
        #expect(!MoonPhase(fraction: 0.9).isWaxing)
    }

    @Test func terminatorRunsFromLitLimbToFarLimb() {
        #expect(abs(MoonPhase(fraction: 0).terminator - 1) < 1e-12)
        #expect(abs(MoonPhase(fraction: 0.25).terminator) < 1e-12)
        #expect(abs(MoonPhase(fraction: 0.5).terminator + 1) < 1e-12)
        // A crescent's terminator is on the lit side of centre, a gibbous moon's beyond it.
        #expect(MoonPhase(fraction: 0.1).terminator > 0)
        #expect(MoonPhase(fraction: 0.35).terminator < 0)
        #expect(MoonPhase(fraction: 0.65).terminator < 0)
        #expect(MoonPhase(fraction: 0.9).terminator > 0)
    }

    @Test func fractionWraps() {
        #expect(abs(MoonPhase(fraction: 1.25).fraction - 0.25) < 1e-12)
        #expect(abs(MoonPhase(fraction: -0.25).fraction - 0.75) < 1e-12)
        #expect(MoonPhase(fraction: 1).fraction == 0)
    }

    @Test func names() {
        #expect(MoonPhase(fraction: 0).name == "new moon")
        #expect(MoonPhase(fraction: 0.196).name == "waxing crescent moon")
        #expect(MoonPhase(fraction: 0.35).name == "waxing gibbous moon")
        #expect(MoonPhase(fraction: 0.5).name == "full moon")
        #expect(MoonPhase(fraction: 0.65).name == "waning gibbous moon")
        #expect(MoonPhase(fraction: 0.99).name == "new moon")
    }

    /// The lit area of the drawn shape should equal the illuminated fraction.
    @Test func litPathAreaMatchesIllumination() {
        for fraction in [0.1, 0.25, 0.35, 0.5, 0.65, 0.75, 0.9] {
            let phase = MoonPhase(fraction: fraction)
            let path = SceneRenderer.litMoonPath(phase: phase, center: .zero, radius: 1)
            // Count sample points of the unit disc that fall inside the path.
            var inside = 0
            var total = 0
            for xi in -40...40 {
                for yi in -40...40 {
                    let point = CGPoint(x: Double(xi) / 40.5, y: Double(yi) / 40.5)
                    guard point.x * point.x + point.y * point.y < 1 else { continue }
                    total += 1
                    if path.contains(point) { inside += 1 }
                }
            }
            let share = Double(inside) / Double(total)
            #expect(abs(share - phase.illuminatedFraction) < 0.03, "phase \(fraction)")
            // And it is on the correct side.
            let litPoint = CGPoint(x: phase.isWaxing ? 0.97 : -0.97, y: 0)
            if phase.illuminatedFraction > 0.05 {
                #expect(path.contains(litPoint), "phase \(fraction)")
            }
        }
    }

    @Test func approximatePhaseIsCloseToAKnownFullMoon() {
        // Full moon of 24 November 2026, about 14:54 UTC.
        let phase = MoonPhase.approximate(at: instant("2026-11-24T14:54:00Z"))
        #expect(abs(phase.fraction - 0.5) < 0.04)
    }
}

@Suite struct WeatherMappingTests {
    @Test(arguments: [0, 1, 2, 3, 45, 48, 4, 100, -1])
    func dryCodes(code: Int) {
        #expect(Precipitation(weatherCode: code) == .none)
    }

    @Test func rainCodes() {
        for code in [51, 53, 56, 61, 66, 80] {
            #expect(Precipitation(weatherCode: code) == .rain(.light), "code \(code)")
        }
        for code in [55, 57, 63, 81] {
            #expect(Precipitation(weatherCode: code) == .rain(.moderate), "code \(code)")
        }
        for code in [65, 67, 82, 95, 96, 99] {
            #expect(Precipitation(weatherCode: code) == .rain(.heavy), "code \(code)")
        }
    }

    @Test func snowCodes() {
        for code in [71, 77, 85] {
            #expect(Precipitation(weatherCode: code) == .snow(.light), "code \(code)")
        }
        #expect(Precipitation(weatherCode: 73) == .snow(.moderate))
        for code in [75, 86] {
            #expect(Precipitation(weatherCode: code) == .snow(.heavy), "code \(code)")
        }
    }

    @Test func cloudThresholds() {
        #expect(CloudLevel(coverPercent: 0, weatherCode: 0) == .clear)
        #expect(CloudLevel(coverPercent: 19.9, weatherCode: 0) == .clear)
        #expect(CloudLevel(coverPercent: 20, weatherCode: 1) == .few)
        #expect(CloudLevel(coverPercent: 49.9, weatherCode: 1) == .few)
        #expect(CloudLevel(coverPercent: 50, weatherCode: 2) == .scattered)
        #expect(CloudLevel(coverPercent: 79.9, weatherCode: 2) == .scattered)
        #expect(CloudLevel(coverPercent: 80, weatherCode: 3) == .overcast)
        #expect(CloudLevel(coverPercent: 100, weatherCode: 3) == .overcast)
    }

    @Test func weatherCodeCanOnlyRaiseTheCloudLevel() {
        #expect(CloudLevel(coverPercent: 5, weatherCode: 2) == .few)
        #expect(CloudLevel(coverPercent: 5, weatherCode: 3) == .overcast)
        #expect(CloudLevel(coverPercent: 5, weatherCode: 45) == .overcast)
        #expect(CloudLevel(coverPercent: 5, weatherCode: 63) == .scattered)
        #expect(CloudLevel(coverPercent: 5, weatherCode: 73) == .scattered)
        #expect(CloudLevel(coverPercent: 95, weatherCode: 0) == .overcast)
    }

    @Test func windThresholds() {
        #expect(WindLevel(speedMph: 9.3, gustsMph: 20) == .calm)
        #expect(WindLevel(speedMph: 14.9, gustsMph: 24.9) == .calm)
        #expect(WindLevel(speedMph: 15, gustsMph: 0) == .windy)
        #expect(WindLevel(speedMph: 9.3, gustsMph: 25.1) == .windy)
        #expect(WindLevel(speedMph: 30, gustsMph: 30) == .gale)
        #expect(WindLevel(speedMph: 20, gustsMph: 45) == .gale)
    }
}
