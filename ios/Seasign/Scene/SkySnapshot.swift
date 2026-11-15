import Foundation

/// The app's own copy of a `GET /v1/sky` response: what the scene maths reads and
/// what the local cache stores. Keeping it separate from the generated
/// `Components.Schemas.Sky` means the maths and the cache do not change shape
/// when the client is regenerated.
struct SkySnapshot: Codable, Sendable, Equatable {
    struct Current: Codable, Sendable, Equatable {
        var observedAt: Date
        var temperatureF: Double
        /// WMO weather interpretation code.
        var weatherCode: Int
        var cloudCoverPercent: Double
        var windSpeedMph: Double
        var windGustsMph: Double
        var isDay: Bool
    }

    struct Day: Codable, Sendable, Equatable {
        /// Calendar date in the place's time zone, `YYYY-MM-DD`.
        var date: String
        var sunrise: Date?
        var sunset: Date?
        var moonrise: Date?
        var moonset: Date?
        /// 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
        var moonPhase: Double
    }

    var zip: String
    var placeName: String
    var region: String?
    /// IANA identifier of the place's time zone.
    var timezone: String
    var current: Current
    var days: [Day]
    /// When the app received this response.
    var fetchedAt: Date

    /// The place's time zone; GMT if Foundation does not know the identifier.
    var timeZone: TimeZone {
        TimeZone(identifier: timezone) ?? .gmt
    }

    /// The entry in `days` for the local date that contains `now`, matched by its
    /// `date` field. `days[0]` is not always today: it can be yesterday for a few
    /// minutes after local midnight, and a cached response can be days old.
    func day(containing now: Date) -> Day? {
        let today = Self.localDateString(for: now, in: timeZone)
        return days.first { $0.date == today }
    }

    /// `YYYY-MM-DD` for `date` in `timeZone`, always in the Gregorian calendar
    /// whatever the user's own calendar is.
    static func localDateString(for date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension SkySnapshot {
    /// Copies a response from the generated client.
    init(_ sky: Components.Schemas.Sky, fetchedAt: Date) {
        self.init(
            zip: sky.zip,
            placeName: sky.place.name,
            region: sky.place.region,
            timezone: sky.timezone,
            current: Current(
                observedAt: sky.current.observedAt,
                temperatureF: sky.current.temperatureF,
                weatherCode: sky.current.weatherCode,
                cloudCoverPercent: sky.current.cloudCoverPercent,
                windSpeedMph: sky.current.windSpeedMph,
                windGustsMph: sky.current.windGustsMph,
                isDay: sky.current.isDay
            ),
            days: sky.days.map { day in
                Day(
                    date: day.date,
                    sunrise: day.sunrise,
                    sunset: day.sunset,
                    moonrise: day.moonrise,
                    moonset: day.moonset,
                    moonPhase: day.moonPhase
                )
            },
            fetchedAt: fetchedAt
        )
    }

    /// A stand-in sky for when there is no usable data (no zip yet, or a cached
    /// response too old to contain today): clear and calm, sun up from 06:00 to
    /// 18:00 and moon up from 18:00 to 06:00 on the clock of `timeZone`, moon phase
    /// from the mean lunar cycle. Covers yesterday, today and tomorrow.
    static func neutral(now: Date, timeZone: TimeZone) -> SkySnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        let days: [Day] = (-1...1).compactMap { offset in
            guard
                let start = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                let six = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: start),
                let eighteen = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: start)
            else { return nil }
            return Day(
                date: localDateString(for: start, in: timeZone),
                sunrise: six,
                sunset: eighteen,
                moonrise: eighteen,
                moonset: six,
                moonPhase: MoonPhase.approximate(at: eighteen).fraction
            )
        }
        let hour = calendar.component(.hour, from: now)
        return SkySnapshot(
            zip: "",
            placeName: "",
            region: nil,
            timezone: timeZone.identifier,
            current: Current(
                observedAt: now,
                temperatureF: 0,
                weatherCode: 0,
                cloudCoverPercent: 0,
                windSpeedMph: 0,
                windGustsMph: 0,
                isDay: (6..<18).contains(hour)
            ),
            days: days,
            fetchedAt: now
        )
    }
}
