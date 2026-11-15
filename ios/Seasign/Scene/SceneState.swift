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
    /// The zone the header's date and the sun's clock are read in.
    var timeZone: TimeZone
    /// False when the scene is the neutral stand-in, not the user's zip.
    var isLive: Bool

    /// How long dusk and dawn last, in seconds.
    static let twilight: TimeInterval = 40 * 60

    /// The moon is drawn only while the sun is down. Both follow the same arc,
    /// so a daytime moon would sit on top of the sun.
    var showsMoon: Bool {
        moon.isUp && !sun.isUp
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
    /// its own time zone (a stale cache), this is the neutral scene: clear sky on
    /// a 06:00–18:00 day, no temperature. The neutral scene runs on the
    /// snapshot's zone when there is one and on `deviceTimeZone` otherwise.
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
        // `isDay` settles the sun only when today has no sunrise or sunset at
        // all (polar day or polar night).
        let today = snapshot.day(containing: now)
        let sun: SkyBodyState
        if let today, today.sunrise == nil, today.sunset == nil {
            sun = snapshot.current.isDay
                ? .up(progress: 0.5)
                : .down(sinceSet: nil, untilRise: nil)
        } else {
            sun = sunTimeline.state(at: now, upWhenUnknown: snapshot.current.isDay)
        }
        let current = snapshot.current
        return SceneState(
            sun: sun,
            moon: moonTimeline.state(at: now),
            moonPhase: MoonPhase(fraction: today?.moonPhase ?? snapshot.days.first?.moonPhase ?? 0),
            nightness: nightness(for: sun),
            precipitation: Precipitation(weatherCode: current.weatherCode),
            clouds: CloudLevel(coverPercent: current.cloudCoverPercent, weatherCode: current.weatherCode),
            wind: WindLevel(speedMph: current.windSpeedMph, gustsMph: current.windGustsMph),
            temperatureF: isLive ? current.temperatureF : nil,
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
