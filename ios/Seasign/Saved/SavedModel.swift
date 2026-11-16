import Foundation
import Observation
import SwiftData

/// The saved articles and their notes (user store).
///
/// Saving copies the article into a `SavedItem`, so it stays after the feed
/// item is pruned or its site is removed. A link is saved once: saving it
/// again changes nothing, notes included.
///
/// Notes are the user's own writing and are handled with care:
/// - what is typed is kept here as a draft (`drafts`), never only in a view,
///   so a row scrolled away or a screen closed does not drop it;
/// - a draft is written a moment after typing stops (`noteDelay`), and at
///   once by `flushNotes()`, which the views call when a field loses focus,
///   when Saved closes and when the app leaves the foreground;
/// - a write that fails keeps the draft (on screen and in memory), sets
///   `problem` so the user is told, and is tried again on the next flush.
@MainActor
@Observable
final class SavedModel {
    enum Problem: Error, Equatable {
        /// An article could not be written to the phone.
        case notSaved
        /// A saved article could not be removed.
        case notRemoved
        /// Notes could not be written; the draft is still held.
        case notesNotSaved

        var message: String {
            switch self {
            case .notSaved:
                "That article couldn't be saved on this phone. Try again."
            case .notRemoved:
                "That article couldn't be removed. Try again."
            case .notesNotSaved:
                "Your latest notes couldn't be saved on this phone. They're kept while Seasign is open. Try again."
            }
        }
    }

    /// The longest notes kept for one article, in characters.
    nonisolated static let notesLimit = 2_000

    /// Every saved article, most recently saved first.
    private(set) var entries: [SavedEntry] = []
    /// The links of every saved article, for History's saved marks.
    private(set) var savedLinks: Set<String> = []
    /// Notes typed but not yet written, by `SavedItem.id`.
    private(set) var drafts: [UUID: String] = [:]
    /// The last thing that went wrong, shown on the screen until it is dismissed or fixed.
    var problem: Problem?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let noteDelay: Duration
    @ObservationIgnored private let commit: (ModelContext) throws -> Void
    @ObservationIgnored private var pendingWrites: [UUID: Task<Void, Never>] = [:]

    /// `commit` writes the context; tests replace it to make a write fail.
    init(
        context: ModelContext,
        now: @escaping () -> Date = { Date() },
        noteDelay: Duration = .milliseconds(800),
        commit: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.now = now
        self.noteDelay = noteDelay
        self.commit = commit
        reload()
    }

    // MARK: Reading

    func isSaved(_ link: String) -> Bool {
        savedLinks.contains(link)
    }

    func entry(link: String) -> SavedEntry? {
        entries.first { $0.item.link == link }
    }

    /// The categories of the saved articles, each once.
    var categories: [String] {
        CategoryName.distinct(entries.map(\.item.category))
    }

    /// The saved articles that match the search and category, most recently saved first.
    func visible(_ query: ArticleQuery) -> [SavedEntry] {
        entries.filter { query.matches($0.item) }
    }

    /// The notes to show for an article: the draft being typed, else what is stored.
    func notes(for id: UUID) -> String {
        drafts[id] ?? entries.first { $0.id == id }?.notes ?? ""
    }

    /// True when the article has notes, counting a draft not yet written.
    func hasNotes(_ id: UUID) -> Bool {
        !notes(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasNotes(link: String) -> Bool {
        entry(link: link).map { hasNotes($0.id) } ?? false
    }

    // MARK: Saving and removing

    /// Saves a copy of the article. Saving a link that is already saved
    /// changes nothing and returns true. Returns false, with nothing stored,
    /// when the link is not one the app would open or the write failed.
    @discardableResult
    func save(_ item: ReadingItem) -> Bool {
        if row(link: item.link) != nil { return true }
        guard ArticleLink.url(item.link) != nil else { return false }
        // Cleaned when fetched; cleaned again, since this copy outlives the cache.
        var copy = item
        copy.title = SiteText.clean(item.title, limit: SiteText.titleLimit)
        copy.source = SiteText.clean(item.source, limit: SiteText.sourceLimit)
        copy.excerpt = item.excerpt.map { SiteText.clean($0, limit: SiteText.excerptLimit) }
        if copy.excerpt?.isEmpty == true { copy.excerpt = nil }
        copy.category = CategoryName.clean(item.category)
        guard !copy.title.isEmpty else { return false }

        context.insert(SavedItem(copy, savedAt: now()))
        guard write() else {
            problem = .notSaved
            return false
        }
        if problem == .notSaved { problem = nil }
        return true
    }

    /// Removes a saved article and its notes, a draft included. Returns
    /// false, with the article still saved, if that could not be written.
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard let row = row(id: id) else {
            forgetDraft(id)
            return true
        }
        context.delete(row)
        guard write() else {
            problem = .notRemoved
            return false
        }
        forgetDraft(id)
        if problem == .notRemoved { problem = nil }
        return true
    }

    /// Removes the saved copy of `link`, if there is one.
    @discardableResult
    func unsave(link: String) -> Bool {
        guard let id = entry(link: link)?.id ?? row(link: link)?.id else { return true }
        return remove(id)
    }

    // MARK: Notes

    /// Takes what is typed in an article's notes: at most `notesLimit`
    /// characters, kept as typed (spaces and line breaks included), written a
    /// moment after typing stops. Returns the text as kept, which is what the
    /// field should show.
    @discardableResult
    func editNotes(_ text: String, for id: UUID) -> String {
        let kept = text.count > Self.notesLimit ? String(text.prefix(Self.notesLimit)) : text
        guard entries.contains(where: { $0.id == id }) else { return kept }
        drafts[id] = kept
        pendingWrites[id]?.cancel()
        let delay = noteDelay
        pendingWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushNotes(for: id)
        }
        return kept
    }

