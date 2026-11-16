#if DEBUG
import Foundation

/// Debug-only: forces the time of day, moon phase and weather so every state of
/// the scene can be looked at and screenshotted. Not compiled into Release.
///
/// The override rewrites the scene's *inputs* (the clock and the sky snapshot),
/// so what is drawn still goes through the real maths in `SceneState.make`.
///
/// Set it in Settings (Debug scene), or with launch arguments, which
/// `UserDefaults` reads as `-key value`:
///
///     -debugTime sunrise|midday|sunset|night
///     -debugTime sunrise-5       (a named time and an offset in minutes: "sunset+7.5", "night+90")
///     -debugMoon 0.35            (phase fraction; implies night unless -debugTime is given)
///     -debugWeather clear|cloudy|windy|rain|snow
struct SceneDebugOverride: Equatable, Sendable {
    enum Time: String, CaseIterable, Sendable {
        case sunrise, midday, sunset, night
    }

    enum Weather: String, CaseIterable, Sendable {
        case clear, cloudy, windy, rain, snow
    }

    static let timeKey = "debugTime"
    static let moonKey = "debugMoon"
    static let weatherKey = "debugWeather"

    var time: Time?
    /// Minutes added to the named time; nil when the text gave no offset.
    var offsetMinutes: Double?
    var moonPhase: Double?
    var weather: Weather?

    var isActive: Bool {
        time != nil || moonPhase != nil || weather != nil
    }

    /// From the raw strings stored in `UserDefaults`; anything unrecognised is ignored.
    init(time: String = "", moon: String = "", weather: String = "") {
        (self.time, self.offsetMinutes) = Self.parseTime(time)
        self.moonPhase = Double(moon).map { min(1, max(0, $0)) }
        self.weather = Weather(rawValue: weather)
    }

    /// "sunset" is the named time alone; "sunset+7.5" and "sunrise-5" add an
    /// offset in minutes. Anything else is no time at all.
    static func parseTime(_ text: String) -> (Time?, Double?) {
        if let named = Time(rawValue: text) { return (named, nil) }
        guard
            let sign = text.firstIndex(where: { $0 == "+" || $0 == "-" }),
            let named = Time(rawValue: String(text[..<sign])),
            let minutes = Double(text[sign...]),
            minutes.isFinite
        else { return (nil, nil) }
        return (named, minutes)
    }

    /// The snapshot and clock to draw instead of the real ones.
    func apply(
        to snapshot: SkySnapshot?,
        now: Date,
        deviceTimeZone: TimeZone
    ) -> (snapshot: SkySnapshot?, now: Date) {
        guard isActive else { return (snapshot, now) }

        // Start from the real sky when it covers today, else from the neutral one.
        var sky: SkySnapshot
        if let snapshot, snapshot.day(containing: now) != nil {
            sky = snapshot
        } else {
            let zone = snapshot?.timeZone ?? deviceTimeZone
            sky = .neutral(now: now, timeZone: zone)
            // Keep a temperature on screen for screenshots of the neutral sky.
            sky.zip = "00000"
            sky.current.temperatureF = 53
        }
        var clock = now

        if let time = time ?? (moonPhase != nil ? .night : nil) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = sky.timeZone
            let today = sky.day(containing: now)
            let startOfDay = calendar.startOfDay(for: now)
            let sunrise = today?.sunrise ?? startOfDay.addingTimeInterval(6 * 3600)
            let sunset = today?.sunset ?? startOfDay.addingTimeInterval(18 * 3600)
            let offset = offsetMinutes.map { $0 * 60 }
            switch time {
            case .sunrise:
                // Without an offset: a second after sunrise, the sun just up.
                clock = sunrise.addingTimeInterval(offset ?? 1)
            case .midday:
                clock = sunrise.addingTimeInterval(sunset.timeIntervalSince(sunrise) / 2 + (offset ?? 0))
            case .sunset:
                // Without an offset: a second before sunset, the sun still up.
                clock = sunset.addingTimeInterval(offset ?? -1)
            case .night:
                // Four hours after sunset, with the moon at the top of its arc.
                clock = sunset.addingTimeInterval(4 * 3600 + (offset ?? 0))
                let half = RiseSetTimeline.moonTimeUp / 2
                for index in sky.days.indices {
                    sky.days[index].moonrise = nil
                    sky.days[index].moonset = nil
                }
                if let index = sky.days.firstIndex(where: { $0.date == today?.date }) ?? sky.days.indices.first {
                    sky.days[index].moonrise = clock.addingTimeInterval(-half)
                    sky.days[index].moonset = clock.addingTimeInterval(half)
                }
            }
            sky.current.isDay = clock >= sunrise && clock < sunset
            sky.current.observedAt = clock
        }
        // The forced scene is "now": the stale rule must not hide its
        // temperature and weather because the clock was moved.
        sky.fetchedAt = clock

        if let moonPhase {
            for index in sky.days.indices {
                sky.days[index].moonPhase = moonPhase
            }
        }

        if let weather {
            switch weather {
            case .clear:
                sky.current.weatherCode = 0
                sky.current.cloudCoverPercent = 0
                sky.current.windSpeedMph = 4
                sky.current.windGustsMph = 8
            case .cloudy:
                sky.current.weatherCode = 3
                sky.current.cloudCoverPercent = 92
                sky.current.windSpeedMph = 4
                sky.current.windGustsMph = 8
            case .windy:
                sky.current.weatherCode = 0
                sky.current.cloudCoverPercent = 0
                sky.current.windSpeedMph = 22
                sky.current.windGustsMph = 34
            case .rain:
                sky.current.weatherCode = 63
                sky.current.cloudCoverPercent = 95
                sky.current.windSpeedMph = 6
                sky.current.windGustsMph = 12
            case .snow:
                sky.current.weatherCode = 73
                sky.current.cloudCoverPercent = 95
                sky.current.windSpeedMph = 6
                sky.current.windGustsMph = 12
            }
        }

        return (sky, clock)
    }
}
#endif
