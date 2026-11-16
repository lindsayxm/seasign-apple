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
enum InterestList {
    static let maxCount = 20
    static let maxLength = 80

    /// What was left out or shortened while reading the typed text.
    struct Trim: Equatable, Sendable {
        /// Interests beyond `maxCount` that were dropped.
        var dropped = 0
        /// Interests cut to `maxLength` characters.
        var shortened = 0

        var isEmpty: Bool { dropped == 0 && shortened == 0 }

        /// Fixed text for Settings.
        var message: String? {
            var parts: [String] = []
            if dropped > 0 {
                parts.append("Only the first \(InterestList.maxCount) interests are used.")
            }
            if shortened > 0 {
                parts.append("Interests are cut to \(InterestList.maxLength) characters.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    struct Parsed: Equatable, Sendable {
        var interests: [String]
        var trim: Trim
    }

    /// Splits on commas, cleans each piece like site text (white space
    /// collapsed, invisible characters dropped), drops empty ones and
    /// repeats that differ only in case (the first spelling wins), cuts each
    /// to `maxLength` characters and keeps the first `maxCount`.
    static func parse(_ typed: String) -> Parsed {
        var trim = Trim()
        var seen = Set<String>()
        var result: [String] = []
        for piece in typed.split(separator: ",", omittingEmptySubsequences: false) {
            var interest = SiteText.clean(String(piece), limit: Int.max)
            guard !interest.isEmpty else { continue }
            if interest.count > maxLength {
                interest = String(interest.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
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
        let identifier = timeZone.identifier
        // Foundation names UTC "GMT"; both are UTC to the API.
        if ["GMT", "UTC", "Etc/UTC", "Etc/GMT"].contains(identifier) { return "UTC" }
        guard TimeZone.knownTimeZoneIdentifiers.contains(identifier) else { return nil }
        return identifier
    }
}

/// Whether AI search can be switched on, and if not, why.
enum AIPrecondition: Equatable, Sendable {
    case ready
    case needsKey
    case needsInterests
    case needsKeyAndInterests

    init(hasKey: Bool, interests: [String]) {
        switch (hasKey, !interests.isEmpty) {
        case (true, true): self = .ready
        case (false, true): self = .needsKey
        case (true, false): self = .needsInterests
        case (false, false): self = .needsKeyAndInterests
        }
    }

    /// Shown next to the toggle while it cannot move to Let AI Search.
    var message: String? {
        switch self {
        case .ready: nil
        case .needsKey: "Add your API key below to let AI search."
        case .needsInterests: "Add at least one interest below to let AI search."
        case .needsKeyAndInterests: "Add your API key and at least one interest below to let AI search."
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
            "Your key couldn't be read from this phone. Enter it again."
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
    var hasKey: Bool
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
        let precondition = AIPrecondition(hasKey: hasKey, interests: interests)
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
