import Foundation

// The scene's maths: where the sun and moon are, what shape the moon is, and
// what the weather numbers mean. Nothing here draws or touches SwiftUI, so it
// can be unit-tested (see `SkyMathTests`).

/// Whether a body (the sun or the moon) is above the horizon at some instant.
enum SkyBodyState: Equatable, Sendable {
    /// Above the horizon. `progress` runs from 0 at rising to 1 at setting.
    case up(progress: Double)
    /// Below the horizon. The intervals are nil when the neighbouring event is
    /// not known.
    case down(sinceSet: TimeInterval?, untilRise: TimeInterval?)

    var isUp: Bool {
        if case .up = self { return true }
        return false
    }

    var progress: Double? {
        if case .up(let progress) = self { return progress }
        return nil
    }

    /// Where to draw the body's disc, or nil when none of it shows.
    ///
    /// Above the horizon it is on its arc. For `crossing` seconds before it
    /// rises and after it sets the disc is still partly above the waterline: it
    /// stands at the end of the arc, lowered by a share of its own radius, so it
    /// rises out of the water and sinks into it instead of appearing half-risen.
    func placement(crossing: TimeInterval = SkyArc.horizonCrossing) -> SkyPlacement? {
        switch self {
        case .up(let progress):
            return SkyPlacement(progress: progress, sunk: 0)
        case .down(let sinceSet, let untilRise):
            guard crossing > 0 else { return nil }
            let rising = untilRise ?? .infinity
            let setting = sinceSet ?? .infinity
            if rising <= setting {
                return rising < crossing ? SkyPlacement(progress: 0, sunk: max(0, rising) / crossing) : nil
            }
            return setting < crossing ? SkyPlacement(progress: 1, sunk: max(0, setting) / crossing) : nil
        }
    }
}

/// Where a body's disc is drawn: a point on its arc, and how far it has been
/// lowered into the water at either end of it.
struct SkyPlacement: Equatable, Sendable {
    /// Position along the arc, 0 at rising and 1 at setting.
    var progress: Double
    /// 0 on the arc (at `progress` 0 or 1 the centre is then on the waterline,
    /// half the disc showing); toward 1 the centre is that share of the radius
    /// below the waterline, and at 1 nothing would show.
    var sunk: Double
}

/// A reading of whether a body was up, and when it was taken (the API's
/// `isDay` and `observedAt` for the sun).
struct SkySighting: Equatable, Sendable {
    var isUp: Bool
    var at: Date
}

/// All the known rise and set instants of one body, in any order and from any
/// number of days.
///
/// The state at an instant comes from the events on either side of it, never
/// from pairing "today's rise" with "today's set": the moon often sets before it
/// rises on a calendar date, and a sunset can fall on the next local date.
struct RiseSetTimeline: Sendable {
    private enum Kind { case rise, set }
    private var events: [(date: Date, kind: Kind)]
    /// How long the body is assumed to stay up when one end of its arc is missing.
    var typicalTimeUp: TimeInterval

    /// Mean time the moon spends above the horizon.
    static let moonTimeUp: TimeInterval = 12.4 * 3600
    static let sunTimeUp: TimeInterval = 12 * 3600

    init(rises: [Date?], sets: [Date?], typicalTimeUp: TimeInterval) {
        let all = rises.compactMap { $0 }.map { (date: $0, kind: Kind.rise) }
            + sets.compactMap { $0 }.map { (date: $0, kind: Kind.set) }
        events = all.sorted { $0.date < $1.date }
        self.typicalTimeUp = typicalTimeUp
    }

    /// The body's state at `now`.
    ///
    /// - Parameter upWhenUnknown: used only when there is no event at all (polar
    ///   day or night for the sun): pass what the API's `isDay` says. A body that
    ///   is up with no known arc is reported at mid-arc.
    func state(at now: Date, upWhenUnknown: Bool = false) -> SkyBodyState {
        let previous = events.last { $0.date <= now }
        let next = events.first { $0.date > now }

        switch (previous, next) {
        case (nil, nil):
            return upWhenUnknown ? .up(progress: 0.5) : .down(sinceSet: nil, untilRise: nil)

        case (let previous?, let next):
            switch previous.kind {
            case .rise:
                // Up since `previous`. The set is the next event if it is one;
                // otherwise estimate it.
                let end: Date
                if let next, next.kind == .set {
                    end = next.date
                } else {
                    end = previous.date.addingTimeInterval(typicalTimeUp)
                }
                if now >= end {
                    // Past the estimated set with nothing known after it.
                    let untilRise = next.map { $0.date.timeIntervalSince(now) }
                    return .down(sinceSet: now.timeIntervalSince(end), untilRise: untilRise)
                }
                return .up(progress: Self.fraction(of: now, from: previous.date, to: end))
            case .set:
                if let next, next.kind == .set {
                    // Two sets in a row: the rise between them is missing.
                    // Estimate it from the set that is coming.
                    let start = max(previous.date, next.date.addingTimeInterval(-typicalTimeUp))
                    if now >= start {
                        return .up(progress: Self.fraction(of: now, from: start, to: next.date))
                    }
                    return .down(
                        sinceSet: now.timeIntervalSince(previous.date),
                        untilRise: start.timeIntervalSince(now)
                    )
                }
                let untilRise = next.map { $0.date.timeIntervalSince(now) }
                return .down(sinceSet: now.timeIntervalSince(previous.date), untilRise: untilRise)
            }

        case (nil, let next?):
            switch next.kind {
            case .rise:
                return .down(sinceSet: nil, untilRise: next.date.timeIntervalSince(now))
            case .set:
                // It sets next, so it is up now; estimate when it rose.
                let start = next.date.addingTimeInterval(-typicalTimeUp)
                return .up(progress: Self.fraction(of: now, from: start, to: next.date))
            }
        }
    }

