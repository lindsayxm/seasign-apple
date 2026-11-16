import Foundation

/// The LLM providers `POST /v1/discover` can search with. Raw values are the API's.
enum AIProvider: String, CaseIterable, Codable, Sendable {
    case anthropic
    case openai
    case gemini
    case perplexity

    /// The provider's name as people know it.
    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .perplexity: "Perplexity"
        }
    }

    static let `default` = AIProvider.anthropic
}

/// The pill toggle in Settings: the user's own list only, or the list plus
/// what the user's LLM finds on their interests.
enum AIMode: String, Codable, Sendable {
    case myList = "my_list"
    case aiSearch = "ai_search"
}

/// Where a feed item came from. Raw values are stored in `FeedItem` and `SavedItem`.
enum FeedOrigin: String, Codable, Sendable {
    /// A site the user follows.
    case site
    /// Found by the user's LLM through `POST /v1/discover`.
    case ai
}

/// The interests typed in Settings, as the API takes them.
///
/// The API (`cleanInterest` in `api/src/routes/discover.ts`) takes at most
/// 400 UTF-16 units as sent, then, after collapsing white space and dropping
/// control and direction characters, 1 to 80 code points. `SiteText.clean`
/// already drops everything that cleaning would, so what is sent is what
/// the API measures, and it is measured the same way here: Unicode scalars
/// (code points) and UTF-16 units, not Swift `Character`s. A flag is two
/// scalars, a family emoji seven; an interest is never cut inside one.
enum InterestList {
    static let maxCount = 20
    /// Unicode scalars (the API's code points), after cleaning.
    static let maxLength = 80
    /// UTF-16 units, as sent.
    static let maxUTF16 = 400

    /// What was left out or shortened while reading the typed text.
    struct Trim: Equatable, Sendable {
        /// Interests beyond `maxCount` that were dropped.
        var dropped = 0
        /// Interests cut to fit `maxLength`.
        var shortened = 0
        /// Interests left out because even their first character is over
        /// the limit (one character built from more than 80 code points),
        /// so no cut can make them fit.
        var tooLong = 0

        var isEmpty: Bool { dropped == 0 && shortened == 0 && tooLong == 0 }

