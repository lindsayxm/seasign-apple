import Foundation
import SwiftData

/// How the API reads a followed site: its RSS or Atom feed, or the article
/// links on the page itself. The raw values are the API's.
enum SiteMode: String, Codable, Sendable {
    case feed
    case links
}

/// A page the user follows, added in Settings › Sites. Lives in the user store.
///
/// The category is the user's own word for it ("Sci"); it is never derived
/// from the address. `title` comes from the site (through
/// `POST /v1/sites/resolve`) and is untrusted text: it is cleaned with
/// `SiteText.clean` before it is stored and shown only as plain text.
@Model
final class Site {
    /// Stable across devices once settings sync; not the SwiftData row identifier.
    /// Feed items and statuses refer to a site by this id.
    var id: UUID
    /// The page address in the API's normal form (`url` from resolve). Sent to
    /// `POST /v1/feed`.
    var url: String
    /// The page's or feed's title at the time it was added, cleaned and capped.
    var title: String
    /// The user's category, trimmed and capped (`CategoryName`).
    var category: String
    /// A `SiteMode` raw value; read it through `mode`.
    var modeRaw: String
    /// Only in feed mode: the feed the API reads.
    var feedUrl: String?
    var createdAt: Date

    var mode: SiteMode {
        SiteMode(rawValue: modeRaw) ?? .links
    }

    init(
        id: UUID = UUID(),
        url: String,
        title: String,
        category: String,
        mode: SiteMode,
        feedUrl: String?,
        createdAt: Date
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.category = category
        self.modeRaw = mode.rawValue
        self.feedUrl = feedUrl
        self.createdAt = createdAt
    }
}