    /// The body's state at `now` without ever assuming how long it stays up.
    /// This is the rule for the sun, whose day can be any length: near the
    /// poles it rises without setting, or sets without having risen that day.
    ///
    /// - A rise before `now` and a set after it: up, at its true place on the arc.
    /// - A set before `now`, or a rise after it with nothing known before: down.
    /// - Otherwise one end of the arc is missing (or both are). Then the
    ///   `sighting` says whether the body is up, unless a known event lies
    ///   between the sighting and `now`, in which case that event does (a sun
    ///   seen down before a known sunrise is up after it).
    ///
    /// A body that is up with an end missing is drawn climbing to the top of
    /// the arc at the usual pace and staying there, or staying there and coming
    /// down to a known set. `typicalTimeUp` sets only that pace, never whether
    /// the body is up.
    func state(at now: Date, sighting: SkySighting) -> SkyBodyState {
        let previous = events.last { $0.date <= now }
        let next = events.first { $0.date > now }
        let since = previous.map { now.timeIntervalSince($0.date) }
        let until = next.map { $0.date.timeIntervalSince(now) }

        if let previous, let next, previous.kind == .rise, next.kind == .set {
            return .up(progress: Self.fraction(of: now, from: previous.date, to: next.date))
        }
        if let previous, previous.kind == .set, next?.kind != .set {
            return .down(sinceSet: since, untilRise: until)
        }
        if previous == nil, let next, next.kind == .rise {
            return .down(sinceSet: nil, untilRise: until)
        }

        let isUp: Bool
        if let previous, previous.date > sighting.at {
            isUp = previous.kind == .rise
        } else {
            isUp = sighting.isUp
        }
        guard isUp else {
            return .down(
                sinceSet: previous?.kind == .set ? since : nil,
                untilRise: next?.kind == .rise ? until : nil
            )
        }
        if let previous, previous.kind == .rise, let since, typicalTimeUp > 0 {
            return .up(progress: min(0.5, since / typicalTimeUp))
        }
        if let next, next.kind == .set, let until, typicalTimeUp > 0 {
            return .up(progress: max(0.5, 1 - until / typicalTimeUp))
        }
        return .up(progress: 0.5)
    }

    private static func fraction(of now: Date, from start: Date, to end: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0.5 }
        return min(1, max(0, now.timeIntervalSince(start) / span))
    }
}

/// The path a body follows across the sky, in unit coordinates.
enum SkyArc {
    /// Height above the horizon, 0 at rising and setting and 1 at mid-arc.
    static func altitude(progress: Double) -> Double {
        sin(.pi * min(1, max(0, progress)))
    }

    /// Horizontal position as a fraction of the screen width. The mockups put
    /// the rising sun at 0.4, the midday sun at 0.5 and the setting sun at 0.6.
    static func horizontal(progress: Double) -> Double {
        0.4 + 0.2 * min(1, max(0, progress))
    }

    /// How far the sun has shrunk from its horizon size (0) to its midday size
    /// (1). It shrinks fastest as it leaves the horizon, but never faster than
    /// it climbs: with the mockups' sizes (see `SceneLayout`) the top of the
    /// disc keeps rising all morning. A square root here made the top of the
    /// disc drop by 16 pt in the first minutes after sunrise.
    static func shrink(altitude: Double) -> Double {
        let a = min(1, max(0, altitude))
        return 1.7 * a - 0.7 * a * a
    }

    /// How long a disc takes to come up through the waterline before it rises,
    /// and to go down through it after it sets.
    static let horizonCrossing: TimeInterval = 15 * 60
}

