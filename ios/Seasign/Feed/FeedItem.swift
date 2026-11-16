import Foundation
import SwiftData

/// One article from `POST /v1/feed`, kept in the cache store so Today and the
/// 7-day history (task 9) can show it before the network answers.
///
/// Everything here can be fetched again: nothing the user typed lives in this
/// row except a copy of the site's category, taken when the item was fetched.
/// Items are found again by `link` (one row per link; `FeedStore.upsert`
/// merges by it), which is also what a saved item will refer to. They are
/// deleted once `published` is more than 7 days ago.
///
/// `title`, `source` and `excerpt` come from arbitrary websites. They are
/// cleaned and capped by `SiteText.clean` before they are stored and must only
/// ever be shown as plain text (`Text(verbatim:)` or `Text(caps:)`).
@Model
final class FeedItem {
    var id: UUID
    /// The article's https address; one row per link.
    var link: String
    var title: String
    /// The feed's or site's name, as the site gives it.
    var source: String
    /// When the article was published, or first seen by the API (`dateSource`).
    var published: Date
    /// A `FeedDateSource` raw value.
    var dateSourceRaw: String
    /// The site's own summary; nil when it gives none (always nil for a site
    /// followed by its links).
    var excerpt: String?
    /// `Site.id` of the site this item came from.
    var siteID: UUID
    /// The site's category when the item was fetched.
    var category: String
    /// When this app first received the item; kept when the item is updated.
    var firstFetchedAt: Date

    init(_ entry: FeedEntry) {
        id = UUID()
        link = entry.link
        title = entry.title
        source = entry.source
        published = entry.published
        dateSourceRaw = entry.dateSource.rawValue
        excerpt = entry.excerpt
        siteID = entry.siteID
        category = entry.category
        firstFetchedAt = entry.firstFetchedAt
    }

    /// Takes the newer copy of everything but `id` and `firstFetchedAt`.
    func update(from entry: FeedEntry) {
        if title != entry.title { title = entry.title }
        if source != entry.source { source = entry.source }
        if published != entry.published { published = entry.published }
        if dateSourceRaw != entry.dateSource.rawValue { dateSourceRaw = entry.dateSource.rawValue }
        if excerpt != entry.excerpt { excerpt = entry.excerpt }
        if siteID != entry.siteID { siteID = entry.siteID }
        if category != entry.category { category = entry.category }
    }

    var entry: FeedEntry {
        FeedEntry(
            link: link,
            title: title,
            source: source,
            published: published,
            dateSource: FeedDateSource(rawValue: dateSourceRaw) ?? .published,
            excerpt: excerpt,
            siteID: siteID,
            category: category,
            firstFetchedAt: firstFetchedAt
        )
    }
}

/// How the last feed refresh went for each site, and when the last full
/// refresh succeeded. At most one row; it holds no address, only site ids.
@Model
final class CachedFeedState {
    /// A JSON-encoded `FeedState`.
    var payload: Data
    var fetchedAt: Date

    init(payload: Data, fetchedAt: Date) {
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}
