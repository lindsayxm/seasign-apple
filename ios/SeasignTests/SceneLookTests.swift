import Foundation
import SwiftUI
import Testing

@testable import Seasign

/// Task 145: the v11 rules on real data — looks, ink, stars, weather amounts,
/// and the marks tied to the sun, moon and horizon.
private let newYork = TimeZone(identifier: "America/New_York")!
private let hour: TimeInterval = 3600
private let rise = instant("2026-11-16T11:41:00Z")  // 6:41 AM EST
private let set = instant("2026-11-16T21:31:00Z")  // 4:31 PM EST
private let dayPass = SkyPass(rise: rise, set: set)

private func scene(
    sun: SkyBodyState = .up(progress: 0.5),
    moon: SkyBodyState = .down(sinceSet: nil, untilRise: nil),
    phase: Double = 0.5,
    precipitation: Precipitation = .none,
    clouds: CloudLevel = .clear,
    live: Bool = true,
    wind: Double? = 8.4,
    sunPass: SkyPass = dayPass,
    moonPass: SkyPass = .unknown
) -> SceneState {
    SceneState(
        sun: sun,
        moon: moon,
        moonPhase: MoonPhase(fraction: phase),
        nightness: SceneState.nightness(for: sun),
        precipitation: precipitation,
        clouds: clouds,
        wind: .calm,
        temperatureF: live ? 55 : nil,
        hasCurrentWeather: live && wind != nil,
        timeZone: newYork,
        isLive: live,
        windMph: live ? wind : nil,
        sunPass: sunPass,
        moonPass: moonPass
    )
}

private let night = SkyBodyState.down(sinceSet: 4 * hour, untilRise: 9 * hour)

@Suite struct SceneLookTests {
    @Test func sunLooksFollowItsPlaceOnThePath() {
        #expect(scene(sun: .up(progress: 0.005)).look == .sunrise)
        #expect(scene(sun: .up(progress: 0.119)).look == .sunrise)
        #expect(scene(sun: .up(progress: 0.12)).look == .day)
        #expect(scene(sun: .up(progress: 0.88)).look == .day)
        #expect(scene(sun: .up(progress: 0.881)).look == .sunset)
        // A sun still sinking through the waterline keeps the sunset look.
        #expect(scene(sun: .down(sinceSet: 300, untilRise: 50_000)).look == .sunset)
        #expect(scene(sun: .down(sinceSet: 50_000, untilRise: 300)).look == .sunrise)
    }

    @Test func dayLooksFollowTheWeather() {
        #expect(scene(clouds: .few).look == .day)
        #expect(scene(clouds: .scattered).look == .cloudy)
        #expect(scene(clouds: .overcast).look == .cloudy)
        #expect(scene(precipitation: .rain(.light), clouds: .overcast).look == .rain)
        #expect(scene(precipitation: .snow(.heavy), clouds: .scattered).look == .snow)
        // Sunrise and sunset win over the weather.
        #expect(scene(sun: .up(progress: 0.02), precipitation: .rain(.light)).look == .sunrise)
    }

    @Test func nightLooks() {
        // In the twilight after the sun has gone under: dusk.
        #expect(scene(sun: .down(sinceSet: 20 * 60, untilRise: 50_000)).look == .dusk)
        // No moon: night.
        #expect(scene(sun: night).look == .night)
        // A low moon: dusk, even when it is full.
        #expect(scene(sun: night, moon: .up(progress: 0.05), phase: 0.5).look == .dusk)
        #expect(scene(sun: night, moon: .up(progress: 0.95), phase: 0.5).look == .dusk)
        // A moon more than 97 % lit and away from the horizon: full.
        #expect(scene(sun: night, moon: .up(progress: 0.5), phase: 0.5).look == .full)
        #expect(scene(sun: night, moon: .up(progress: 0.5), phase: 0.44).look == .night)
        #expect(scene(sun: night, moon: .up(progress: 0.36), phase: 0.25).look == .night)
        // A full moon below the horizon does not light the sky.
        #expect(scene(sun: night, phase: 0.5).look == .night)
    }

    @Test func inkFollowsTheLook() {
        #expect(scene(sun: .up(progress: 0.01)).ink == SceneRGB(255, 244, 190))
        #expect(scene(sun: .up(progress: 0.99)).ink == SceneRGB(255, 205, 186))
        for state in [scene(), scene(clouds: .overcast), scene(precipitation: .rain(.light)), scene(precipitation: .snow(.light))] {
            #expect(state.ink == SceneRGB(244, 216, 104))
        }
        for state in [scene(sun: night), scene(sun: night, moon: .up(progress: 0.5)), scene(sun: night, moon: .up(progress: 0.01))] {
            #expect(state.ink == SceneRGB(150, 232, 240))
        }
    }

