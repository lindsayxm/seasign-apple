import Foundation

/// Everything the scene and the Today header need to know at one instant,
/// derived from a sky snapshot and a clock. A value type: the Canvas captures
/// one of these and nothing else.
struct SceneState: Equatable, Sendable {
    var sun: SkyBodyState
    var moon: SkyBodyState
    var moonPhase: MoonPhase
    /// 0 in daylight, 1 at night, in between for 40 minutes after sunset and
    /// before sunrise.
    var nightness: Double
    var precipitation: Precipitation
    var clouds: CloudLevel
    var wind: WindLevel
    /// Nil when there is no current reading to show.
    var temperatureF: Double?
    /// False when there is no reading recent enough to show as the weather
    /// now: the neutral scene, or a cached sky older than
    /// `SkySnapshot.currentMaxAge`. The scene is then clear and calm and the
    /// header shows no temperature.
    var hasCurrentWeather: Bool
    /// The zone the header's date and the sun's clock are read in.
    var timeZone: TimeZone
    /// False when the scene is the neutral stand-in, not the user's zip.
    var isLive: Bool

    /// How long dusk and dawn last, in seconds.
    static let twilight: TimeInterval = 40 * 60

    /// Where the sun's disc is, nil when none of it is above the waterline.
    var sunPlacement: SkyPlacement? {
        sun.placement()
    }

    /// Where the moon's disc is. The moon is drawn only while no part of the
    /// sun shows: both follow the same arc, so a daytime moon would sit on top
    /// of the sun.
    var moonPlacement: SkyPlacement? {
        sunPlacement == nil ? moon.placement() : nil
    }

    var showsMoon: Bool {
        moonPlacement != nil
    }

    var showsStars: Bool {
        nightness > 0
    }

    /// True when something in the scene moves, so it is worth animating.
    var hasMotion: Bool {
        precipitation != .none || wind != .calm || clouds != .clear || showsStars
    }

    /// True when the motion is fast (rain, snow, wind) and needs a high frame rate.
    var hasFastMotion: Bool {
        precipitation != .none || wind != .calm
    }

    /// The scene for `snapshot` at `now`.
    ///
    /// Without a snapshot, or when the snapshot has no entry for today's date in
    /// its own time zone (a cache days old), this is the neutral scene: clear sky
    /// on a 06:00–18:00 day, no temperature. The neutral scene runs on the
    /// snapshot's zone when there is one and on `deviceTimeZone` otherwise.
    ///
    /// A snapshot that covers today but whose reading is no longer fresh
    /// (`SkySnapshot.currentIsFresh`) still places the sun and moon, which hold
    /// for the date, but its temperature and weather are not shown.
    static func make(snapshot: SkySnapshot?, now: Date, deviceTimeZone: TimeZone) -> SceneState {
        if let snapshot, snapshot.day(containing: now) != nil {
            return build(from: snapshot, now: now, isLive: true)
        }
        let zone = snapshot?.timeZone ?? deviceTimeZone
        return build(from: .neutral(now: now, timeZone: zone), now: now, isLive: false)
    }

    private static func build(from snapshot: SkySnapshot, now: Date, isLive: Bool) -> SceneState {
        let sunTimeline = RiseSetTimeline(
            rises: snapshot.days.map(\.sunrise),
            sets: snapshot.days.map(\.sunset),
            typicalTimeUp: RiseSetTimeline.sunTimeUp
        )
        let moonTimeline = RiseSetTimeline(
            rises: snapshot.days.map(\.moonrise),
            sets: snapshot.days.map(\.moonset),
            typicalTimeUp: RiseSetTimeline.moonTimeUp
        )
        // The sun never assumes a day length: where a sunrise or sunset is
        // missing (polar days and the days around them) `isDay` decides.
        let today = snapshot.day(containing: now)
        let current = snapshot.current
        let sun = sunTimeline.state(
            at: now,
            sighting: SkySighting(isUp: current.isDay, at: current.observedAt)
        )
        let hasCurrentWeather = isLive && snapshot.currentIsFresh(at: now)
        // What is drawn when the reading is too old to show: clear and calm.
        let weatherCode = hasCurrentWeather ? current.weatherCode : 0
        return SceneState(
            sun: sun,
            moon: moonTimeline.state(at: now),
            moonPhase: MoonPhase(fraction: today?.moonPhase ?? snapshot.days.first?.moonPhase ?? 0),
            nightness: nightness(for: sun),
            precipitation: Precipitation(weatherCode: weatherCode),
            clouds: CloudLevel(
                coverPercent: hasCurrentWeather ? current.cloudCoverPercent : 0,
                weatherCode: weatherCode
            ),
            wind: hasCurrentWeather
                ? WindLevel(speedMph: current.windSpeedMph, gustsMph: current.windGustsMph)
                : .calm,
            temperatureF: hasCurrentWeather ? current.temperatureF : nil,
            hasCurrentWeather: hasCurrentWeather,
            timeZone: snapshot.timeZone,
            isLive: isLive
        )
    }

    static func nightness(for sun: SkyBodyState) -> Double {
        switch sun {
        case .up:
            return 0
        case .down(let sinceSet, let untilRise):
            let nearest = min(sinceSet ?? .infinity, untilRise ?? .infinity)
            return min(1, max(0, nearest / twilight))
        }
    }

    /// A sentence for VoiceOver, since the scene is a drawing.
    var accessibilityDescription: String {
        var parts: [String] = []
        if sun.isUp {
            parts.append("The sun is up")
        } else if showsMoon {
            parts.append("Night, \(moonPhase.name)")
        } else {
            parts.append("Night")
        }
        // Without a recent reading the drawing is clear and calm by default;
        // that is not a weather report, so it is not spoken as one.
        guard hasCurrentWeather else { return parts.joined() + " over the water." }
        switch precipitation {
        case .none:
            switch clouds {
            case .clear: parts.append("clear sky")
            case .few: parts.append("a few clouds")
            case .scattered: parts.append("scattered clouds")
            case .overcast: parts.append("overcast")
            }
        case .rain: parts.append("rain")
        case .snow: parts.append("snow")
        }
        if wind != .calm { parts.append("windy") }
        return parts.joined(separator: ", ") + " over the water."
    }
}

/// The Today header's date, read on the clock of the scene's time zone.
struct HeaderDate: Equatable, Sendable {
    /// "NOV"
    var month: String
    /// "15"
    var day: String
    /// "Sun"
    var weekday: String
    /// "Sunday, November 15" for VoiceOver.
    var spoken: String

    init(now: Date, timeZone: TimeZone, locale: Locale = Locale(identifier: "en_US")) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        func format(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.locale = locale
            formatter.dateFormat = template
            return formatter.string(from: now)
        }
        month = format("MMM").uppercased()
        day = format("d")
        weekday = format("EEE")
        spoken = format("EEEE, MMMM d")
    }
}
