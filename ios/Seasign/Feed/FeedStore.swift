import Foundation
import SwiftData

/// Reads and writes the followed sites (user store) and the cached feed items
/// and feed state (cache store) in SwiftData.
@MainActor
struct FeedStore {
    let context: ModelContext

    // MARK: Sites

    /// The sites in the order they were added.
    func sites() -> [Site] {
        let all = (try? context.fetch(FetchDescriptor<Site>())) ?? []
        return all.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }

    /// Saves a new site. Returns false, with nothing stored, if it could not be written.
    func insert(_ site: Site) -> Bool {
        context.insert(site)
        return save()
    }

    /// Deletes a site. Returns false, with the site still stored, if that could not be written.
    func delete(_ site: Site) -> Bool {
        context.delete(site)
        return save()
    }

    // MARK: Items

    private func itemRows() -> [FeedItem] {
        (try? context.fetch(FetchDescriptor<FeedItem>())) ?? []
    }

    /// Every cached item, newest first.
    func items() -> [FeedEntry] {
        itemRows().map(\.entry).sorted(by: FeedEntry.newestFirst)
    }

    /// The cached item with this link, if there is one. Task 9's history and
    /// Saved find items again this way.
    func item(link: String) -> FeedEntry? {
        var descriptor = FetchDescriptor<FeedItem>(predicate: #Predicate { $0.link == link })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.entry
    }

    /// Merges `entries` into the cache by link: a new link is inserted, a
    /// known one takes the new title, date, excerpt and so on but keeps its
    /// `firstFetchedAt`. Nothing that is missing from `entries` is removed.
    func upsert(_ entries: [FeedEntry]) {
        guard !entries.isEmpty else { return }
        var byLink: [String: FeedItem] = [:]
        for row in itemRows() {
            if byLink[row.link] == nil {
                byLink[row.link] = row
            } else {
                // Never expected; keep one row per link if it ever happens.
                context.delete(row)
            }
        }
        for entry in entries {
            if let row = byLink[entry.link] {
                row.update(from: entry)
            } else {
                let row = FeedItem(entry)
                context.insert(row)
                byLink[entry.link] = row
            }
        }
        _ = save()
    }

    /// Deletes items dated more than 7 days before `now`, and items of sites
    /// that are no longer followed.
    func prune(now: Date, keepingSites sites: Set<UUID>) {
        var changed = false
        for row in itemRows() where row.published < now.addingTimeInterval(-FeedEntry.lifetime) || !sites.contains(row.siteID) {
            context.delete(row)
            changed = true
        }
        if changed { _ = save() }
    }

    // MARK: State

    func state() -> FeedState? {
        guard let row = try? context.fetch(FetchDescriptor<CachedFeedState>()).first else { return nil }
        return try? JSONDecoder().decode(FeedState.self, from: row.payload)
    }

    /// Replaces the stored state, or empties it when nil.
    func setState(_ state: FeedState?) {
        for row in (try? context.fetch(FetchDescriptor<CachedFeedState>())) ?? [] {
            context.delete(row)
        }
        if let state, let payload = try? JSONEncoder().encode(state) {
            context.insert(CachedFeedState(payload: payload, fetchedAt: state.refreshedAt ?? .distantPast))
        }
        _ = save()
    }

    private func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            // Keep memory and the store in step: drop what could not be written.
            context.rollback()
            return false
        }
    }
}
