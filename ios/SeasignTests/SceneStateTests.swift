import Foundation
import Testing

@testable import Seasign

private let newYork = TimeZone(identifier: "America/New_York")!
private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

@Suite struct SkySnapshotTests {
    /// Task 3 review, note 4: a real payload decodes through the generated
    /// client, with second-precision UTC instants.
    @Test func decodesARealPayload() async throws {
        let fetched = instant("2026-11-15T23:05:00Z")
        let sky = try await snapshot(fetchedAt: fetched)
        #expect(sky.zip == "10001")
        #expect(sky.placeName == "New York")
        #expect(sky.region == "New York")
        #expect(sky.timeZone == newYork)
        #expect(sky.current.observedAt == instant("2026-11-15T23:00:00Z"))
        #expect(sky.current.temperatureF == 43.4)
        #expect(sky.current.isDay == false)
        #expect(sky.days.count == 2)
        #expect(sky.days[0].sunrise == instant("2026-11-15T11:42:55Z"))
        #expect(sky.days[0].moonset == instant("2026-11-16T02:49:21Z"))
        #expect(sky.days[1].moonPhase == 0.226)
        #expect(sky.fetchedAt == fetched)
    }

    @Test func decodesNullSunAndMoonTimes() async throws {
        let sky = try await snapshot(zip: "99723", json: skyJSONPolar, fetchedAt: instant("2026-06-21T20:00:00Z"))
        #expect(sky.region == nil)
        #expect(sky.days[0].sunrise == nil)
        #expect(sky.days[0].sunset == nil)
        #expect(sky.days[0].moonrise == nil)
        #expect(sky.days[0].moonset == nil)
    }

    @Test func survivesTheCacheRoundTrip() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-15T23:05:00Z"))
        let decoded = try JSONDecoder().decode(SkySnapshot.self, from: JSONEncoder().encode(sky))
        #expect(decoded == sky)
    }

    /// Task 3 review, note 1: today is found by its date, not by index.
    @Test func picksTodayByDateNotByIndex() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-15T23:05:00Z"))
        // 23:59 EST on the 15th.
        #expect(sky.day(containing: instant("2026-11-16T04:59:00Z"))?.date == "2026-11-15")
        // 00:05 EST on the 16th: days[0] is now yesterday.
        #expect(sky.day(containing: instant("2026-11-16T05:05:00Z"))?.date == "2026-11-16")
        // Two days later the cache has no entry for today.
        #expect(sky.day(containing: instant("2026-11-18T15:00:00Z")) == nil)
    }

    @Test func localDateUsesThePlaceZoneAndTheGregorianCalendar() {
        let late = instant("2026-11-16T06:00:00Z")
        #expect(SkySnapshot.localDateString(for: late, in: newYork) == "2026-11-16")
        #expect(SkySnapshot.localDateString(for: late, in: losAngeles) == "2026-11-15")
    }
}

