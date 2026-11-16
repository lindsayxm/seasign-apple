import Foundation
import SwiftData

/// An article the user saved, with their notes. Lives in the user store.
///
/// It is a full copy of what the reading view and Saved need, taken when the
/// article was saved. It never refers to a `FeedItem`: those are pruned
/// 7 days after their date and deleted when their site is unfollowed, and a
/// saved article has to outlive both.
///
/// `title`, `source` and `excerpt` came from a website (cleaned with
/// `SiteText.clean` when they were fetched, and again when saved) and are
/// shown only as plain text. `notes` is the user's own writing, kept as typed
/// up to `SavedModel.notesLimit` characters.
///
/// One row per `link`. That is enforced by `SavedModel`, which looks the link
/// up before inserting; `@Attribute(.unique)` is not used because a second
/// insert would then replace the first row, notes and all.
@Model
final class SavedItem {
    /// Stable across devices once saved items sync; not the SwiftData row identifier.
    var id: UUID
    /// The article's https address.
    var link: String
    var title: String
    var source: String
    var published: Date
    /// A `FeedDateSource` raw value.
    var dateSourceRaw: String
    var excerpt: String?
    /// The site's category when the article was saved.
    var category: String
    /// The user's notes, as typed. Empty when there are none.
    var notes: String
    var savedAt: Date
    /// When the item was saved or its notes last changed.
    var updatedAt: Date

    init(id: UUID = UUID(), _ item: ReadingItem, notes: String = "", savedAt: Date) {
        self.id = id
        link = item.link
        title = item.title
        source = item.source
        published = item.published
        dateSourceRaw = item.dateSource.rawValue
        excerpt = item.excerpt
        category = item.category
        self.notes = notes
        self.savedAt = savedAt
        updatedAt = savedAt
    }

    var readingItem: ReadingItem {
        ReadingItem(
            link: link,
            title: title,
            source: source,
            published: published,
            dateSource: FeedDateSource(rawValue: dateSourceRaw) ?? .published,
            excerpt: excerpt,
            category: category
        )
    }

    var entry: SavedEntry {
        SavedEntry(id: id, item: readingItem, notes: notes, savedAt: savedAt)
    }
}

/// A saved article as the screens pass it around: plain values copied out of
/// `SavedItem`, so no view or dialog holds a row that a removal deletes.
struct SavedEntry: Identifiable, Hashable, Sendable {
    var id: UUID
    var item: ReadingItem
    /// The stored notes (a draft not yet written is in `SavedModel.notes(for:)`).
    var notes: String
    var savedAt: Date
}