    @Test func starsHideOnlyInAClearDaySky() {
        #expect(scene().starStrength == 0)
        #expect(!scene().showsStars)
        #expect(scene(clouds: .few).starStrength == 0)
        #expect(scene(clouds: .overcast).starStrength == 0.95)
        #expect(scene(precipitation: .rain(.light)).starStrength == 0.95)
        #expect(scene(sun: .up(progress: 0.01)).starStrength == 0.95)
        #expect(scene(sun: .up(progress: 0.99)).starStrength == 0.95)
        #expect(scene(sun: night).starStrength == 1.25)
        #expect(scene(sun: .down(sinceSet: 20 * 60, untilRise: 50_000)).starStrength == 1.25)
    }

    @Test func weatherAmountsAreKeptApartFromTheLook() {
        #expect(scene().cloudAmount == 0)
        #expect(scene(clouds: .few).cloudAmount == 0.3)
        #expect(scene(clouds: .overcast).cloudAmount == 0.8)
        #expect(scene(precipitation: .rain(.light), clouds: .scattered).cloudAmount == 1)
        #expect(scene(precipitation: .snow(.light), clouds: .overcast).cloudAmount == 0.6)
        // Rain at night is still rain round the moon.
        let wet = scene(sun: night, moon: .up(progress: 0.5), phase: 0.3, precipitation: .rain(.heavy), clouds: .overcast)
        #expect(wet.look == .night)
        #expect(wet.isRaining)
        #expect(!wet.isSnowing)
    }

    @Test func oneBodyAtATime() {
        let both = scene(sun: .up(progress: 0.5), moon: .up(progress: 0.3))
        #expect(both.body?.kind == .sun)
        let moon = scene(sun: night, moon: .up(progress: 0.3), moonPass: SkyPass(rise: set, set: nil))
        #expect(moon.body?.kind == .moon)
        #expect(moon.body?.pass == SkyPass(rise: set, set: nil))
        #expect(scene(sun: night).body == nil)
    }
}

@Suite struct SceneMarkRulesTests {
    @Test func tagOnlyAtTheEnds() {
        #expect(scene(sun: .up(progress: 0.049)).tagEdge == .rise)
        #expect(scene(sun: .up(progress: 0.05)).tagEdge == nil)
        #expect(scene(sun: .up(progress: 0.5)).tagEdge == nil)
        #expect(scene(sun: .up(progress: 0.95)).tagEdge == nil)
        #expect(scene(sun: .up(progress: 0.951)).tagEdge == .set)
        #expect(scene(sun: .up(progress: 0.99)).showsTag)
        #expect(!scene().showsTag)
    }

    @Test func squareOnlyAwayFromTheEnds() {
        #expect(!scene(sun: .up(progress: 0.05)).showsSquare)
        #expect(scene(sun: .up(progress: 0.051)).showsSquare)
        #expect(scene(sun: .up(progress: 0.949)).showsSquare)
        #expect(!scene(sun: .up(progress: 0.95)).showsSquare)
        #expect(!scene(sun: night).showsSquare)
    }

    @Test func theTimeUnderTheTagIsHidden() {
        let sunrise = scene(sun: .up(progress: 0.01))
        #expect(sunrise.riseMark == nil)
        #expect(sunrise.setMark == set)
        let midday = scene()
        #expect(midday.riseMark == rise)
        #expect(midday.setMark == set)
        let sunset = scene(sun: .up(progress: 0.99))
        #expect(sunset.riseMark == rise)
        #expect(sunset.setMark == nil)
    }

    @Test func tickCountIsTheRealSpan() {
        // 6:41 to 4:31 is 9 h 50 min: ten intervals, eleven ticks.
        #expect(scene().tickCount == 10)
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let marks = SceneMarks(state: scene(), layout: layout, clock: .twelveHour)
        #expect(marks.ticks.count == 11)
        #expect(marks.ticks.first == SceneMarks.Tick(x: 62, isEnd: true))
        #expect(abs((marks.ticks.last?.x ?? 0) - 331) < 1e-9)
        #expect(marks.ticks.dropFirst().dropLast().allSatisfy { !$0.isEnd })
    }

