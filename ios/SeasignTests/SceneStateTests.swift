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
