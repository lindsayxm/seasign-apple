import Foundation

/// The search and category filter of History and Saved.
///
/// Matching is plain text, done in memory: the typed words are compared with
/// the title and source ignoring case, accents and width, and curly quotes
/// count as straight ones. Nothing the user types is ever turned into a
/// predicate, a pattern or a format string.
struct ArticleQuery: Equatable, Sendable {
    /// What is typed in the search field.
    var text = ""
    /// The chosen category; nil is "All". An AI interest and a user
    /// category of the same name are different choices.
    var category: CategoryChoice?

    /// Every word typed must appear in the title or the source (not
    /// necessarily the same one); with nothing typed, everything matches.
    /// The category, when one is chosen, must be of the same kind (a user
    /// category or an AI interest) and match ignoring case, the way
    /// `CategoryChoice.distinct` lists them.
    func matches(title: String, source: String, category itemCategory: String, isAI: Bool = false) -> Bool {
        if let category, !category.matches(CategoryChoice(name: itemCategory, isAI: isAI)) {
            return false
        }
        let words = Self.fold(text).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [Self.fold(title), Self.fold(source)]
        return words.allSatisfy { word in
            haystack.contains { $0.range(of: word, options: Self.options) != nil }
        }
    }

    func matches(_ item: ReadingItem) -> Bool {
        matches(title: item.title, source: item.source, category: item.category, isAI: item.isAI)
    }

    /// The choice to keep showing when the menu's categories change: a
    /// category no longer present in the list falls back to All, so the
    /// screen never sits on an empty filter nobody can see in the menu.
    static func choice(_ selected: CategoryChoice?, among categories: [CategoryChoice]) -> CategoryChoice? {
        guard let selected else { return nil }
        return categories.first { $0.matches(selected) }
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Curly quotes and apostrophes read as straight ones, so "it's" finds "It’s".
    private static func fold(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{02BC}": result.append("'")
            case "\u{201C}", "\u{201D}": result.append("\"")
            default: result.append(character)
            }
        }
        return result
    }
}

/// What the 7-day history shows: every cached feed item dated within the last
/// 7 days, newest first, through the search and category filter.
enum HistoryList {
    /// Items dated more than `FeedEntry.lifetime` before `now` are left out
    /// even if they are still in the cache (the cache is pruned on load and
    /// on refresh, not continuously).
    static func visible(_ entries: [FeedEntry], now: Date, query: ArticleQuery) -> [FeedEntry] {
        recent(entries, now: now)
            .filter { query.matches(title: $0.title, source: $0.source, category: $0.category, isAI: $0.isAI) }
    }

    /// The categories of the items History can show, each once; AI
    /// interests are listed apart from the user's own categories.
    static func categories(_ entries: [FeedEntry], now: Date) -> [CategoryChoice] {
        CategoryChoice.distinct(recent(entries, now: now).map(\.categoryChoice))
    }

    private static func recent(_ entries: [FeedEntry], now: Date) -> [FeedEntry] {
        entries.filter { !$0.isExpired(at: now) }.sorted(by: FeedEntry.newestFirst)
    }
}
