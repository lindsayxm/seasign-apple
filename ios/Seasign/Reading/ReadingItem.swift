import Foundation

/// What the reading view shows and what saving copies: one article as plain
/// values. A cached feed item (`FeedEntry`) and a saved item (`SavedItem`)
/// both produce one, so the reading view works for a saved article whose feed
/// item has been pruned or whose site is no longer followed.
///
/// `title`, `source` and `excerpt` came from a website and are plain text
/// only (`Text(verbatim:)`, `Text(caps:)`, or `String`s joined by hand).
struct ReadingItem: Identifiable, Hashable, Sendable {
    var link: String
    var title: String
    var source: String
    var published: Date
    var dateSource: FeedDateSource
    var excerpt: String?
    var category: String
    /// AI-found items are labelled wherever they appear.
    var origin: FeedOrigin = .site
    /// For an AI-found item, the interest it matched.
    var interest: String?
    /// For an AI-found item, the provider that found it.
    var provider: AIProvider?

    var id: String { link }

    var isAI: Bool { origin == .ai }

    var categoryChoice: CategoryChoice {
        CategoryChoice(name: category, isAI: isAI)
    }
}

extension ReadingItem {
    init(_ entry: FeedEntry) {
        self.init(
            link: entry.link,
            title: entry.title,
            source: entry.source,
            published: entry.published,
            dateSource: entry.dateSource,
            excerpt: entry.excerpt,
            category: entry.category,
            origin: entry.origin,
            interest: entry.interest,
            provider: entry.provider
        )
    }
}
