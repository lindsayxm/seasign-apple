import CoreGraphics
import Foundation

/// Where an item's date comes from; the raw values are the API's.
enum FeedDateSource: String, Codable, Sendable {
    /// The site's own publication date.
    case published
    /// The site gives no date, so it is when the API first saw the link.
    case firstSeen = "first_seen"
}

/// One feed item as the app passes it around: a plain value copied out of
/// `FeedItem`, so screens never hold a row that a prune may delete.
struct FeedEntry: Identifiable, Hashable, Sendable {
    var link: String
    var title: String
    var source: String
    var published: Date
    var dateSource: FeedDateSource
    var excerpt: String?
    /// The followed site it came from; nil for an AI-found item.
    var siteID: UUID?
    /// A site's category, or for an AI-found item the interest it matched
    /// (empty when the model did not say). `origin` keeps the two apart.
    var category: String
    var firstFetchedAt: Date
    var origin: FeedOrigin = .site
    /// For an AI-found item, the interest it matched, as the user typed it.
    var interest: String?
    /// For an AI-found item, the provider that found it.
    var provider: AIProvider?

    var id: String { link }

    var isAI: Bool { origin == .ai }

    /// What History's category filter groups it under.
    var categoryChoice: CategoryChoice {
        CategoryChoice(name: category, isAI: isAI)
    }

    /// Items stay for 7 days after their date.
    static let lifetime: TimeInterval = 7 * 86_400

    func isExpired(at now: Date) -> Bool {
        published < now.addingTimeInterval(-Self.lifetime)
    }

    /// Newest first; items with the same date keep a fixed order by link.
    static func newestFirst(_ first: FeedEntry, _ second: FeedEntry) -> Bool {
        if first.published != second.published { return first.published > second.published }
        return first.link < second.link
    }
}

/// Why a site could not be read; the API's per-site error codes, from
/// `POST /v1/sites/resolve` and `POST /v1/feed` alike.
enum SiteProblem: String, Codable, CaseIterable, Sendable {
    case invalidURL = "invalid_url"
    case blockedHost = "blocked_host"
    case fetchFailed = "fetch_failed"
    case timeout
    case tooLarge = "too_large"
    case notFeed = "not_feed"
    case notHTML = "not_html"

    /// Shown in Settings. Fixed text: it never repeats the address or anything the site sent.
    var message: String {
        switch self {
        case .invalidURL:
            "That doesn't look like a web address. Check it and try again."
        case .blockedHost:
            "That address points to a private network, so it can't be followed."
        case .fetchFailed:
            "We couldn't reach that page. Check the address and try again."
        case .timeout:
            "That site took too long to answer. Try again in a moment."
        case .tooLarge:
            "That page is too large to read."
        case .notFeed:
            "That address returned something that isn't a news feed."
        case .notHTML:
            "That address didn't return a web page or a news feed."
        }
    }
}

/// What the app remembers about the last feed refresh: how each site went and
/// when the last full refresh succeeded. Stored as JSON in `CachedFeedState`.
struct FeedState: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        /// `Site.id`.
        var site: UUID
        /// Nil when the site was read.
        var problem: SiteProblem?
        var checkedAt: Date
    }

    var statuses: [Entry] = []
    /// When every followed site was last asked for in one successful request.
    var refreshedAt: Date?

    func status(for site: UUID) -> Entry? {
        statuses.first { $0.site == site }
    }

    /// With `entries` replacing whatever was known about those sites.
    func merging(_ entries: [Entry]) -> FeedState {
        let replaced = Set(entries.map(\.site))
        var copy = self
        copy.statuses = statuses.filter { !replaced.contains($0.site) } + entries
        return copy
    }

    /// Only the statuses of sites that are still followed.
    func keeping(sites: Set<UUID>) -> FeedState {
        var copy = self
        copy.statuses.removeAll { !sites.contains($0.site) }
        return copy
    }
}

/// Text that came from a website: a title, a source name, an excerpt.
///
/// It is untrusted. It is shown only as plain text (`Text(verbatim:)` or
/// `Text(caps:)`, never through `LocalizedStringKey`, Markdown or HTML), and
/// before it is stored it goes through `clean`, which keeps a line of text a
/// line of text whatever the site sent.
enum SiteText {
    static let titleLimit = 300
    static let sourceLimit = 120
    static let excerptLimit = 600