    @Test func labelsInBothClockStyles() {
        #expect(SceneState.markTime(rise, timeZone: newYork, clock: .twelveHour) == "6:41 AM")
        #expect(SceneState.markTime(rise, timeZone: newYork, clock: .twentyFourHour) == "06:41")
        #expect(SceneState.markTime(set, timeZone: newYork, clock: .twelveHour) == "4:31 PM")
        #expect(SceneState.markTime(set, timeZone: newYork, clock: .twentyFourHour) == "16:31")
        let midnight = instant("2026-11-16T05:05:00Z")
        #expect(SceneState.markTime(midnight, timeZone: newYork, clock: .twelveHour) == "12:05 AM")
        #expect(SceneState.markTime(midnight, timeZone: newYork, clock: .twentyFourHour) == "00:05")

        let sunrise = scene(sun: .up(progress: 0.01), wind: 6.4)
        #expect(sunrise.tagLines(clock: .twelveHour)?.title == "SUNRISE 6:41 AM")
        #expect(sunrise.tagLines(clock: .twelveHour)?.wind == "WIND 6 MPH")
        #expect(scene(sun: .up(progress: 0.99)).tagLines(clock: .twentyFourHour)?.title == "SUNSET 16:31")
        let moonset = scene(
            sun: night, moon: .up(progress: 0.99), wind: 10.5,
            moonPass: SkyPass(rise: instant("2026-11-15T22:12:00Z"), set: instant("2026-11-16T12:03:00Z"))
        )
        #expect(moonset.tagLines(clock: .twelveHour)?.title == "MOONSET 7:03 AM")
        #expect(moonset.tagLines(clock: .twelveHour)?.wind == "WIND 11 MPH")
        let moonrise = scene(sun: night, moon: .up(progress: 0.0), moonPass: SkyPass(rise: instant("2026-11-15T22:12:00Z"), set: nil))
        #expect(moonrise.tagLines(clock: .twelveHour)?.title == "MOONRISE 5:12 PM")
    }

    @Test func windIsLeftOutWithoutAFreshReading() {
        #expect(scene(wind: 8.4).windLabel == "WIND 8 MPH")
        #expect(scene(wind: 8.5).windLabel == "WIND 9 MPH")
        let stale = scene(sun: .up(progress: 0.01), wind: nil)
        #expect(stale.windLabel == nil)
        #expect(stale.showsTag)
        #expect(stale.tagLines(clock: .twelveHour)?.wind == nil)
    }

    @Test func aMissingRiseLeavesOutItsTickTimeAndTag() {
        let noRise = SkyPass(rise: nil, set: set)
        let early = scene(sun: .up(progress: 0.01), sunPass: noRise)
        #expect(early.tagEdge == nil)
        #expect(!early.showsTag)
        #expect(early.riseMark == nil)
        #expect(early.setMark == set)
        #expect(early.tickCount == nil)
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let marks = SceneMarks(state: early, layout: layout, clock: .twelveHour)
        #expect(marks.ticks == [SceneMarks.Tick(x: 331, isEnd: true)])
        #expect(marks.riseTime == nil)
        #expect(marks.setTime?.text == "4:31 PM")
        #expect(marks.tag == nil)

        let noSet = scene(sun: .up(progress: 0.99), sunPass: SkyPass(rise: rise, set: nil))
        #expect(!noSet.showsTag)
        let late = SceneMarks(state: noSet, layout: layout, clock: .twelveHour)
        #expect(late.ticks == [SceneMarks.Tick(x: 62, isEnd: true)])
        #expect(late.riseTime?.text == "6:41 AM")
        #expect(late.setTime == nil)

        let neither = SceneMarks(state: scene(sunPass: .unknown), layout: layout, clock: .twelveHour)
        #expect(neither.ticks.isEmpty)
        #expect(neither.riseTime == nil && neither.setTime == nil && neither.tag == nil)
        #expect(neither.square != nil)
    }

