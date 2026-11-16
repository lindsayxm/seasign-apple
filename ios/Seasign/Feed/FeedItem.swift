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
    /// `Site.id` of the site this item came from; `FeedItem.noSite` for an
    /// AI-found item. Kept non-optional so the stored schema of this column
    /// does not change.
    var siteID: UUID
    /// The site's category when the item was fetched, or the interest an
    /// AI-found item matched.
    var category: String
    /// When this app first received the item; kept when the item is updated.
    var firstFetchedAt: Date
    /// A `FeedOrigin` raw value; nil (rows from before task 12) is a site.
    var originRaw: String?
    /// For an AI-found item: the interest it matched, as the user typed it.
    var interest: String?
    /// For an AI-found item: an `AIProvider` raw value.
    var providerRaw: String?

    /// The `siteID` of an AI-found item.
    static let noSite = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    init(_ entry: FeedEntry) {
        id = UUID()
        link = entry.link
        title = entry.title
        source = entry.source
        published = entry.published
        dateSourceRaw = entry.dateSource.rawValue
        excerpt = entry.excerpt
        siteID = entry.siteID ?? Self.noSite
        category = entry.category
        firstFetchedAt = entry.firstFetchedAt
        originRaw = entry.origin == .ai ? FeedOrigin.ai.rawValue : nil
        interest = entry.interest
        providerRaw = entry.provider?.rawValue
    }

    var origin: FeedOrigin {
        originRaw.flatMap(FeedOrigin.init(rawValue:)) ?? .site
    }

    /// Takes the newer copy of everything but `id` and `firstFetchedAt`. An
    /// AI-found row that a followed site now also has becomes the site's.
    func update(from entry: FeedEntry) {
        if title != entry.title { title = entry.title }
        if source != entry.source { source = entry.source }
        if published != entry.published { published = entry.published }
        if dateSourceRaw != entry.dateSource.rawValue { dateSourceRaw = entry.dateSource.rawValue }
        if excerpt != entry.excerpt { excerpt = entry.excerpt }
        let site = entry.siteID ?? Self.noSite
        if siteID != site { siteID = site }
        if category != entry.category { category = entry.category }
        let originValue = entry.origin == .ai ? FeedOrigin.ai.rawValue : nil
        if originRaw != originValue { originRaw = originValue }
        if interest != entry.interest { interest = entry.interest }
        if providerRaw != entry.provider?.rawValue { providerRaw = entry.provider?.rawValue }
    }

    var entry: FeedEntry {
        let origin = origin
        return FeedEntry(
            link: link,
            title: title,
            source: source,
            published: published,
            dateSource: FeedDateSource(rawValue: dateSourceRaw) ?? .published,
            excerpt: excerpt,
            siteID: origin == .ai ? nil : siteID,
            category: category,
            firstFetchedAt: firstFetchedAt,
            origin: origin,
            interest: origin == .ai ? interest : nil,
            provider: origin == .ai ? providerRaw.flatMap(AIProvider.init(rawValue:)) : nil
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