@Suite struct SceneStateTests {
    @Test func eveningInNewYork() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-15T23:05:00Z"))
        // 17:05 EST: 27 minutes after the 16:37 sunset, moon up until 21:49.
        let state = SceneState.make(snapshot: sky, now: instant("2026-11-15T22:05:00Z"), deviceTimeZone: losAngeles)
        #expect(state.isLive)
        #expect(!state.sun.isUp)
        #expect(state.moon.isUp)
        #expect(state.showsMoon)
        #expect(state.moonPhase.fraction == 0.196)
        #expect(state.temperatureF == 43.4)
        #expect(state.timeZone == newYork)
        #expect(state.clouds == .clear)
        // Gusts of 25.1 mph make it windy although the sustained wind is light.
        #expect(state.wind == .windy)
        #expect(state.precipitation == .none)
        // Dusk: part way between day and night.
        #expect(state.nightness > 0.6 && state.nightness < 0.7)
    }

    @Test func middayInNewYork() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-15T16:00:00Z"))
        let noon = instant("2026-11-15T16:40:24Z")
        let state = SceneState.make(snapshot: sky, now: noon, deviceTimeZone: losAngeles)
        #expect(abs((state.sun.progress ?? 0) - 0.5) < 0.001)
        #expect(state.nightness == 0)
        // The moon does not rise until 12:01 EST.
        #expect(!state.moon.isUp)
        #expect(!state.showsStars)
    }

    @Test func daytimeMoonIsNotDrawn() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-15T16:00:00Z"))
        // 15:00 EST: sun and moon are both up.
        let state = SceneState.make(snapshot: sky, now: instant("2026-11-15T20:00:00Z"), deviceTimeZone: newYork)
        #expect(state.sun.isUp)
        #expect(state.moon.isUp)
        #expect(!state.showsMoon)
    }

    /// The moon set on the next local date (02:49Z on the 16th is 21:49 EST on
    /// the 15th here, but a late-night moonset works the same way): after local
    /// midnight the scene uses tomorrow's entry and the same instants.
    @Test func afterLocalMidnightUsesTheNextEntry() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-16T05:00:00Z"))
        // 00:10 EST on the 16th.
        let state = SceneState.make(snapshot: sky, now: instant("2026-11-16T05:10:00Z"), deviceTimeZone: newYork)
        #expect(state.isLive)
        #expect(state.moonPhase.fraction == 0.226)
        #expect(!state.sun.isUp)
        #expect(!state.moon.isUp)
        #expect(state.nightness == 1)
    }

    @Test func polarDayFollowsIsDay() async throws {
        let now = instant("2026-06-21T20:00:00Z")
        var sky = try await snapshot(zip: "99723", json: skyJSONPolar, fetchedAt: now)
        var state = SceneState.make(snapshot: sky, now: now, deviceTimeZone: newYork)
        #expect(state.isLive)
        #expect(state.sun == .up(progress: 0.5))
        #expect(state.nightness == 0)
        #expect(!state.moon.isUp)
        #expect(state.clouds == .overcast)

        // Polar night: the same nulls with isDay false.
        sky.current.isDay = false
        state = SceneState.make(snapshot: sky, now: now, deviceTimeZone: newYork)
        #expect(state.sun == .down(sinceSet: nil, untilRise: nil))
        #expect(state.nightness == 1)
        #expect(state.showsStars)
    }

    /// Task 17, item 2. The sun rose at 02:40 and does not set: it must not be
    /// taken down twelve hours later.
    @Test func sunriseWithoutSunsetStaysUp() async throws {
        let anchorage = TimeZone(identifier: "America/Anchorage")!
        var sky = try await snapshot(
            zip: "99723", json: skyJSONSunriseWithoutSunset, fetchedAt: instant("2026-05-10T20:00:00Z")
        )
        func state(_ now: String) -> SceneState {
            SceneState.make(snapshot: sky, now: instant(now), deviceTimeZone: anchorage)
        }
        // 02:00 local: before the known sunrise the sun is down, 40 minutes from rising.
        #expect(state("2026-05-10T10:00:00Z").sun == .down(sinceSet: nil, untilRise: 40 * 60))
        // 03:40: an hour up, climbing at the usual pace.
        #expect(abs((state("2026-05-10T11:40:00Z").sun.progress ?? 0) - 1.0 / 12) < 1e-9)
        // 15:30, nearly 13 hours after sunrise: still up, at the top of the arc.
        let afternoon = state("2026-05-10T23:30:00Z")
        #expect(afternoon.sun == .up(progress: 0.5))
        #expect(afternoon.nightness == 0)
        #expect(!afternoon.showsStars)
        // 23:00 local, more than 20 hours after sunrise.
        #expect(state("2026-05-11T07:00:00Z").sun == .up(progress: 0.5))

        // If the API says it is not day, that is believed over any day length...
        sky.current.isDay = false
        #expect(state("2026-05-10T23:30:00Z").sun == .down(sinceSet: nil, untilRise: nil))
        // ...unless the reading was taken before the sunrise that has since happened.
        sky.current.observedAt = instant("2026-05-10T09:00:00Z")
        #expect(state("2026-05-10T12:40:00Z").sun.isUp)
    }

    /// Task 17, item 2. No sunrise today and a sunset at 23:40: the sun has
    /// been up all day, not for the twelve hours before it sets.
    @Test func sunsetWithoutSunriseIsUpUntilItSets() async throws {
        let anchorage = TimeZone(identifier: "America/Anchorage")!
        var sky = try await snapshot(
            zip: "99723", json: skyJSONSunsetWithoutSunrise, fetchedAt: instant("2026-08-02T20:00:00Z")
        )
        func state(_ now: String) -> SceneState {
            SceneState.make(snapshot: sky, now: instant(now), deviceTimeZone: anchorage)
        }
        // 02:00 local, almost 22 hours before the sunset: up, at the top of the arc.
        let early = state("2026-08-02T10:00:00Z")
        #expect(early.sun == .up(progress: 0.5))
        #expect(early.nightness == 0)
        // 20:40, three hours before sunset: coming down.
        #expect(abs((state("2026-08-03T04:40:00Z").sun.progress ?? 0) - 0.75) < 1e-9)
        // 23:39: about to set.
        #expect((state("2026-08-03T07:39:00Z").sun.progress ?? 0) > 0.99)
        // 23:50: set ten minutes ago, the next sunrise is known.
        #expect(state("2026-08-03T07:50:00Z").sun == .down(sinceSet: 600, untilRise: 140 * 60))

        // With isDay false there is no reason to think the sun is up before the set.
        sky.current.isDay = false
        let dark = state("2026-08-02T21:00:00Z")
        #expect(!dark.sun.isUp)
        #expect(dark.nightness == 1)
    }

    /// Task 17, item 1. A cache that still covers today keeps placing the sun
    /// and moon, but a reading older than three hours is not shown as current.
    @Test func oldReadingKeepsSunAndMoonButNotTheWeather() async throws {
        var sky = try await snapshot(fetchedAt: instant("2026-11-15T23:05:00Z"))
        sky.current.weatherCode = 63
        sky.current.cloudCoverPercent = 95

        // 20:05 EST, exactly three hours after the fetch: still current.
        let fresh = SceneState.make(snapshot: sky, now: instant("2026-11-16T02:05:00Z"), deviceTimeZone: newYork)
        #expect(fresh.hasCurrentWeather)
        #expect(fresh.temperatureF == 43.4)
        #expect(fresh.precipitation == .rain(.moderate))
        #expect(fresh.wind == .windy)

        // 20:10 EST, five minutes later: the same sky without the reading.
        let stale = SceneState.make(snapshot: sky, now: instant("2026-11-16T02:10:00Z"), deviceTimeZone: newYork)
        #expect(stale.isLive)
        #expect(!stale.hasCurrentWeather)
        #expect(stale.temperatureF == nil)
        #expect(stale.precipitation == .none)
        #expect(stale.clouds == .clear)
        #expect(stale.wind == .calm)
        // Sun and moon are unchanged: night, the moon up until 21:49.
        #expect(stale.sun == fresh.sun.shifted(by: 300))
        #expect(stale.moon.isUp)
        #expect(stale.showsMoon)
        #expect(stale.moonPhase.fraction == 0.196)
        #expect(stale.timeZone == newYork)
        // VoiceOver is not told about weather that is not known.
        #expect(stale.accessibilityDescription == "Night, waxing crescent moon over the water.")
        #expect(fresh.accessibilityDescription == "Night, waxing crescent moon, rain, windy over the water.")
    }

    @Test func freshnessIsMeasuredFromWhenTheSkyWasFetched() async throws {
        let fetched = instant("2026-11-15T23:05:00Z")
        let sky = try await snapshot(fetchedAt: fetched)
        #expect(SkySnapshot.currentMaxAge == 3 * 3600)
        #expect(sky.currentIsFresh(at: fetched))
        #expect(sky.currentIsFresh(at: fetched.addingTimeInterval(3 * 3600)))
        #expect(!sky.currentIsFresh(at: fetched.addingTimeInterval(3 * 3600 + 1)))
        // A clock set back to long before the fetch is no better.
        #expect(sky.currentIsFresh(at: fetched.addingTimeInterval(-60)))
        #expect(!sky.currentIsFresh(at: fetched.addingTimeInterval(-4 * 3600)))
    }

    @Test func neutralSceneHasNoCurrentWeather() {
        let state = SceneState.make(snapshot: nil, now: instant("2026-11-15T20:00:00Z"), deviceTimeZone: losAngeles)
        #expect(!state.hasCurrentWeather)
        #expect(state.accessibilityDescription == "The sun is up over the water.")
    }

    /// Task 17, item 3. The moon waits until none of the sun shows.
    @Test func sunSinksBeforeTheMoonShows() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-15T21:40:00Z"))
        // Sunset is 21:37:53Z. Six minutes later the sun is 40 % under.
        let sinking = SceneState.make(snapshot: sky, now: instant("2026-11-15T21:43:53Z"), deviceTimeZone: newYork)
        #expect(!sinking.sun.isUp)
        #expect(sinking.sunPlacement?.progress == 1)
        #expect(abs((sinking.sunPlacement?.sunk ?? 0) - 0.4) < 1e-9)
        #expect(sinking.moon.isUp)
        #expect(!sinking.showsMoon)
        // Fifteen minutes after sunset it is gone and the moon is drawn.
        let gone = SceneState.make(snapshot: sky, now: instant("2026-11-15T21:52:53Z"), deviceTimeZone: newYork)
        #expect(gone.sunPlacement == nil)
        #expect(gone.showsMoon)
    }

    @Test func staleCacheFallsBackToTheNeutralSceneInThePlaceZone() async throws {
        let sky = try await snapshot(fetchedAt: instant("2026-11-15T23:05:00Z"))
        // Three days later, 12:00 EST.
        let state = SceneState.make(snapshot: sky, now: instant("2026-11-18T17:00:00Z"), deviceTimeZone: losAngeles)
        #expect(!state.isLive)
        #expect(state.temperatureF == nil)
        #expect(state.timeZone == newYork)
        #expect(abs((state.sun.progress ?? 0) - 0.5) < 1e-9)
        #expect(state.clouds == .clear)
        #expect(state.wind == .calm)
    }

    @Test func noZipIsTheNeutralSceneOnThePhoneClock() {
        // 12:00 PST.
        let noon = SceneState.make(snapshot: nil, now: instant("2026-11-15T20:00:00Z"), deviceTimeZone: losAngeles)
        #expect(!noon.isLive)
        #expect(noon.temperatureF == nil)
        #expect(noon.timeZone == losAngeles)
        #expect(abs((noon.sun.progress ?? 0) - 0.5) < 1e-9)
        #expect(noon.precipitation == .none)

        // 00:00 PST: night, moon at the top of its arc.
        let midnight = SceneState.make(snapshot: nil, now: instant("2026-11-16T08:00:00Z"), deviceTimeZone: losAngeles)
        #expect(!midnight.sun.isUp)
        #expect(midnight.showsMoon)
        #expect(abs((midnight.moon.progress ?? 0) - 0.5) < 1e-9)
        #expect(midnight.nightness == 1)
    }

    @Test func twilightBlendsDayIntoNight() {
        #expect(SceneState.nightness(for: .up(progress: 0.99)) == 0)
        #expect(SceneState.nightness(for: .down(sinceSet: 0, untilRise: 50_000)) == 0)
        #expect(SceneState.nightness(for: .down(sinceSet: 20 * 60, untilRise: 50_000)) == 0.5)
        #expect(SceneState.nightness(for: .down(sinceSet: 30_000, untilRise: 10 * 60)) == 0.25)
        #expect(SceneState.nightness(for: .down(sinceSet: 3 * 3600, untilRise: nil)) == 1)
    }

    @Test func headerDateUsesThePlaceZone() {
        // 01:00 EST on Monday the 16th is still 22:00 PST on Sunday the 15th.
        let now = instant("2026-11-16T06:00:00Z")
        let east = HeaderDate(now: now, timeZone: newYork)
        #expect(east.month == "NOV")
        #expect(east.day == "16")
        #expect(east.weekday == "Mon")
        let west = HeaderDate(now: now, timeZone: losAngeles)
        #expect(west.day == "15")
        #expect(west.weekday == "Sun")
        #expect(west.spoken == "Sunday, November 15")
    }
}

