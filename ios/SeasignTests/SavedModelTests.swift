import Foundation
import SwiftData
import Testing

@testable import Seasign

/// A write that can be made to fail, standing in for a full disk.
@MainActor
private final class Writes {
    struct Failure: Error {}
    var fail = false
    var count = 0

    func commit(_ context: ModelContext) throws {
        count += 1
        if fail { throw Failure() }
        try context.save()
    }
}

private let savedNow = instant("2026-11-15T23:05:00Z")

private func article(
    _ title: String,
    link: String? = nil,
    source: String = "Example News",
    category: String = "Sci",
    excerpt: String? = "What it says.",
    published: Date = savedNow.addingTimeInterval(-3600)
) -> ReadingItem {
    ReadingItem(
        link: link ?? "https://news.example.com/" + title.lowercased().replacingOccurrences(of: " ", with: "-"),
        title: title,
        source: source,
        published: published,
        dateSource: .published,
        excerpt: excerpt,
        category: category
    )
}

@Suite @MainActor struct SavedModelTests {
    private let writes = Writes()

    private func model(_ context: ModelContext, delay: Duration = .seconds(60)) -> SavedModel {
        let writes = writes
        return SavedModel(context: context, now: { savedNow }, noteDelay: delay, commit: { try writes.commit($0) })
    }

    private func storedNotes(_ context: ModelContext) throws -> [String] {
        try ModelContext(context.container).fetch(FetchDescriptor<SavedItem>()).map(\.notes)
    }

    // MARK: Saving

    @Test func savingCopiesTheArticle() throws {
        let context = try inMemoryContext()
        let model = model(context)
        let item = article("A new telescope sees first light")
        #expect(model.save(item))
        #expect(model.isSaved(item.link))
        let entry = try #require(model.entries.first)
        #expect(entry.item == item)
        #expect(entry.notes == "")
        #expect(entry.savedAt == savedNow)

        let row = try #require(try ModelContext(context.container).fetch(FetchDescriptor<SavedItem>()).first)
        #expect(row.readingItem == item)
        #expect(row.updatedAt == savedNow)
    }

    @Test func savingALinkTwiceChangesNothing() throws {
        let context = try inMemoryContext()
        let item = article("Crows make decisions faster than we can")
        let first = model(context)
        first.save(item)
        let id = try #require(first.entries.first?.id)
        first.editNotes("Read again", for: id)
        #expect(first.flushNotes())

        // Later, from another screen, with a changed title.
        let later = SavedModel(context: context, now: { savedNow.addingTimeInterval(86_400) })
        var changed = item
        changed.title = "Crows (updated)"
        #expect(later.save(changed))
        #expect(later.entries.count == 1)
        #expect(later.entries[0].notes == "Read again")
        #expect(later.entries[0].savedAt == savedNow)
        #expect(later.entries[0].item.title == "Crows make decisions faster than we can")
        #expect(try context.fetch(FetchDescriptor<SavedItem>()).count == 1)
    }

    @Test func aLinkTheAppWouldNotOpenIsNotSaved() throws {
        let model = model(try inMemoryContext())
        #expect(!model.save(article("Script", link: "javascript:alert(1)")))
        #expect(!model.save(article("Plain", link: "http://news.example.com/plain")))
        #expect(model.entries.isEmpty)
    }

    @Test func textIsCleanedAgainWhenSaved() throws {
        let model = model(try inMemoryContext())
        model.save(article("Line one\nLine\u{202E} two", excerpt: "  \n "))
        let entry = try #require(model.entries.first)
        #expect(entry.item.title == "Line one Line two")
        #expect(entry.item.excerpt == nil)
    }

    @Test func aFailedSaveStoresNothingAndSaysSo() throws {
        let context = try inMemoryContext()
        let model = model(context)
        writes.fail = true
        #expect(!model.save(article("Telescope")))
        #expect(model.problem == .notSaved)
        #expect(model.entries.isEmpty)
        #expect(try context.fetch(FetchDescriptor<SavedItem>()).isEmpty)

        writes.fail = false
        #expect(model.save(article("Telescope")))
        #expect(model.problem == nil)
        #expect(model.entries.count == 1)
    }

    @Test func mostRecentlySavedFirst() throws {
        let context = try inMemoryContext()
        var clock = savedNow
        let model = SavedModel(context: context, now: { clock })
        model.save(article("First"))
        clock = savedNow.addingTimeInterval(60)
        model.save(article("Second"))
        #expect(model.entries.map(\.item.title) == ["Second", "First"])
    }

    // MARK: The guarantee

