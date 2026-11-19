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

/// Task 145: the v11 path, a circle's top segment centred on the screen.
@Suite struct SkyPathTests {
    @Test func pathRunsFromHorizonToTopAndBack() {
        let rise = SkyPath.offset(progress: 0)
        #expect(abs(rise.x + 134.5) < 1e-9)
        #expect(abs(rise.height) < 1e-9)
        let top = SkyPath.offset(progress: 0.5)
        #expect(abs(top.x) < 1e-9)
        #expect(abs(top.height - 88) < 1e-9)
        let set = SkyPath.offset(progress: 1)
        #expect(abs(set.x - 134.5) < 1e-9)
        #expect(abs(set.height) < 1e-9)
        // Out-of-range progress stays on the path.
        #expect(SkyPath.offset(progress: -0.2) == SkyPath.offset(progress: 0))
        #expect(SkyPath.offset(progress: 1.3) == SkyPath.offset(progress: 1))
    }

    @Test func bodyIsLargeOnTheHorizonAndSmallHigh() {
        #expect(SkyPath.lowness(height: 0) == 1)
        #expect(SkyPath.lowness(height: 88) == 0)
        #expect(abs(SkyPath.lowness(height: 44) - 0.25) < 1e-12)
        #expect(abs(SkyPath.bodyRadius(progress: 0) - 50.4) < 1e-9)
        #expect(abs(SkyPath.bodyRadius(progress: 1) - 50.4) < 1e-9)
        #expect(abs(SkyPath.bodyRadius(progress: 0.5) - 12) < 1e-9)
    }

    @Test func layoutMatchesTheMockup() {
        // iPhone 16: 393 x 852 pt, the size of the mockup.
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        #expect(layout.scale == 1)
        #expect(layout.horizonY == 386)
        #expect(layout.headlinesTop == 486)
        #expect(abs(layout.pathPoint(progress: 0).x - 62) < 1e-9)
        #expect(abs(layout.pathPoint(progress: 1).x - 331) < 1e-9)
        #expect(abs(layout.pathPoint(progress: 0.5).y - 298) < 1e-9)
        // A wider phone scales everything with the width.
        let wide = SceneLayout(size: CGSize(width: 440, height: 956))
        #expect(abs(wide.horizonY - 386 * 440 / 393) < 1e-9)
        #expect(abs(wide.bodyRadius(progress: 0.5) - 12 * 440 / 393) < 1e-9)
    }
}

/// Task 17, item 3: discs cross the waterline gradually.
@Suite struct HorizonCrossingTests {
    private let crossing = SkyArc.horizonCrossing

    @Test func aBodyOnItsArcIsNotSunk() {
        #expect(SkyBodyState.up(progress: 0.3).placement() == SkyPlacement(progress: 0.3, sunk: 0))
    }

    @Test func risesOutOfTheWaterBeforeRising() {
        func rising(in seconds: TimeInterval) -> SkyPlacement? {
            SkyBodyState.down(sinceSet: 9 * hour, untilRise: seconds).placement()
        }
        #expect(crossing == 15 * 60)
        #expect(rising(in: crossing + 1) == nil)
        // Exactly one crossing away the disc would be fully under: not drawn.
        #expect(rising(in: crossing) == nil)
        #expect(rising(in: crossing / 2) == SkyPlacement(progress: 0, sunk: 0.5))
        // At the moment of rising it is where the arc starts: half above the water.
        #expect(rising(in: 0) == SkyBodyState.up(progress: 0).placement())
    }

    @Test func sinksIntoTheWaterAfterSetting() {
        func set(_ seconds: TimeInterval) -> SkyPlacement? {
            SkyBodyState.down(sinceSet: seconds, untilRise: nil).placement()
        }
        #expect(set(0) == SkyBodyState.up(progress: 1).placement())
        #expect(set(crossing / 3) == SkyPlacement(progress: 1, sunk: 1.0 / 3))
        #expect(set(crossing) == nil)
        #expect(SkyBodyState.down(sinceSet: nil, untilRise: nil).placement() == nil)
    }

    /// A short night: the nearer event decides which end of the arc it is at.
    @Test func theNearerEventDecidesTheSide() {
        #expect(SkyBodyState.down(sinceSet: 300, untilRise: 600).placement()?.progress == 1)
        #expect(SkyBodyState.down(sinceSet: 600, untilRise: 300).placement()?.progress == 0)
    }

    /// The visible top of the sun must only go up from first light to midday,
    /// and by no more than a few points a minute: no popping in, no dip as the
    /// disc shrinks. A ten-hour day on an iPhone 16.
    @Test func theTopOfTheSunOnlyRisesThroughTheMorning() {
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let rise = instant("2026-11-15T11:42:00Z")
        let timeline = RiseSetTimeline(
            rises: [rise],
            sets: [rise.addingTimeInterval(10 * hour)],
            typicalTimeUp: RiseSetTimeline.sunTimeUp
        )
        func top(atMinute minute: Double) -> CGFloat {
            let now = rise.addingTimeInterval(minute * 60)
            let sighting = SkySighting(isUp: minute >= 0, at: now)
            guard let placement = timeline.state(at: now, sighting: sighting).placement() else { return 0 }
            let radius = layout.bodyRadius(progress: placement.progress)
            return layout.horizonY - (layout.bodyCenter(placement, radius: radius).y - radius)
        }
        #expect(top(atMinute: -15) == 0)
        #expect(abs(top(atMinute: 0) - 50.4) < 0.01)
        var previous = top(atMinute: -15)
        for step in 1...(4 * (15 + 300)) {
            let minute = -15 + Double(step) / 4
            let now = top(atMinute: minute)
            #expect(now >= previous - 1e-9, "the top of the sun drops at minute \(minute)")
            #expect(now - previous < 3, "the sun jumps at minute \(minute)")
            previous = now
        }
        // Midday: a 12 pt disc at the top of the path, 88 pt up.
        #expect(abs(top(atMinute: 300) - 100) < 0.01)
    }
}