#if DEBUG
@Suite struct SceneDebugOverrideTests {
    private func state(_ override: SceneDebugOverride, at now: Date) async throws -> SceneState {
        let sky = try await snapshot(fetchedAt: now)
        let inputs = override.apply(to: sky, now: now, deviceTimeZone: newYork)
        return SceneState.make(snapshot: inputs.snapshot, now: inputs.now, deviceTimeZone: newYork)
    }

    @Test func inactiveOverrideChangesNothing() async throws {
        let now = instant("2026-11-15T16:00:00Z")
        let sky = try await snapshot(fetchedAt: now)
        let override = SceneDebugOverride(time: "", moon: "", weather: "nonsense")
        #expect(!override.isActive)
        let inputs = override.apply(to: sky, now: now, deviceTimeZone: newYork)
        #expect(inputs.snapshot == sky)
        #expect(inputs.now == now)
    }

    @Test func forcedTimesPutTheSunWhereTheMockupsDo() async throws {
        let now = instant("2026-11-15T23:05:00Z")
        let sunrise = try await state(SceneDebugOverride(time: "sunrise"), at: now)
        #expect((sunrise.sun.progress ?? 1) < 0.001)
        let midday = try await state(SceneDebugOverride(time: "midday"), at: now)
        #expect(abs((midday.sun.progress ?? 0) - 0.5) < 0.001)
        let sunset = try await state(SceneDebugOverride(time: "sunset"), at: now)
        #expect((sunset.sun.progress ?? 0) > 0.999)
    }