    /// Runs of white space (newlines included) become one space and the ends
    /// are trimmed; control characters and invisible format characters
    /// (zero-width spaces, direction marks and overrides) are dropped, except
    /// the joiners and tag characters that emoji sequences need. Longer than
    /// `limit` characters, it is cut at a character boundary and ends in "…".
    static func clean(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if isHidden(scalar) { continue }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        let cleaned = String(scalars)
        guard limit > 0 else { return "" }
        guard cleaned.count > limit else { return cleaned }
        let kept = cleaned.prefix(limit - 1)
        return String(kept).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control:
            return true
        case .format:
            // Zero-width non-joiner and joiner, and the tag characters of
            // subdivision flags, are part of how some text and emoji are written.
            let value = scalar.value
            return !(value == 0x200C || value == 0x200D || (0xE0020...0xE007F).contains(value))
        default:
            return false
        }
    }
}

/// One entry of the CATEGORY menu in History and Saved: a category the user
/// gave a site, or the interest an AI-found item matched. The flag keeps an
/// interest apart from a user category of the same name ("space" the
/// interest is not "Space" the category), so neither filter ever shows the
/// other's items.
struct CategoryChoice: Hashable, Sendable, ExpressibleByStringLiteral {
    var name: String
    var isAI: Bool

    init(name: String, isAI: Bool = false) {
        self.name = name
        self.isAI = isAI
    }

    /// A user category.
    init(stringLiteral value: String) {
        self.init(name: value)
    }

    /// "Sci", "AI · tide pools", or "AI" for items with no matched interest.
    var label: String {
        guard isAI else { return name }
        return name.isEmpty ? AILabel.mark : AILabel.mark + " · " + name
    }

    /// Same kind, and the same name ignoring case.
    func matches(_ other: CategoryChoice) -> Bool {
        isAI == other.isAI && name.caseInsensitiveCompare(other.name) == .orderedSame
    }