/// Task 145: the rise and set instants of the pass the drawn body is on.
@Suite struct SkyPassTests {
    private let rise = instant("2026-11-15T11:42:00Z")
    private var set: Date { rise.addingTimeInterval(9 * hour + 50 * 60) }

    @Test func upBetweenAKnownRiseAndSet() {
        let timeline = RiseSetTimeline(rises: [rise], sets: [set], typicalTimeUp: RiseSetTimeline.sunTimeUp)
        let pass = timeline.pass(at: rise.addingTimeInterval(3 * hour))
        #expect(pass == SkyPass(rise: rise, set: set))
        // 9 h 50 min is ten hourly intervals.
        #expect(pass.hourCount == 10)
    }

    @Test func crossingTheWaterlineBelongsToTheNearPass() {
        let timeline = RiseSetTimeline(
            rises: [rise, rise.addingTimeInterval(24 * hour)], sets: [set],
            typicalTimeUp: RiseSetTimeline.sunTimeUp
        )
        // Five minutes before rising: the coming pass.
        #expect(timeline.pass(at: rise.addingTimeInterval(-300)) == SkyPass(rise: rise, set: set))
        // Five minutes after setting: the pass that just ended.
        #expect(timeline.pass(at: set.addingTimeInterval(300)) == SkyPass(rise: rise, set: set))
        // Late at night, nearer the next rise, whose set is not known.
        let late = timeline.pass(at: rise.addingTimeInterval(23 * hour))
        #expect(late == SkyPass(rise: rise.addingTimeInterval(24 * hour), set: nil))
        #expect(late.hourCount == nil)
    }

    @Test func aMissingEndIsUnknownNotEstimated() {
        let noSet = RiseSetTimeline(rises: [rise], sets: [nil], typicalTimeUp: RiseSetTimeline.moonTimeUp)
        #expect(noSet.pass(at: rise.addingTimeInterval(hour)) == SkyPass(rise: rise, set: nil))
        let noRise = RiseSetTimeline(rises: [nil], sets: [set], typicalTimeUp: RiseSetTimeline.moonTimeUp)
        #expect(noRise.pass(at: set.addingTimeInterval(-hour)) == SkyPass(rise: nil, set: set))
        let none = RiseSetTimeline(rises: [], sets: [], typicalTimeUp: RiseSetTimeline.sunTimeUp)
        #expect(none.pass(at: rise) == .unknown)
    }

    @Test func shortSpansStillHaveOneInterval() {
        #expect(SkyPass(rise: rise, set: rise.addingTimeInterval(20 * 60)).hourCount == 1)
        #expect(SkyPass(rise: rise, set: rise).hourCount == nil)
        #expect(SkyPass(rise: rise, set: rise.addingTimeInterval(14 * hour + 29 * 60)).hourCount == 14)
    }
}

@Suite struct SunWithoutADayLengthTests {
    private let noon = instant("2026-06-21T20:00:00Z")
    private func timeline(rises: [Date?], sets: [Date?]) -> RiseSetTimeline {
        RiseSetTimeline(rises: rises, sets: sets, typicalTimeUp: RiseSetTimeline.sunTimeUp)
    }

    @Test func knownArcIgnoresTheSighting() {
        let line = timeline(rises: [noon.addingTimeInterval(-5 * hour)], sets: [noon.addingTimeInterval(5 * hour)])
        #expect(line.state(at: noon, sighting: SkySighting(isUp: false, at: noon)) == .up(progress: 0.5))
        let after = noon.addingTimeInterval(6 * hour)
        #expect(
            line.state(at: after, sighting: SkySighting(isUp: true, at: after))
                == .down(sinceSet: hour, untilRise: nil)
        )
    }

    @Test func noEventsFollowsTheSighting() {
        let line = timeline(rises: [nil], sets: [nil])
        #expect(line.state(at: noon, sighting: SkySighting(isUp: true, at: noon)) == .up(progress: 0.5))
        #expect(
            line.state(at: noon, sighting: SkySighting(isUp: false, at: noon))
                == .down(sinceSet: nil, untilRise: nil)
        )
    }

    @Test func twoSetsInARowDoNotInventASunrise() {
        let line = timeline(rises: [nil, nil], sets: [noon.addingTimeInterval(-20 * hour), noon.addingTimeInterval(4 * hour)])
        // Seen up: up, coming down to the known set.
        let up = line.state(at: noon, sighting: SkySighting(isUp: true, at: noon))
        #expect(abs((up.progress ?? 0) - (1 - 4.0 / 12)) < 1e-9)
        // Seen down before the earlier set, nothing since says it rose.
        let down = line.state(at: noon, sighting: SkySighting(isUp: true, at: noon.addingTimeInterval(-30 * hour)))
        #expect(down == .down(sinceSet: 20 * hour, untilRise: nil))
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