    /// Task 17, item 3: a named time with an offset in minutes.
    @Test func offsetsStepAcrossTheHorizon() async throws {
        let now = instant("2026-11-15T23:05:00Z")
        #expect(SceneDebugOverride(time: "sunrise-5").offsetMinutes == -5)
        #expect(SceneDebugOverride(time: "sunset+7.5").offsetMinutes == 7.5)
        #expect(SceneDebugOverride(time: "sunset").offsetMinutes == nil)
        #expect(!SceneDebugOverride(time: "sunrise-").isActive)
        #expect(!SceneDebugOverride(time: "dawn+5").isActive)

        let before = try await state(SceneDebugOverride(time: "sunrise-5"), at: now)
        #expect(before.sun == .down(sinceSet: nil, untilRise: 300))
        #expect(abs((before.sunPlacement?.sunk ?? 0) - 1.0 / 3) < 1e-9)
        // The moved clock does not make the reading stale.
        #expect(before.temperatureF == 43.4)
        let at = try await state(SceneDebugOverride(time: "sunrise+0"), at: now)
        #expect(at.sunPlacement == SkyPlacement(progress: 0, sunk: 0))
        let after = try await state(SceneDebugOverride(time: "sunrise+5"), at: now)
        #expect((after.sun.progress ?? 0) > 0.008)
        let set = try await state(SceneDebugOverride(time: "sunset+7.5"), at: now)
        #expect(set.sunPlacement == SkyPlacement(progress: 1, sunk: 0.5))
        let late = try await state(SceneDebugOverride(time: "night+90", weather: "cloudy"), at: now)
        #expect(late.nightness == 1)
        #expect(late.clouds == .overcast)
    }