    /// Each choice once (ignoring case within a kind), user categories in
    /// alphabetical order first, then the AI interests in alphabetical order.
    static func distinct(_ choices: [CategoryChoice]) -> [CategoryChoice] {
        var seen = Set<String>()
        var result: [CategoryChoice] = []
        for choice in choices where !choice.name.isEmpty || choice.isAI {
            if seen.insert((choice.isAI ? "ai:" : "site:") + choice.name.lowercased()).inserted {
                result.append(choice)
            }
        }
        return result.sorted {
            if $0.isAI != $1.isAI { return !$0.isAI }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// The address of an article, as the reading view may open it.
enum ArticleLink {
    /// What two spellings of one article's address have in common: the host
    /// in lower case without a leading `www.`, the path without a trailing
    /// slash, and the query; the scheme and fragment are left out. Used to
    /// keep an AI-found copy of an article a followed site already has.
    static func matchKey(_ text: String) -> String {
        guard let components = URLComponents(string: text), let host = components.host?.lowercased() else {
            return text
        }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return bareHost + path + query
    }

    /// The link as a URL if it is an absolute https address with a host and no
    /// user name or password, and not absurdly long; otherwise nil. Nothing
    /// else is ever offered to the system to open.
    static func url(_ text: String) -> URL? {
        guard text.utf8.count <= 2048,
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }
}

/// A page address typed in Settings, made ready for `POST /v1/sites/resolve`.
enum SiteAddress {
    /// The most UTF-8 bytes a site's `url` and `feedUrl` may take together.
    /// The API refuses request bodies over 64 KB; 50 sites at this length
    /// still fit even if every character had to be escaped in JSON.
    static let maxBytes = 560

    /// Trimmed; `https://` added when no scheme is typed, and `http://`
    /// read as `https://` (the API follows https only). Nil when the text is
    /// empty, has spaces inside, uses another scheme or has no host.
    static func normalize(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        var text: String
        if let separator = trimmed.range(of: "://") {
            let scheme = trimmed[..<separator.lowerBound].lowercased()
            guard scheme == "https" || scheme == "http" else { return nil }
            text = "https://" + trimmed[separator.upperBound...]
        } else {
            // "example.com:443/x" would read as a scheme to URLComponents, so
            // the test is for "://", not for a parsed scheme.
            text = "https://" + trimmed
        }
        guard let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { return nil }
        return text
    }

    static func fits(url: String, feedUrl: String?) -> Bool {
        url.utf8.count + (feedUrl?.utf8.count ?? 0) <= maxBytes
    }
}

/// The category the user gives a site.
enum CategoryName {
    static let maxLength = 24

    /// Trimmed, white space collapsed, invisible characters dropped, at most
    /// `maxLength` characters. If a category already in use matches it
    /// ignoring case, that spelling is used: "sci" and "Sci" look the same in caps.
    static func clean(_ typed: String, existing: [String] = []) -> String {
        let cleaned = String(SiteText.clean(typed, limit: Int.max).prefix(maxLength))
            .trimmingCharacters(in: .whitespaces)
        return existing.first { $0.caseInsensitiveCompare(cleaned) == .orderedSame } ?? cleaned
    }

    /// The categories in use, each once (ignoring case), in alphabetical order.
    static func distinct(_ categories: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for category in categories where !category.isEmpty {
            if seen.insert(category.lowercased()).inserted {
                result.append(category)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// Which items Today shows.
enum HeadlinePicker {
    /// Midnight at the start of yesterday in `timeZone`. Calendar days, not
    /// 24-hour steps, so a day with a daylight-saving change is still one day.
    static func startOfYesterday(now: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
    }

    /// Items dated since the start of yesterday in `timeZone`, newest first.
    static func sinceYesterday(_ entries: [FeedEntry], now: Date, timeZone: TimeZone) -> [FeedEntry] {
        let start = startOfYesterday(now: now, timeZone: timeZone)
        return entries.filter { $0.published >= start }.sorted(by: FeedEntry.newestFirst)
    }
}

/// How many headlines Today shows: as many of the newest as fit in the water
/// above the `>>` button, whole, with no scrolling.
enum HeadlineFit {
    /// Never more than this many, even on a tall screen.
    static let maxCount = 5

    /// The longest run from the start of `heights` (each headline's height,
    /// newest first) that fits in `available` with `spacing` between
    /// headlines, and no more than `limit`.
    static func count(heights: [CGFloat], spacing: CGFloat, available: CGFloat, limit: Int = maxCount) -> Int {
        var used: CGFloat = 0
        var count = 0
        for height in heights.prefix(max(0, limit)) {
            let next = used + (count == 0 ? 0 : spacing) + height
            // A hair of tolerance for rounding in the measured sizes.
            guard next <= available + 0.5 else { break }
            used = next
            count += 1
        }
        return count
    }
}

/// The date line of the reading view.
struct ReadingDate: Equatable, Sendable {
    /// "Published" or "First seen".
    var label: String
    /// "Nov 15, 2026 2:18PM", in the time zone given. Built by hand so the
    /// phone's region and 24-hour setting do not change it, like the event times.
    var value: String

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    init(entry: FeedEntry, timeZone: TimeZone) {
        self.init(published: entry.published, dateSource: entry.dateSource, timeZone: timeZone)
    }

    init(item: ReadingItem, timeZone: TimeZone) {
        self.init(published: item.published, dateSource: item.dateSource, timeZone: timeZone)
    }

    init(published: Date, dateSource: FeedDateSource, timeZone: TimeZone) {
        label = dateSource == .firstSeen ? "First seen" : "Published"
        let parts = Self.parts(of: published, in: timeZone)
        let hour = parts.hour ?? 0
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let minute = String(format: "%02d", parts.minute ?? 0)
        value = Self.day(parts) + " \(hour12):\(minute)\(hour < 12 ? "AM" : "PM")"
    }

    /// "Nov 10, 2026": the day alone, for the `SOURCE · DATE` line of the
    /// History and Saved rows. Built by hand like `value`.
    static func day(_ date: Date, timeZone: TimeZone) -> String {
        day(parts(of: date, in: timeZone))
    }

    private static func parts(of date: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private static func day(_ parts: DateComponents) -> String {
        let month = months[max(0, min(11, (parts.month ?? 1) - 1))]
        return "\(month) \(parts.day ?? 1), \(parts.year ?? 1970)"
    }
}

/// The line under a site in Settings.
struct SiteStatusLine: Equatable, Sendable {
    var text: String
    /// The last read failed; shown in the warning colour.
    var isProblem: Bool

    init(status: FeedState.Entry?, itemCount: Int) {
        guard let status else {
            text = "Not read yet"
            isProblem = false
            return
        }
        if let problem = status.problem {
            text = problem.message
            isProblem = true
        } else {
            switch itemCount {
            case 0: text = "No articles in the last 7 days"
            case 1: text = "1 article in the last 7 days"
            default: text = "\(itemCount) articles in the last 7 days"
            }
            isProblem = false
        }
    }
}
