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
    /// The wind now in mph; nil without a fresh current reading (and so in
    /// the neutral scene).
    var windMph: Double?
    /// The rise and set instants of the sun's pass and the moon's pass
    /// around now, as far as they are known.
    var sunPass: SkyPass = .unknown
    var moonPass: SkyPass = .unknown

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

    /// The sun or moon that is drawn, if either.
    var body: SceneBody? {
        if let placement = sunPlacement { return SceneBody(kind: .sun, placement: placement, pass: sunPass) }
        if let placement = moonPlacement { return SceneBody(kind: .moon, placement: placement, pass: moonPass) }
        return nil
    }

    /// The look of the sky, from the plan's table: the sun's looks while any
    /// of it is drawn (sunrise and sunset in the first and last 12 % of its
    /// path), dusk in the twilight and while the moon is low, full under a
    /// moon more than 97 % lit, night otherwise.
    var look: SceneLook {
        if let placement = sunPlacement {
            if placement.progress < 0.12 { return .sunrise }
            if placement.progress > 0.88 { return .sunset }
            switch precipitation {
            case .rain: return .rain
            case .snow: return .snow
            case .none: return clouds >= .scattered ? .cloudy : .day
            }
        }
        if nightness < 1 { return .dusk }
        if let placement = moonPlacement {
            if placement.progress < 0.12 || placement.progress > 0.88 { return .dusk }
            if moonPhase.illuminatedFraction > 0.97 { return .full }
        }
        return .night
    }

    /// The one highlight colour of the screen.
    var ink: SceneRGB { look.ink }

    /// How bright the stars are drawn (the mockup's multipliers): full at
    /// night, a little less with the sun low or behind weather, none in a
    /// clear (or few-cloud) day sky away from sunrise and sunset.
    var starStrength: Double {
        switch look {
        case .dusk, .night, .full: 1.25
        case .sunrise, .sunset, .cloudy, .rain, .snow: 0.95
        case .day: 0
        }
    }

    var showsStars: Bool {
        starStrength > 0
    }

    /// How much cloud is drawn round the body, 0 to 1: rain under full
    /// cloud, snow under some, otherwise by the cloud level.
    var cloudAmount: Double {
        switch precipitation {
        case .rain: return 1
        case .snow: return 0.6
        case .none:
            switch clouds {
            case .clear: return 0
            case .few: return 0.3
            case .scattered: return 0.6
            case .overcast: return 0.8
            }
        }
    }

    var isRaining: Bool {
        if case .rain = precipitation { return true }
        return false
    }

    var isSnowing: Bool {
        if case .snow = precipitation { return true }
        return false
    }

    // MARK: Marks on the horizon

    /// The pass the horizon marks describe: the drawn body's, in a live
    /// scene only (the neutral scene has no ticks, times or tag).
    var markedPass: SkyPass {
        guard isLive, let body else { return .unknown }
        return body.pass
    }

    /// How many hourly intervals the ticks under the horizon mark; nil when
    /// the span is not known, and then only the known ends get a tick.
    var tickCount: Int? {
        markedPass.hourCount
    }

    /// The end of the path the tag is at: only within 5 % of either end, and
    /// only when that end's instant is known.
    var tagEdge: SkyEdge? {
        guard let progress = body?.placement.progress else { return nil }
        let pass = markedPass
        if progress < 0.05, pass.rise != nil { return .rise }
        if progress > 0.95, pass.set != nil { return .set }
        return nil
    }

    /// Whether the rise or set tag beside the body is showing. While it is,
    /// the wind is written in it, not under the header.
    var showsTag: Bool {
        tagEdge != nil
    }

    /// The small square on the horizon under the body, away from the ends.
    var showsSquare: Bool {
        guard let progress = body?.placement.progress else { return false }
        return progress > 0.05 && progress < 0.95
    }

    /// The time written under the rise end; nil when unknown or while the
    /// tag carries it.
    var riseMark: Date? {
        tagEdge == .rise ? nil : markedPass.rise
    }

    var setMark: Date? {
        tagEdge == .set ? nil : markedPass.set
    }

    /// `WIND 8 MPH`, or nil without a fresh reading.
    var windLabel: String? {
        windMph.map { "WIND \(Int($0.rounded())) MPH" }
    }

    /// The tag's two lines: `SUNRISE 6:41 AM` (in the ink colour) and the
    /// wind, which is left out without a fresh reading. Nil when no tag shows.
    func tagLines(clock: ClockStyle) -> (title: String, wind: String?)? {
        guard let edge = tagEdge, let body else { return nil }
        let instant = edge == .rise ? markedPass.rise : markedPass.set
        guard let instant else { return nil }
        let name: String =
            switch (body.kind, edge) {
            case (.sun, .rise): "SUNRISE"
            case (.sun, .set): "SUNSET"
            case (.moon, .rise): "MOONRISE"
            case (.moon, .set): "MOONSET"
            }
        return (name + " " + Self.markTime(instant, timeZone: timeZone, clock: clock), windLabel)
    }

    /// A rise or set time as the marks write it, on the scene's clock:
    /// `6:41 AM`, or `06:41` on a 24-hour phone.
    static func markTime(_ date: Date, timeZone: TimeZone, clock: ClockStyle) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let time = clock.columns(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        return time.half.map { time.clock + " " + $0 } ?? time.clock
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
        let moon = moonTimeline.state(at: now)
        let hasCurrentWeather = isLive && snapshot.currentIsFresh(at: now)
        // What is drawn when the reading is too old to show: clear and calm.
        let weatherCode = hasCurrentWeather ? current.weatherCode : 0
        return SceneState(
            sun: sun,
            moon: moon,
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
            isLive: isLive,
            windMph: hasCurrentWeather ? current.windSpeedMph : nil,
            sunPass: sunTimeline.pass(at: now, state: sun),
            moonPass: moonTimeline.pass(at: now, state: moon)
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

    /// What VoiceOver says for the scene: the sentence below, then what the
    /// marks on the horizon show. While the tag shows it is spoken first,
    /// with the wind it carries (the wind line under the header is hidden
    /// then): "Sunset at 4:31 PM, wind 11 miles per hour. Sunrise was at
    /// 6:41 AM." Otherwise the two times: "Sunrise 6:41 AM, sunset 4:31 PM."
    /// Unknown times, and the neutral scene's, are not spoken.
    func accessibilityDescription(clock: ClockStyle) -> String {
        var sentences = [accessibilityDescription]
        guard let body else { return sentences[0] }
        let pass = markedPass
        let (riseName, setName) = body.kind == .sun ? ("Sunrise", "Sunset") : ("Moonrise", "Moonset")
        func time(_ date: Date) -> String { Self.markTime(date, timeZone: timeZone, clock: clock) }
        if let edge = tagEdge {
            let (name, instant) = edge == .rise ? (riseName, pass.rise) : (setName, pass.set)
            if let instant {
                var tag = "\(name) at \(time(instant))"
                if let windMph { tag += ", wind \(Int(windMph.rounded())) miles per hour" }
                sentences.append(tag + ".")
            }
            if edge == .rise, let set = pass.set {
                sentences.append("\(setName) at \(time(set)).")
            } else if edge == .set, let rise = pass.rise {
                sentences.append("\(riseName) was at \(time(rise)).")
            }
        } else {
            let times = [
                pass.rise.map { "\(riseName) \(time($0))" },
                pass.set.map { "\(setName.lowercased()) \(time($0))" },
            ].compactMap { $0 }
            if !times.isEmpty {
                let joined = times.joined(separator: ", ")
                sentences.append(joined.prefix(1).uppercased() + joined.dropFirst() + ".")
            }
        }
        return sentences.joined(separator: " ")
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

/// The sun or moon that is drawn.
struct SceneBody: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case sun, moon }
    var kind: Kind
    var placement: SkyPlacement
    var pass: SkyPass
}

/// Which end of the path a body is at.
enum SkyEdge: Equatable, Sendable { case rise, set }

/// A colour as 0–255 sRGB components, as the mockup writes them.
struct SceneRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The looks of the v11 scene (see `SceneState.look`).
enum SceneLook: String, CaseIterable, Sendable {
    case sunrise, day, sunset, cloudy, rain, snow, dusk, night, full

    var isNight: Bool {
        switch self {
        case .dusk, .night, .full: true
        default: false
        }
    }

    /// The highlight colour of the screen in this look.
    var ink: SceneRGB {
        switch self {
        case .sunrise: SceneRGB(255, 244, 190)
        case .sunset: SceneRGB(255, 205, 186)
        case .day, .cloudy, .rain, .snow: SceneRGB(244, 216, 104)
        case .dusk, .night, .full: SceneRGB(150, 232, 240)
        }
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