    @Test func forcedNightShowsTheMoonAtTheTopOfItsArc() async throws {
        let night = try await state(SceneDebugOverride(moon: "0.65"), at: instant("2026-11-15T16:00:00Z"))
        #expect(night.showsMoon)
        #expect(abs((night.moon.progress ?? 0) - 0.5) < 1e-9)
        #expect(night.moonPhase.fraction == 0.65)
        #expect(night.nightness == 1)
    }

    @Test func forcedWeather() async throws {
        let now = instant("2026-11-15T16:00:00Z")
        let cloudy = try await state(SceneDebugOverride(weather: "cloudy"), at: now)
        #expect(cloudy.clouds == .overcast)
        #expect(cloudy.wind == .calm)
        let windy = try await state(SceneDebugOverride(weather: "windy"), at: now)
        #expect(windy.wind == .windy)
        #expect(windy.clouds == .clear)
        let rain = try await state(SceneDebugOverride(weather: "rain"), at: now)
        #expect(rain.precipitation == .rain(.moderate))
        let snow = try await state(SceneDebugOverride(weather: "snow"), at: now)
        #expect(snow.precipitation == .snow(.moderate))
    }

    @Test func worksWithoutAZip() {
        let now = instant("2026-11-15T20:00:00Z")
        let inputs = SceneDebugOverride(time: "sunset", weather: "windy")
            .apply(to: nil, now: now, deviceTimeZone: newYork)
        let state = SceneState.make(snapshot: inputs.snapshot, now: inputs.now, deviceTimeZone: newYork)
        #expect((state.sun.progress ?? 0) > 0.999)
        #expect(state.wind == .windy)
    }
}
#endif

private extension SkyBodyState {
    /// The same state `seconds` later, for a body that stays down.
    func shifted(by seconds: TimeInterval) -> SkyBodyState {
        guard case .down(let sinceSet, let untilRise) = self else { return self }
        return .down(sinceSet: sinceSet.map { $0 + seconds }, untilRise: untilRise.map { $0 - seconds })
    }
}