    @Test func theNeutralSceneHasNoTicksTimesTagOrWind() {
        let neutral = SceneState.make(snapshot: nil, now: instant("2026-11-16T12:05:00Z"), deviceTimeZone: newYork)
        // 07:05 on the 06–18 stand-in day: the sun is up near its rise.
        #expect(neutral.body?.kind == .sun)
        #expect((neutral.body?.placement.progress ?? 1) < 0.12)
        #expect(neutral.windMph == nil)
        #expect(neutral.windLabel == nil)
        #expect(neutral.tickCount == nil)
        #expect(!neutral.showsTag)
        #expect(neutral.riseMark == nil && neutral.setMark == nil)
        let atRise = SceneState.make(snapshot: nil, now: instant("2026-11-16T11:00:30Z"), deviceTimeZone: newYork)
        #expect(!atRise.showsTag)
        let marks = SceneMarks(state: atRise, layout: SceneLayout(size: CGSize(width: 393, height: 852)), clock: .twelveHour)
        #expect(marks.ticks.isEmpty)
        #expect(marks.tag == nil)
        #expect(marks.riseTime == nil && marks.setTime == nil)
        // A night with no body draws no marks at all.
        let dark = SceneMarks(state: scene(sun: night), layout: SceneLayout(size: CGSize(width: 393, height: 852)), clock: .twelveHour)
        #expect(dark == SceneMarks(state: scene(sun: night, sunPass: .unknown), layout: SceneLayout(size: CGSize(width: 393, height: 852)), clock: .twelveHour))
        #expect(dark.ticks.isEmpty && dark.square == nil && dark.dropLine == nil && dark.tag == nil)
    }

    @Test func dropLineOnlyWhenTheBodyIsWellAboveTheHorizon() {
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let high = SceneMarks(state: scene(), layout: layout, clock: .twelveHour)
        // Midday: a 12 pt sun at y 298; the line runs from 11 under it to the horizon.
        #expect(high.dropLine == SceneMarks.DropLine(x: 196.5, top: 298 + 12 + 11, bottom: 385))
        let low = SceneMarks(state: scene(sun: .up(progress: 0.06)), layout: layout, clock: .twelveHour)
        #expect(low.dropLine == nil)
    }

    @Test func tagStandsAboveTheBodyOnTheInsideOfThePath() throws {
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let sunrise = SceneMarks(state: scene(sun: .up(progress: 0)), layout: layout, clock: .twelveHour)
        let tag = try #require(sunrise.tag)
        #expect(!tag.flipped)
        // The mockup: radius 50.4, so 58.4 to the corner of the leader, the
        // text 23 further out and 20 above.
        #expect(abs(tag.corner.x - (62 + 58.4 + 23)) < 1e-9)
        #expect(abs(tag.corner.y - (386 - 58.4 - 20)) < 1e-9)
        #expect(tag.leader.count == 3)
        let sunset = SceneMarks(state: scene(sun: .up(progress: 1)), layout: layout, clock: .twelveHour)
        #expect(sunset.tag?.flipped == true)
        #expect(abs((sunset.tag?.corner.x ?? 0) - (331 - 58.4 - 23)) < 1e-9)
    }
}

/// Task 145: the renderer draws every kind of sky without crashing, including
/// a missing rise or set, the neutral scene and a night with no body up.
@MainActor
@Suite struct SceneRenderTests {
    private func render(_ state: SceneState, time: Double = SceneRenderer.stillTime) -> CGImage? {
        let renderer = SceneRenderer(
            state: state, clock: .twelveHour, time: time, grain: SceneImages.grain,
            moonFace: state.body?.kind == .moon ? SceneImages.moonFace(phase: state.moonPhase) : nil
        )
        let view = Canvas { context, size in renderer.draw(in: &context, size: size) }
            .frame(width: 393, height: 852)
        let image = ImageRenderer(content: view)
        image.scale = 1
        return image.cgImage
    }

    @Test func drawsEdgeCases() {
        let states: [SceneState] = [
            scene(sun: .up(progress: 0.01), sunPass: SkyPass(rise: nil, set: set)),
            scene(sun: .up(progress: 0.99), sunPass: SkyPass(rise: rise, set: nil)),
            scene(sun: .up(progress: 0.5), sunPass: .unknown),
            scene(sun: night),
            scene(sun: night, moon: .up(progress: 0.02), phase: 0.02, moonPass: SkyPass(rise: nil, set: nil)),
            scene(sun: night, moon: .up(progress: 0.5), precipitation: .snow(.heavy), clouds: .overcast),
            scene(precipitation: .rain(.heavy), clouds: .overcast, live: false),
            SceneState.make(snapshot: nil, now: instant("2026-11-16T12:05:00Z"), deviceTimeZone: newYork),
            SceneState.make(snapshot: nil, now: instant("2026-11-16T05:05:00Z"), deviceTimeZone: newYork),
        ]
        for state in states {
            let image = render(state, time: 123.4)
            #expect(image?.width == 393)
        }
    }
}