    /// A saved article does not depend on the cached feed item: it is all
    /// there after the site is unfollowed (which deletes the site's items at
    /// once) and after the item would have been pruned, and it still opens.
    @Test func savedSurvivesSiteRemovalAndPruning() throws {
        let context = try inMemoryContext()
        let site = Site(
            url: "https://news.example.com/science/", title: "Science | Example News", category: "Sci",
            mode: .feed, feedUrl: "https://news.example.com/science/feed/", createdAt: savedNow
        )
        context.insert(site)
        let feedEntry = FeedEntry(
            link: "https://news.example.com/science/telescope/",
            title: "A new telescope sees first light",
            source: "Example News",
            published: savedNow.addingTimeInterval(-3600),
            dateSource: .published,
            excerpt: "The observatory released its first images.",
            siteID: site.id,
            category: "Sci",
            firstFetchedAt: savedNow
        )
        let other = FeedEntry(
            link: "https://news.example.com/science/crows/",
            title: "Crows", source: "Example News", published: savedNow.addingTimeInterval(-7200),
            dateSource: .firstSeen, excerpt: nil, siteID: site.id, category: "Sci", firstFetchedAt: savedNow
        )
        context.insert(FeedItem(feedEntry))
        context.insert(FeedItem(other))
        try context.save()

        let feed = FeedModel(context: context, now: { savedNow })
        let saved = model(context)
        let opened = ReadingItem(try #require(feed.entries.first { $0.link == feedEntry.link }))
        saved.save(opened)
        saved.save(ReadingItem(other))
        let id = try #require(saved.entry(link: feedEntry.link)?.id)
        saved.editNotes("Ask about the mirror.", for: id)
        #expect(saved.flushNotes())

        // Unfollowing the site deletes its cached items straight away.
        feed.remove(try #require(feed.sites.first))
        #expect(feed.entries.isEmpty)
        #expect(FeedStore(context: context).item(link: feedEntry.link) == nil)

        // And eight days on, a fresh launch prunes whatever is old.
        let later = FeedModel(context: context, now: { savedNow.addingTimeInterval(8 * 86_400) })
        #expect(later.entries.isEmpty)

        let relaunched = SavedModel(context: ModelContext(context.container))
        #expect(relaunched.entries.count == 2)
        let entry = try #require(relaunched.entry(link: feedEntry.link))
        #expect(entry.item == opened)
        #expect(entry.item.excerpt == "The observatory released its first images.")
        #expect(entry.notes == "Ask about the mirror.")
        #expect(relaunched.entry(link: other.link)?.item.dateSource == .firstSeen)
    }

    // MARK: Notes

    @Test func notesAreKeptAsTypedAndWrittenOnFlush() throws {
        let context = try inMemoryContext()
        let model = model(context)
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        let typed = "  First line\n\nSecond line with *stars* and [a](link)  "
        #expect(model.editNotes(typed, for: id) == typed)
        #expect(model.notes(for: id) == typed)
        // Not written yet: the delay has not passed.
        #expect(try storedNotes(context) == [""])

        #expect(model.flushNotes())
        #expect(try storedNotes(context) == [typed])
        #expect(model.drafts.isEmpty)
        #expect(model.notes(for: id) == typed)
        #expect(SavedModel(context: ModelContext(context.container)).entries.first?.notes == typed)
    }

    @Test func notesAreWrittenAMomentAfterTypingStops() async throws {
        let context = try inMemoryContext()
        let model = model(context, delay: .milliseconds(20))
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        model.editNotes("Draft", for: id)
        model.editNotes("Draft two", for: id)
        for _ in 0..<200 where !model.drafts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.drafts.isEmpty)
        #expect(try storedNotes(context) == ["Draft two"])
    }

    @Test func notesAreCappedAtTheLimit() throws {
        let context = try inMemoryContext()
        let model = model(context)
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        let long = String(repeating: "é", count: SavedModel.notesLimit + 50)
        let kept = model.editNotes(long, for: id)
        #expect(kept.count == SavedModel.notesLimit)
        #expect(model.notes(for: id).count == SavedModel.notesLimit)
        model.flushNotes()
        #expect(try storedNotes(context).first?.count == SavedModel.notesLimit)
    }

    /// A write that fails never loses what was typed: the draft stays on
    /// screen and in memory, the user is told, and the next flush writes it.
    @Test func aFailedNotesWriteKeepsTheDraftAndSaysSo() throws {
        let context = try inMemoryContext()
        let model = model(context)
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        model.editNotes("Kept", for: id)
        model.flushNotes()

        writes.fail = true
        model.editNotes("Kept, and more", for: id)
        #expect(!model.flushNotes())
        #expect(model.problem == .notesNotSaved)
        #expect(model.notes(for: id) == "Kept, and more")
        #expect(model.hasNotes(id))
        #expect(try storedNotes(context) == ["Kept"])
        // Still failing: still kept.
        #expect(!model.flushNotes(for: id))
        #expect(model.notes(for: id) == "Kept, and more")

        writes.fail = false
        #expect(model.flushNotes())
        #expect(model.problem == nil)
        #expect(try storedNotes(context) == ["Kept, and more"])
    }

    @Test func aFlushWithNothingChangedDoesNotWrite() throws {
        let context = try inMemoryContext()
        let model = model(context)
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        let before = writes.count
        model.editNotes("", for: id)
        #expect(model.flushNotes())
        #expect(writes.count == before)
        #expect(model.drafts.isEmpty)
    }

    // MARK: Removing

    @Test func removeWithoutNotesHappensAtOnce() throws {
        let context = try inMemoryContext()
        let model = model(context)
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        #expect(model.requestRemoval(id) == .removed)
        #expect(model.entries.isEmpty)
        #expect(try context.fetch(FetchDescriptor<SavedItem>()).isEmpty)
    }

    @Test func removeWithNotesAsksFirst() throws {
        let context = try inMemoryContext()
        let model = model(context)
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        model.editNotes("Mine", for: id)
        model.flushNotes()
        #expect(model.requestRemoval(id) == .needsConfirmation)
        #expect(model.entries.count == 1)

        // Confirmed.
        #expect(model.remove(id))
        #expect(model.entries.isEmpty)
    }

    /// Notes typed a moment ago and not written yet count as notes.
    @Test func anUnwrittenDraftCountsAsNotes() throws {
        let model = model(try inMemoryContext())
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        model.editNotes("Just typed", for: id)
        #expect(model.requestRemoval(id) == .needsConfirmation)
        model.editNotes("   \n", for: id)
        #expect(!model.hasNotes(id))
    }

    @Test func removingDropsTheDraftSoNothingComesBack() throws {
        let context = try inMemoryContext()
        let model = model(context)
        let item = article("Telescope")
        model.save(item)
        let id = try #require(model.entries.first?.id)
        model.editNotes("Draft", for: id)
        #expect(model.remove(id))
        #expect(model.drafts.isEmpty)
        #expect(model.flushNotes())
        #expect(try context.fetch(FetchDescriptor<SavedItem>()).isEmpty)
        // Saving again starts with no notes.
        model.save(item)
        #expect(model.entries.first?.notes == "")
    }

    @Test func aFailedRemoveKeepsTheArticle() throws {
        let context = try inMemoryContext()
        let model = model(context)
        model.save(article("Telescope"))
        let id = try #require(model.entries.first?.id)
        writes.fail = true
        #expect(model.requestRemoval(id) == .failed)
        #expect(model.problem == .notRemoved)
        #expect(model.entries.count == 1)
        #expect(try context.fetch(FetchDescriptor<SavedItem>()).count == 1)
    }

    // MARK: The save control

    @Test func theSaveControlTogglesAndAsksBeforeDroppingNotes() throws {
        let model = model(try inMemoryContext())
        let item = article("Telescope")
        #expect(model.toggleSave(item) == .saved)
        #expect(model.isSaved(item.link))
        #expect(model.toggleSave(item) == .removed)
        #expect(!model.isSaved(item.link))

        model.toggleSave(item)
        let id = try #require(model.entry(link: item.link)?.id)
        model.editNotes("Mine", for: id)
        #expect(model.toggleSave(item) == .needsConfirmation)
        #expect(model.isSaved(item.link))
        let confirmation = try #require(RemovalConfirmation(link: item.link, in: model))
        #expect(confirmation.id == id)
        #expect(confirmation.title == "Telescope")
        #expect(model.unsave(link: item.link))
        #expect(!model.isSaved(item.link))
    }

    // MARK: Search and filter

    @Test func searchAndCategoryUseTheSavedCopy() throws {
        let model = model(try inMemoryContext())
        model.save(article("El Niño explained", source: "Weather Desk", category: "Sci"))
        model.save(article("The quiet return of the paper map", source: "Example Wire", category: "news"))
        model.save(article("Maps of the lake floor", source: "Lakes Review", category: "Local"))

        #expect(model.categories == ["Local", "news", "Sci"])
        #expect(model.visible(ArticleQuery()).count == 3)
        #expect(model.visible(ArticleQuery(text: "nino")).map(\.item.title) == ["El Niño explained"])
        #expect(model.visible(ArticleQuery(text: "MAP")).count == 2)
        #expect(model.visible(ArticleQuery(text: "map", category: "News")).map(\.item.title)
            == ["The quiet return of the paper map"])
        #expect(model.visible(ArticleQuery(text: "wire")).count == 1)
        #expect(model.visible(ArticleQuery(category: "Elsewhere")).isEmpty)
    }
}

#if DEBUG
@Suite @MainActor struct SavedSampleTests {
    @Test func theSamplesShareOneStoreInMemory() throws {
        let context = try inMemoryContext()
        let feed = try FeedModel.sample(now: savedNow, context: context)
        let saved = try SavedModel.sample(context: context, now: savedNow)
        #expect(saved.entries.count == 3)
        #expect(saved.entries.contains { !$0.notes.isEmpty })
        // One saved sample is also in the feed sample; the others are not.
        #expect(saved.entries.filter { entry in feed.entries.contains { $0.link == entry.item.link } }.count == 1)
        #expect(HistoryList.visible(feed.entries, now: savedNow, query: ArticleQuery()).count == 8)
    }
}
#endif
