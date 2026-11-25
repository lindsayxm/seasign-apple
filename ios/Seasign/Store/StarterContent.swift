import Foundation
import SwiftData

/// What a fresh install starts with (task 218, plan
/// `plans/2026-11-24-account-and-subscription.md` phase A, items 4 and 5):
/// three followed sites and one item on each list, so a new person sees
/// headlines and what the lists are for. For everyone, Free included: the
/// sites are plain followed sites (list refresh through `POST /v1/feed`, no
/// AI and nothing that costs money), and nothing here touches AI search or
/// the subscription.
///
/// Written once, when the user store is first created on disk
/// (`LocalStore.Opened.userStoreIsNew`: the file did not exist before this
/// launch opened it), like the default zip. Never again: a store that
/// already exists, even one with no sites and empty lists, is an install
/// from before this build or one where the person removed them, and is left
/// as it is. Stores in memory (tests, the DEBUG samples) are never seeded.
/// If the app stops between creating the file and saving the seeds, that
/// install simply starts empty: the safe side.
@MainActor
enum StarterContent {
    /// A site as `POST /v1/sites/resolve` gives it for the page address
    /// (address, mode, feed), with the user's own name for it as the title
    /// (resolve's page titles read badly and are cut off in Settings) and
    /// the category the person would type.
    struct StarterSite: Sendable, Equatable {
        /// The page address in resolve's normal form.
        var url: String
        /// The user's name for the site (the plan's wording).
        var title: String
        var category: String
        /// Feed mode always; the feed the API reads.
        var feedUrl: String
    }

    /// Checked through local `wrangler dev` on 2026-11-24: resolve gives
    /// Hacker News and Ars Technica Space feed mode with these feeds; Wired's
    /// science page has no feed of its own (links mode, no dates), so it is
    /// followed in feed mode with Wired's science feed, which answers with
    /// dated items (the plan's decision). `/v1/feed` returned 30, 16 and 13
    /// items for the three.
    static let sites: [StarterSite] = [
        StarterSite(
            url: "https://news.ycombinator.com/",
            title: "Hacker News",
            category: "Tech",
            feedUrl: "https://news.ycombinator.com/rss"
        ),
        StarterSite(
            url: "https://www.wired.com/category/science/",
            title: "Wired Science",
            category: "Science",
            feedUrl: "https://www.wired.com/feed/category/science/latest/rss"
        ),
        StarterSite(
            url: "https://arstechnica.com/space/",
            title: "Ars Technica Space",
            category: "Space",
            feedUrl: "https://arstechnica.com/space/feed/"
        ),
    ]

    /// The user's examples: one thing to do, one to get.
    static let listItems: [(kind: ListKind, title: String)] = [
        (.todo, "Go outside"),
        (.get, "Concert tickets"),
    ]

    /// Opens the stores (`LocalStore.open`) and, only when the user store was
    /// created by this open, writes the starter content into it. The app's
    /// one way of opening its stores.
    static func open(_ files: LocalStore.Files = .standard, now: Date = Date()) throws(LocalStore.UserStoreUnreadable) -> LocalStore.Opened {
        let opened = try LocalStore.open(files)
        if opened.userStoreIsNew {
            seed(ModelContext(opened.container), now: now)
        }
        return opened
    }

    /// Inserts the sites and items with one save; on failure nothing is kept.
    /// Each row is a millisecond apart so the sites and items keep this
    /// order (both are sorted by when they were added).
    static func seed(_ context: ModelContext, now: Date) {
        var stamp = now
        func next() -> Date {
            defer { stamp = stamp.addingTimeInterval(0.001) }
            return stamp
        }
        for site in sites {
            context.insert(Site(
                url: site.url,
                title: site.title,
                category: site.category,
                mode: .feed,
                feedUrl: site.feedUrl,
                createdAt: next()
            ))
        }
        for item in listItems {
            context.insert(ListItem(kind: item.kind, title: item.title, createdAt: next()))
        }
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }
}
