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

    /// Task 161: no stars while the sun is up, whatever the weather; they
    /// fade out through sunrise and in through sunset.
    @Test func starsShowOnlyFromSunsetToSunrise() {
        #expect(scene().starStrength == 0)
        #expect(!scene().showsStars)
        #expect(scene(clouds: .few).starStrength == 0)
        #expect(scene(clouds: .overcast).starStrength == 0)
        #expect(scene(precipitation: .rain(.light)).starStrength == 0)
        #expect(scene(precipitation: .snow(.light)).starStrength == 0)
        // Sunrise: strongest on the horizon, gone where the look ends.
        #expect(scene(sun: .up(progress: 0)).starStrength == 0.95)
        #expect(abs(scene(sun: .up(progress: 0.06)).starStrength - 0.475) < 1e-9)
        #expect(scene(sun: .up(progress: 0.1199)).starStrength < 0.01)
        #expect(scene(sun: .up(progress: 0.12)).starStrength == 0)
        // Sunset: the same, mirrored.
        #expect(scene(sun: .up(progress: 0.88)).starStrength == 0)
        #expect(abs(scene(sun: .up(progress: 0.94)).starStrength - 0.475) < 1e-9)
        #expect(scene(sun: .up(progress: 1)).starStrength == 0.95)
        // Weather does not bring them back at a low sun's far end either.
        #expect(scene(sun: .up(progress: 0.5), precipitation: .rain(.light), clouds: .overcast).starStrength == 0)
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
    @Test func aTimeIsHiddenOnlyAtItsEnd() {
        #expect(scene(sun: .up(progress: 0.049)).hiddenTimeEdge == .rise)
        #expect(scene(sun: .up(progress: 0.05)).hiddenTimeEdge == nil)
        #expect(scene(sun: .up(progress: 0.5)).hiddenTimeEdge == nil)
        #expect(scene(sun: .up(progress: 0.95)).hiddenTimeEdge == nil)
        #expect(scene(sun: .up(progress: 0.951)).hiddenTimeEdge == .set)
        #expect(scene().hiddenTimeEdge == nil)
        // The written times follow the same bounds.
        #expect(scene(sun: .up(progress: 0.049)).riseMark == nil)
        #expect(scene(sun: .up(progress: 0.05)).riseMark == rise)
        #expect(scene(sun: .up(progress: 0.95)).setMark == set)
        #expect(scene(sun: .up(progress: 0.951)).setMark == nil)
    }

    @Test func squareOnlyAwayFromTheEnds() {
        #expect(!scene(sun: .up(progress: 0.05)).showsSquare)
        #expect(scene(sun: .up(progress: 0.051)).showsSquare)
        #expect(scene(sun: .up(progress: 0.949)).showsSquare)
        #expect(!scene(sun: .up(progress: 0.95)).showsSquare)
        #expect(!scene(sun: night).showsSquare)
    }

    @Test func theTimeUnderTheBodyIsHidden() {
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

        // At the ends the body's own time is hidden and the other end's is
        // written, in the phone's clock style.
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let sunset = SceneMarks(state: scene(sun: .up(progress: 0.99)), layout: layout, clock: .twentyFourHour)
        #expect(sunset.riseTime?.text == "06:41")
        #expect(sunset.setTime == nil)
        let moonset = scene(
            sun: night, moon: .up(progress: 0.99), wind: 10.5,
            moonPass: SkyPass(rise: instant("2026-11-15T22:12:00Z"), set: instant("2026-11-16T12:03:00Z"))
        )
        let moonsetMarks = SceneMarks(state: moonset, layout: layout, clock: .twelveHour)
        #expect(moonsetMarks.riseTime?.text == "5:12 PM")
        #expect(moonsetMarks.setTime == nil)
        let moonrise = scene(sun: night, moon: .up(progress: 0.0), moonPass: SkyPass(rise: instant("2026-11-15T22:12:00Z"), set: nil))
        #expect(moonrise.hiddenTimeEdge == .rise)
        #expect(SceneMarks(state: moonrise, layout: layout, clock: .twelveHour).riseTime == nil)
    }

    @Test func windIsLeftOutWithoutAFreshReading() {
        #expect(scene(wind: 8.4).windLabel == "WIND 8 MPH")
        #expect(scene(wind: 8.5).windLabel == "WIND 9 MPH")
        // At the ends too: the wind line no longer gives way to anything.
        #expect(scene(sun: .up(progress: 0.01), wind: 6.4).windLabel == "WIND 6 MPH")
        #expect(scene(sun: night, moon: .up(progress: 0.99), wind: 10.5).windLabel == "WIND 11 MPH")
        let stale = scene(sun: .up(progress: 0.01), wind: nil)
        #expect(stale.windLabel == nil)
    }

    @Test func aMissingRiseLeavesOutItsTickAndTime() {
        let noRise = SkyPass(rise: nil, set: set)
        let early = scene(sun: .up(progress: 0.01), sunPass: noRise)
        #expect(early.hiddenTimeEdge == nil)
        #expect(early.riseMark == nil)
        #expect(early.setMark == set)
        #expect(early.tickCount == nil)
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let marks = SceneMarks(state: early, layout: layout, clock: .twelveHour)
        #expect(marks.ticks == [SceneMarks.Tick(x: 331, isEnd: true)])
        #expect(marks.riseTime == nil)
        #expect(marks.setTime?.text == "4:31 PM")

        let noSet = scene(sun: .up(progress: 0.99), sunPass: SkyPass(rise: rise, set: nil))
        #expect(noSet.hiddenTimeEdge == nil)
        let late = SceneMarks(state: noSet, layout: layout, clock: .twelveHour)
        #expect(late.ticks == [SceneMarks.Tick(x: 62, isEnd: true)])
        #expect(late.riseTime?.text == "6:41 AM")
        #expect(late.setTime == nil)

        let neither = SceneMarks(state: scene(sunPass: .unknown), layout: layout, clock: .twelveHour)
        #expect(neither.ticks.isEmpty)
        #expect(neither.riseTime == nil && neither.setTime == nil)
        #expect(neither.square != nil)
    }

    @Test func theNeutralSceneHasNoTicksTimesOrWind() {
        let neutral = SceneState.make(snapshot: nil, now: instant("2026-11-16T12:05:00Z"), deviceTimeZone: newYork)
        // 07:05 on the 06–18 stand-in day: the sun is up near its rise.
        #expect(neutral.body?.kind == .sun)
        #expect((neutral.body?.placement.progress ?? 1) < 0.12)
        #expect(neutral.windMph == nil)
        #expect(neutral.windLabel == nil)
        #expect(neutral.tickCount == nil)
        #expect(neutral.hiddenTimeEdge == nil)
        #expect(neutral.riseMark == nil && neutral.setMark == nil)
        let atRise = SceneState.make(snapshot: nil, now: instant("2026-11-16T11:00:30Z"), deviceTimeZone: newYork)
        #expect(atRise.hiddenTimeEdge == nil)
        let marks = SceneMarks(state: atRise, layout: SceneLayout(size: CGSize(width: 393, height: 852)), clock: .twelveHour)
        #expect(marks.ticks.isEmpty)
        #expect(marks.riseTime == nil && marks.setTime == nil)
        // A night with no body draws no marks at all.
        let dark = SceneMarks(state: scene(sun: night), layout: SceneLayout(size: CGSize(width: 393, height: 852)), clock: .twelveHour)
        #expect(dark == SceneMarks(state: scene(sun: night, sunPass: .unknown), layout: SceneLayout(size: CGSize(width: 393, height: 852)), clock: .twelveHour))
        #expect(dark.ticks.isEmpty && dark.square == nil && dark.dropLine == nil)
    }

    @Test func dropLineOnlyWhenTheBodyIsWellAboveTheHorizon() {
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let high = SceneMarks(state: scene(), layout: layout, clock: .twelveHour)
        // Midday: a 12 pt sun at y 298; the line runs from 11 under it to the horizon.
        #expect(high.dropLine == SceneMarks.DropLine(x: 196.5, top: 298 + 12 + 11, bottom: 385))
        let low = SceneMarks(state: scene(sun: .up(progress: 0.06)), layout: layout, clock: .twelveHour)
        #expect(low.dropLine == nil)
    }

    @Test func lightFadesAsTheDiscGoesUnder() throws {
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let up = try #require(scene().body.map(layout.drawnBody))
        #expect(up.light == 1)
        // Ten of the fifteen minutes after sunset: two thirds under, a third of its light.
        let sinking = try #require(scene(sun: .down(sinceSet: 600, untilRise: 50_000)).body.map(layout.drawnBody))
        #expect(abs(sinking.light - 1.0 / 3) < 1e-9)
        #expect(sinking.progress == 1)
        #expect(sinking.center.y > layout.horizonY)
    }

    @Test func weatherAndGlintsCentreOnTheBodyOrThePath() throws {
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let body = try #require(scene(sun: .up(progress: 0.3)).body.map(layout.drawnBody))
        #expect(layout.weatherCenter(body) == body.center)
        #expect(layout.glintCenterX(body) == body.center.x)
        // No body up: the top of the path, and mid-sea.
        #expect(layout.weatherCenter(nil) == CGPoint(x: 196.5, y: 298))
        #expect(layout.glintCenterX(nil) == 196.5)
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

    /// RGBA pixels of `image`, drawn into a known sRGB layout.
    private func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, width, height)
    }

    private func brightness(_ p: (bytes: [UInt8], width: Int, height: Int), x: Int, y: Int) -> Int {
        let i = (y * p.width + x) * 4
        return max(Int(p.bytes[i]), Int(p.bytes[i + 1]), Int(p.bytes[i + 2]))
    }

    /// Task 147, item 2: the skies with a missing rise or set are really
    /// drawn: the sky is lit, not left black, and the disc is bright where
    /// the layout puts it.
    @Test func skiesWithAMissingEndAreDrawn() throws {
        let layout = SceneLayout(size: CGSize(width: 393, height: 852))
        let skies = [
            scene(sun: .up(progress: 0.01), sunPass: SkyPass(rise: nil, set: set)),
            scene(sun: .up(progress: 0.99), sunPass: SkyPass(rise: rise, set: nil)),
            scene(sun: night, moon: .up(progress: 0.03), phase: 0.5, moonPass: SkyPass(rise: nil, set: set)),
            scene(sun: night, moon: .up(progress: 0.97), phase: 0.5, moonPass: SkyPass(rise: rise, set: nil)),
        ]
        for state in skies {
            let image = try #require(render(state))
            let p = pixels(image)
            #expect(p.width == 393 && p.height == 852)
            // The low sky, under the dark veil at the top, is lit nearly everywhere.
            var lit = 0
            var total = 0
            for y in stride(from: 290, to: 384, by: 2) {
                for x in stride(from: 0, to: 393, by: 2) {
                    total += 1
                    if brightness(p, x: x, y: y) > 12 { lit += 1 }
                }
            }
            #expect(lit > total / 2, "the sky is not drawn: \(lit) of \(total) lit")
            // The disc: bright a little above its centre (its lower half is under the water).
            let body = try #require(state.body.map(layout.drawnBody))
            let x = Int(body.center.x)
            let y = Int(body.center.y - body.radius / 2)
            #expect(brightness(p, x: x, y: y) > 150, "the disc is not drawn")
            // The black above the drawing is not mistaken for the scene: the
            // bottom corner of the sea stays dark.
            #expect(brightness(p, x: 2, y: 849) < 80)
        }
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

/// Task 147, item 3: from a real multi-day `/v1/sky` response through
/// `SceneState.make` to the marks on the horizon. New York, 15 and 16
/// November 2026 (`skyJSON10001`).
@Suite struct SnapshotToMarksTests {
    private let layout = SceneLayout(size: CGSize(width: 393, height: 852))

    private func marks(at now: String, fetched: String) async throws -> (SceneState, SceneMarks) {
        let sky = try await snapshot(fetchedAt: instant(fetched))
        let state = SceneState.make(snapshot: sky, now: instant(now), deviceTimeZone: newYork)
        return (state, SceneMarks(state: state, layout: layout, clock: .twelveHour))
    }

    @Test func middayOnTheFifteenth() async throws {
        let (state, marks) = try await marks(at: "2026-11-15T16:40:00Z", fetched: "2026-11-15T16:00:00Z")
        #expect(state.body?.kind == .sun)
        // Sunrise 11:42:55Z to sunset 21:37:53Z: 9 h 55 min, ten intervals.
        #expect(state.tickCount == 10)
        #expect(marks.ticks.count == 11)
        #expect(marks.riseTime?.text == "6:42 AM")
        #expect(marks.setTime?.text == "4:37 PM")
        #expect(marks.square != nil)
        #expect(marks.dropLine != nil)
        #expect(state.windLabel == "WIND 9 MPH")
    }

    @Test func justAfterSunrise() async throws {
        let (state, marks) = try await marks(at: "2026-11-15T11:44:00Z", fetched: "2026-11-15T11:30:00Z")
        #expect(state.look == .sunrise)
        // The sunrise time is hidden while the sun sits on it; the wind
        // line still shows.
        #expect(state.hiddenTimeEdge == .rise)
        #expect(state.windLabel == "WIND 9 MPH")
        #expect(marks.riseTime == nil)
        #expect(marks.setTime?.text == "4:37 PM")
        #expect(marks.square == nil)
    }

    @Test func theMoonInTheEvening() async throws {
        // 17:05 EST: the sun set 27 minutes ago; the moon rose at 12:01 PM and sets at 9:49 PM.
        let (state, marks) = try await marks(at: "2026-11-15T22:05:00Z", fetched: "2026-11-15T22:00:00Z")
        #expect(state.body?.kind == .moon)
        #expect(state.look == .dusk)
        #expect(state.tickCount == 10)
        #expect(marks.riseTime?.text == "12:01 PM")
        #expect(marks.setTime?.text == "9:49 PM")
        #expect(state.hiddenTimeEdge == nil)

        // 21:47 EST, two minutes before the moon sets (02:49Z on the 16th).
        let (late, lateMarks) = try await self.marks(at: "2026-11-16T02:47:00Z", fetched: "2026-11-16T02:00:00Z")
        #expect(late.body?.kind == .moon)
        #expect(late.hiddenTimeEdge == .set)
        #expect(late.windLabel != nil)
        #expect(lateMarks.riseTime?.text == "12:01 PM")
        #expect(lateMarks.setTime == nil)
    }

    @Test func theNextDayUsesItsOwnTimes() async throws {
        // 00:10 EST on the 16th: nothing up, so nothing marked.
        let (night, nightMarks) = try await marks(at: "2026-11-16T05:10:00Z", fetched: "2026-11-16T05:00:00Z")
        #expect(night.body == nil)
        #expect(nightMarks == SceneMarks(state: night, layout: layout, clock: .twentyFourHour))
        #expect(nightMarks.ticks.isEmpty && nightMarks.riseTime == nil)
        // 13:00 EST on the 16th: that day's sunrise and sunset, 24-hour.
        let sky = try await snapshot(fetchedAt: instant("2026-11-16T17:30:00Z"))
        let day = SceneState.make(snapshot: sky, now: instant("2026-11-16T18:00:00Z"), deviceTimeZone: newYork)
        let dayMarks = SceneMarks(state: day, layout: layout, clock: .twentyFourHour)
        #expect(dayMarks.riseTime?.text == "06:44")
        #expect(dayMarks.setTime?.text == "16:37")
        #expect(day.tickCount == 10)
    }
}

/// Task 147, item 5: VoiceOver hears the rise and set times. Task 148: in
/// every position, with no tag; the wind line speaks the wind itself.
@Suite struct SceneSpokenMarksTests {
    @Test func timesAreSpokenAwayFromTheEnds() {
        #expect(scene().accessibilityDescription(clock: .twelveHour)
            == "The sun is up, clear sky over the water. Sunrise 6:41 AM, sunset 4:31 PM.")
        #expect(scene().accessibilityDescription(clock: .twentyFourHour)
            == "The sun is up, clear sky over the water. Sunrise 06:41, sunset 16:31.")
    }

    @Test func bothTimesAreSpokenAtTheEndsToo() {
        // The time hidden under the body is still spoken; the wind is not
        // (the wind line under the header has its own label).
        #expect(scene(sun: .up(progress: 0.01), wind: 6.4).accessibilityDescription(clock: .twelveHour)
            == "The sun is up, clear sky over the water. Sunrise 6:41 AM, sunset 4:31 PM.")
        #expect(scene(sun: .up(progress: 0.99)).accessibilityDescription(clock: .twentyFourHour)
            == "The sun is up, clear sky over the water. Sunrise 06:41, sunset 16:31.")
        #expect(scene(sun: .up(progress: 0.99), wind: nil).accessibilityDescription(clock: .twelveHour)
            == "The sun is up over the water. Sunrise 6:41 AM, sunset 4:31 PM.")
        let moonset = scene(
            sun: night, moon: .up(progress: 0.99), phase: 0.3, wind: 10.5,
            moonPass: SkyPass(rise: instant("2026-11-15T22:12:00Z"), set: instant("2026-11-16T12:03:00Z"))
        )
        #expect(moonset.accessibilityDescription(clock: .twelveHour)
            == "Night, waxing gibbous moon, clear sky over the water. Moonrise 5:12 PM, moonset 7:03 AM.")
    }

    @Test func unknownTimesAndTheNeutralSceneAreNotSpoken() {
        let moon = scene(sun: night, moon: .up(progress: 0.5), phase: 0.3, moonPass: SkyPass(rise: nil, set: set))
        #expect(moon.accessibilityDescription(clock: .twelveHour)
            == "Night, waxing gibbous moon, clear sky over the water. Moonset 4:31 PM.")
        #expect(scene(sun: night).accessibilityDescription(clock: .twelveHour) == "Night, clear sky over the water.")
        let neutral = SceneState.make(snapshot: nil, now: instant("2026-11-16T17:00:00Z"), deviceTimeZone: newYork)
        #expect(neutral.accessibilityDescription(clock: .twelveHour) == "The sun is up over the water.")
    }
}