        /// Fixed text for Settings.
        var message: String? {
            var parts: [String] = []
            if dropped > 0 {
                parts.append("Only the first \(InterestList.maxCount) interests are used.")
            }
            if shortened > 0 {
                parts.append("Interests are cut to \(InterestList.maxLength) characters (an emoji can count as several).")
            }
            if tooLong > 0 {
                parts.append(tooLong == 1
                    ? "One interest is too long to use and was left out."
                    : "\(tooLong) interests are too long to use and were left out.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    struct Parsed: Equatable, Sendable {
        var interests: [String]
        var trim: Trim
    }

    /// Whether the API takes `interest` as it stands (already cleaned).
    static func fits(_ interest: String) -> Bool {
        let scalars = interest.unicodeScalars.count
        return scalars >= 1 && scalars <= maxLength && interest.utf16.count <= maxUTF16
    }

    /// The longest run of whole characters from the start that fits, with
    /// trailing spaces trimmed; empty when not even the first character fits.
    static func cut(_ interest: String) -> String {
        var scalars = 0
        var utf16 = 0
        var end = interest.startIndex
        for character in interest {
            let nextScalars = scalars + character.unicodeScalars.count
            let nextUTF16 = utf16 + character.utf16.count
            guard nextScalars <= maxLength, nextUTF16 <= maxUTF16 else { break }
            scalars = nextScalars
            utf16 = nextUTF16
            end = interest.index(after: end)
        }
        return String(interest[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// Splits on commas, cleans each piece like site text (white space
    /// collapsed, invisible characters dropped), drops empty ones and
    /// repeats that differ only in case (the first spelling wins), cuts each
    /// to fit the API's limits on a character boundary (or leaves it out
    /// when no cut can), and keeps the first `maxCount`.
    static func parse(_ typed: String) -> Parsed {
        var trim = Trim()
        var seen = Set<String>()
        var result: [String] = []
        for piece in typed.split(separator: ",", omittingEmptySubsequences: false) {
            var interest = SiteText.clean(String(piece), limit: Int.max)
            guard !interest.isEmpty else { continue }
            if !fits(interest) {
                interest = cut(interest)
                guard !interest.isEmpty else {
                    trim.tooLong += 1
                    continue
                }
                trim.shortened += 1
            }
            guard seen.insert(interest.lowercased()).inserted else { continue }
            if result.count == maxCount {
                trim.dropped += 1
                continue
            }
            result.append(interest)
        }
        return Parsed(interests: result, trim: trim)
    }
}

/// How many searches a day the user allows.
enum DailyCap {
    static let `default` = 3
    static let range = 1...20

    /// A stored or typed value brought into range; nil is the default.
    static func clamp(_ value: Int?) -> Int {
        guard let value else { return `default` }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// Automatic searches are spread through the day: at least 24 h / cap
    /// apart, and never closer than the feed's own refresh interval.
    static func spacing(cap: Int) -> TimeInterval {
        max(FeedModel.refreshInterval, 86_400 / Double(clamp(cap)))
    }

    /// "2 of 3 searches used today".
    static func usage(used: Int, cap: Int) -> String {
        "\(used) of \(cap) \(cap == 1 ? "search" : "searches") used today"
    }
}

/// The local calendar day a search is counted on.
enum SearchDay {
    /// "2026-11-16" for `date` in `timeZone`.
    static func key(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The zone's identifier when it is an IANA name the API can read
    /// (`America/Chicago`, `UTC`); nil for anything else, such as
    /// `GMT-0500`, which the API would refuse.
    static func ianaName(_ timeZone: TimeZone) -> String? {
        ianaName(identifier: timeZone.identifier)
    }

    /// The API checks `timezone` with `Intl.DateTimeFormat` and a 64
    /// character limit, and answers 400 to a name it does not know, which
    /// would refuse every search. So only a name that is certainly one of
    /// the IANA database's is sent: UTC under any of its names (sent as
    /// `UTC`), or, in at most 64 characters of letters, digits, `/`, `_`,
    /// `-` and `+`, a name Foundation lists as known or an `Area/Place` name
    /// in one of the database's areas that `TimeZone(identifier:)`
    /// recognises unchanged (Foundation's known list has `Asia/Calcutta`
    /// but not `Asia/Kolkata`, which `TimeZone(identifier:)` accepts).
    /// Anything else (offset zones such as `GMT-0500`, abbreviations such
    /// as `CST`, whose acceptance depends on the server's time zone data,
    /// unknown names) is nil and the field is left out; the API then
    /// counts days in UTC.
    static func ianaName(identifier: String) -> String? {
        // Foundation names UTC "GMT"; both are UTC to the API.
        if ["GMT", "UTC", "Etc/UTC", "Etc/GMT"].contains(identifier) { return "UTC" }
        guard (1...64).contains(identifier.utf16.count),
              identifier.unicodeScalars.allSatisfy(isNameScalar)
        else { return nil }
        if TimeZone.knownTimeZoneIdentifiers.contains(identifier) { return identifier }
        guard let area = identifier.split(separator: "/", omittingEmptySubsequences: false).first,
              ianaAreas.contains(String(area)),
              identifier.contains("/"),
              TimeZone(identifier: identifier)?.identifier == identifier
        else { return nil }
        return identifier
    }

    /// The geographic areas of the IANA database's `Area/Place` names.
    private static let ianaAreas: Set<String> = [
        "Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic",
        "Australia", "Europe", "Indian", "Pacific",
    ]

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "/", "_", "-", "+": true
        default: false
        }
    }
}

/// What is known about the key in the Keychain. The key itself is never held.
enum KeyStatus: Equatable, Sendable {
    /// A key is stored.
    case saved
    /// The Keychain answered that no key is stored.
    case missing
    /// The Keychain could not be read (for one, before the phone's first
    /// unlock after a restart), so whether a key is stored is not known.
    /// Nothing is sent and the pill keeps its place until it can be read;
    /// AI-found items are hidden meanwhile, as AI search is not active.
    case unknown
}

/// Whether AI search can be switched on, and if not, why.
enum AIPrecondition: Equatable, Sendable {
    case ready
    case needsKey
    case needsInterests
    case needsKeyAndInterests
    /// The Keychain cannot be read right now; the key may well be there.
    case keyUnreadable

    init(key: KeyStatus, interests: [String]) {
        switch (key, !interests.isEmpty) {
        case (.unknown, _): self = .keyUnreadable
        case (.saved, true): self = .ready
        case (.missing, true): self = .needsKey
        case (.saved, false): self = .needsInterests
        case (.missing, false): self = .needsKeyAndInterests
        }
    }

    init(hasKey: Bool, interests: [String]) {
        self.init(key: hasKey ? .saved : .missing, interests: interests)
    }

    /// Shown next to the toggle while it cannot move to Let AI Search.
    var message: String? {
        switch self {
        case .ready: nil
        case .needsKey: "Add your API key below to let AI search."
        case .needsInterests: "Add at least one interest below to let AI search."
        case .needsKeyAndInterests: "Add your API key and at least one interest below to let AI search."
        // Not "add your key": the key is most likely stored, just locked away.
        case .keyUnreadable: "AI search waits until your saved key can be read."
        }
    }
}

/// Why a search was not sent, or what went wrong with one.
enum AISearchProblem: Equatable, Sendable {
    /// The API's error codes.
    case invalidRequest
    case invalidKey
    case quotaExceeded
    case rateLimited
    case providerError
    case timeout
    case internalError
    /// The server could not be reached or sent something unreadable.
    case unavailable
    /// The Keychain would not give the key back.
    case keyUnreadable
    /// The day's count could not be written, so the search was not sent.
    case countNotSaved

    init(_ failure: SeasignAPI.DiscoverFailure) {
        switch failure {
        case .invalidRequest: self = .invalidRequest
        case .invalidKey: self = .invalidKey
        case .quotaExceeded: self = .quotaExceeded
        case .rateLimited: self = .rateLimited
        case .providerError: self = .providerError
        case .timeout: self = .timeout
        case .internalError: self = .internalError
        case .unavailable: self = .unavailable
        }
    }

    /// Shown in Settings' AI section only, never on Today. Fixed text: it
    /// never holds the key or anything the server sent.
    var message: String {
        switch self {
        case .invalidRequest:
            "Seasign's server refused the search. Check your interests and try again."
        case .invalidKey:
            "That key was refused by the provider. Check the key and the provider."
        case .quotaExceeded:
            "Your provider account is out of credit."
        case .rateLimited:
            "Your provider is limiting searches right now. Try again later."
        case .providerError:
            "The provider couldn't run the search. Try again later."
        case .timeout:
            "The provider took too long to answer. The search may still be billed."
        case .internalError:
            "Seasign's server had a problem with the search. Try again later."
        case .unavailable:
            "We couldn't reach Seasign's server. Check your connection."
        case .keyUnreadable:
            // Most often the phone has restarted and not been unlocked yet;
            // the key is still there, so this does not ask for it again.
            "Your key can't be read from this phone's Keychain right now. If the phone has just restarted, unlock it and try again."
        case .countNotSaved:
            "The search couldn't be counted on this phone, so it wasn't sent. Try again."
        }
    }

    /// Answers that prove the provider was never called, so nothing was
    /// billed and the search is not counted: the API refused the request
    /// itself (400), or the provider refused the key (401).
    var refundsSearch: Bool {
        self == .invalidRequest || self == .invalidKey
    }

    /// After this, automatic searches stop until the key or provider changes.
    var stopsAutomaticSearch: Bool {
        self == .invalidKey
    }

    /// Stored in `Settings.aiLastProblemRaw` so the message survives a relaunch.
    var rawValue: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidKey: "invalid_key"
        case .quotaExceeded: "quota_exceeded"
        case .rateLimited: "rate_limited"
        case .providerError: "provider_error"
        case .timeout: "timeout"
        case .internalError: "internal_error"
        case .unavailable: "unavailable"
        case .keyUnreadable: "key_unreadable"
        case .countNotSaved: "count_not_saved"
        }
    }

    init?(rawValue: String) {
        let all: [AISearchProblem] = [
            .invalidRequest, .invalidKey, .quotaExceeded, .rateLimited, .providerError,
            .timeout, .internalError, .unavailable, .keyUnreadable, .countNotSaved,
        ]
        guard let match = all.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = match
    }
}

/// Whether a search may be sent now. Pure, so every rule is tested on its own.
struct SearchGate: Equatable, Sendable {
    enum Trigger: Sendable {
        /// A feed refresh (launch, return to the foreground): respects the spacing.
        case automatic
        /// "Search now" in Settings: ignores the spacing, never the cap.
        case manual
    }

    enum Decision: Equatable, Sendable {
        case send
        case myListMode
        case notReady(AIPrecondition)
        case capReached
        case tooSoon(until: Date)
        case stoppedAfterInvalidKey
        case alreadySearching
    }

    var mode: AIMode
    /// Only `.saved` can send; `.unknown` never does.
    var key: KeyStatus
    var interests: [String]
    var cap: Int
    var usedToday: Int
    /// When the last search was sent, on any day.
    var lastSentAt: Date?
    var keyRefused: Bool
    var isSearching: Bool

    func decide(_ trigger: Trigger, now: Date) -> Decision {
        // With Use My List selected nothing is ever sent, whatever else holds.
        guard mode == .aiSearch else { return .myListMode }
        let precondition = AIPrecondition(key: key, interests: interests)
        guard precondition == .ready else { return .notReady(precondition) }
        guard !isSearching else { return .alreadySearching }
        guard usedToday < DailyCap.clamp(cap) else { return .capReached }
        if trigger == .automatic {
            guard !keyRefused else { return .stoppedAfterInvalidKey }
            if let lastSentAt {
                let next = lastSentAt.addingTimeInterval(DailyCap.spacing(cap: cap))
                // A clock set back past the last search counts as too soon too.
                if now < next { return .tooSoon(until: next) }
            }
        }
        return .send
    }
}

/// How an AI-found item is marked.
enum AILabel {
    /// The visible mark.
    static let mark = "AI"
    /// Spoken before the title.
    static let spoken = "AI-found"

    /// The accessibility label of a row or headline: plain strings joined by
    /// hand, since the title came from a website.
    static func accessibility(title: String, isAI: Bool) -> String {
        isAI ? spoken + ": " + title : title
    }

    /// "AI · Anthropic" for the reading view.
    static func foundBy(_ provider: AIProvider?) -> String {
        guard let provider else { return "AI search" }
        return "AI search · " + provider.displayName
    }
}