    /// Writes every draft now. Returns true when nothing is left unwritten.
    @discardableResult
    func flushNotes() -> Bool {
        var allWritten = true
        for id in Array(drafts.keys) where !flushNotes(for: id) {
            allWritten = false
        }
        return allWritten
    }

    /// Writes one article's draft now. Returns true when it is written (or
    /// there was nothing to write). On failure the draft is kept, `problem`
    /// says so, and the next flush tries again.
    @discardableResult
    func flushNotes(for id: UUID) -> Bool {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = nil
        guard let draft = drafts[id] else { return true }
        guard let row = row(id: id) else {
            // Removed meanwhile; its notes went with it.
            drafts[id] = nil
            return true
        }
        if row.notes != draft {
            row.notes = draft
            row.updatedAt = now()
            guard write() else {
                problem = .notesNotSaved
                return false
            }
        }
        drafts[id] = nil
        if problem == .notesNotSaved, drafts.isEmpty { problem = nil }
        return true
    }

    // MARK: Store

    private func row(link: String) -> SavedItem? {
        var descriptor = FetchDescriptor<SavedItem>(predicate: #Predicate { $0.link == link })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func row(id: UUID) -> SavedItem? {
        var descriptor = FetchDescriptor<SavedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func forgetDraft(_ id: UUID) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = nil
        drafts[id] = nil
        if problem == .notesNotSaved, drafts.isEmpty { problem = nil }
    }

    /// Saves the context. On failure the change is rolled back so memory and
    /// the store agree; drafts are held apart from the context, so a rolled
    /// back notes write loses nothing typed.
    private func write() -> Bool {
        defer { reload() }
        do {
            try commit(context)
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    private func reload() {
        let rows = (try? context.fetch(FetchDescriptor<SavedItem>())) ?? []
        let fresh = rows.map(\.entry).sorted {
            ($0.savedAt, $1.id.uuidString) > ($1.savedAt, $0.id.uuidString)
        }
        if fresh != entries { entries = fresh }
        let links = Set(fresh.map(\.item.link))
        if links != savedLinks { savedLinks = links }
    }
}

#if DEBUG
extension SavedModel {
    /// Debug-only (`-debugSaved YES`): three saved articles, one with notes
    /// and one whose feed item is not in the cache, written into `context`,
    /// which is an in-memory store (see `SeasignApp`). Nothing reaches the
    /// user's own store.
    static func sample(context: ModelContext, now: Date = Date()) throws -> SavedModel {
        let items: [(ReadingItem, String)] = [
            (
                ReadingItem(
                    link: "https://news.example.com/sample/0",
                    title: PlaceholderHeadlines.all[0],
                    source: "Example News",
                    published: now.addingTimeInterval(-2.5 * 3600),
                    dateSource: .published,
                    excerpt: "Forecasters explain how warm water in the Pacific changes winters far away, in three minutes.",
                    category: "Sci"
                ),
                ""
            ),
            (
                ReadingItem(
                    link: "https://science.example.com/2026/11/x-70-fractal",
                    title: "Here’s what we know about the X-70 Fractal, NASA’s experimental new plane",
                    source: "Science",
                    published: now.addingTimeInterval(-5 * 86_400),
                    dateSource: .published,
                    excerpt: nil,
                    category: "Sci"
                ),
                "Ask Sam about the wing shape."
            ),
            (
                ReadingItem(
                    link: "https://quantum.example.org/percolation",
                    title: "Entanglement percolation enhanced by the power of choice",
                    source: "Quantum",
                    published: now.addingTimeInterval(-12 * 86_400),
                    dateSource: .firstSeen,
                    excerpt: "A network that picks which links to keep shares entanglement further.",
                    category: "Physics"
                ),
                ""
            ),
        ]
        for (index, (item, notes)) in items.enumerated() {
            context.insert(SavedItem(item, notes: notes, savedAt: now.addingTimeInterval(-Double(index) * 3600)))
        }
        try context.save()
        return SavedModel(context: context, now: { now })
    }
}
#endif