/// The moon's phase as a fraction of the cycle: 0 new, 0.25 first quarter,
/// 0.5 full, 0.75 last quarter.
struct MoonPhase: Equatable, Sendable {
    /// Always in `0..<1`.
    let fraction: Double

    init(fraction: Double) {
        let wrapped = fraction.truncatingRemainder(dividingBy: 1)
        self.fraction = wrapped < 0 ? wrapped + 1 : wrapped
    }

    /// Share of the disc that is lit, 0 at new moon and 1 at full moon.
    var illuminatedFraction: Double {
        (1 - cos(2 * .pi * fraction)) / 2
    }

    /// True from new to full moon. The lit side is then on the right (as seen
    /// from the northern hemisphere, which covers every US zip).
    var isWaxing: Bool {
        fraction < 0.5
    }

    /// Where the terminator (the edge of the lit part) crosses the disc's
    /// horizontal diameter, as a multiple of the radius measured from the centre
    /// toward the lit limb: 1 at new moon (nothing lit), 0 at the quarters,
    /// -1 at full moon (everything lit).
    var terminator: Double {
        cos(2 * .pi * fraction)
    }

    var name: String {
        switch fraction {
        case ..<0.03, 0.97...: "new moon"
        case ..<0.22: "waxing crescent moon"
        case ..<0.28: "first quarter moon"
        case ..<0.47: "waxing gibbous moon"
        case ..<0.53: "full moon"
        case ..<0.72: "waning gibbous moon"
        case ..<0.78: "last quarter moon"
        default: "waning crescent moon"
        }
    }

    /// The phase from the mean length of the lunar cycle, good to about a day.
    /// Used only for the neutral scene, when the API has not supplied a phase.
    static func approximate(at date: Date) -> MoonPhase {
        // New moon of 6 January 2000, 18:14 UTC.
        let referenceNewMoon = Date(timeIntervalSince1970: 947_182_440)
        let synodicMonth = 29.530588853 * 86_400
        return MoonPhase(fraction: date.timeIntervalSince(referenceNewMoon) / synodicMonth)
    }
}

/// Rain or snow, from the WMO weather code.
enum Precipitation: Equatable, Sendable {
    enum Intensity: Int, Sendable, Comparable {
        case light = 1, moderate, heavy
        static func < (a: Intensity, b: Intensity) -> Bool { a.rawValue < b.rawValue }
    }

    case none
    case rain(Intensity)
    case snow(Intensity)

    /// Maps a WMO weather interpretation code (as Open-Meteo reports it).
    /// Drizzle, freezing rain, showers and thunderstorms count as rain; snow
    /// grains and snow showers count as snow. Fog and cloud are not precipitation.
    init(weatherCode: Int) {
        switch weatherCode {
        case 51, 53, 56, 61, 66, 80: self = .rain(.light)
        case 55, 57, 63, 81: self = .rain(.moderate)
        case 65, 67, 82, 95, 96, 99: self = .rain(.heavy)
        case 71, 77, 85: self = .snow(.light)
        case 73: self = .snow(.moderate)
        case 75, 86: self = .snow(.heavy)
        default: self = .none
        }
    }
}

/// How much cloud the scene draws.
enum CloudLevel: Int, Sendable, Comparable {
    case clear, few, scattered, overcast

    static func < (a: CloudLevel, b: CloudLevel) -> Bool { a.rawValue < b.rawValue }

    /// From total cloud cover: under 20 % clear, under 50 % few, under 80 %
    /// scattered, otherwise overcast. The weather code can only raise the level:
    /// "partly cloudy" (2) shows at least a few clouds, "overcast" (3) and fog
    /// (45, 48) are overcast, and rain or snow never falls from fewer than
    /// scattered clouds.
    init(coverPercent: Double, weatherCode: Int) {
        let fromCover: CloudLevel =
            switch coverPercent {
            case ..<20: .clear
            case ..<50: .few
            case ..<80: .scattered
            default: .overcast
            }
        let fromCode: CloudLevel =
            switch weatherCode {
            case 2: .few
            case 3, 45, 48: .overcast
            default: Precipitation(weatherCode: weatherCode) == .none ? .clear : .scattered
            }
        self = max(fromCover, fromCode)
    }
}

/// Whether the water shows wind.
enum WindLevel: Int, Sendable, Comparable {
    case calm, windy, gale

    static func < (a: WindLevel, b: WindLevel) -> Bool { a.rawValue < b.rawValue }

    /// Windy from a sustained 15 mph or gusts of 25 mph (a fresh breeze, when
    /// open water shows whitecaps); gale from 30 mph or gusts of 45 mph.
    init(speedMph: Double, gustsMph: Double) {
        if speedMph >= 30 || gustsMph >= 45 {
            self = .gale
        } else if speedMph >= 15 || gustsMph >= 25 {
            self = .windy
        } else {
            self = .calm
        }
    }
}
