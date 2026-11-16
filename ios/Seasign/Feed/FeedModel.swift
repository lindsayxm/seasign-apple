import Foundation
import Observation
import SwiftData

/// The followed sites and their recent items: shows the cached items at once,
/// then refreshes them from `POST /v1/feed`.
///
/// Sites live in the user store; items and the per-site status in the cache
/// store. Everything that came from a site is cleaned (`SiteText.clean`) on
/// the way in and is plain text from then on.
@MainActor
@Observable
final class FeedModel {
    /// Why a site typed in Settings was not added. Messages are fixed text.
    enum AddProblem: Error, Equatable {
        case missingAddress
        case missingCategory
        /// Not a web address the app can send (another scheme, spaces, no host).
        case invalidAddress
        /// The address, with its feed's, is longer than `SiteAddress.maxBytes`.
        case tooLong
        case alreadyFollowed
        case limitReached
        /// The API could not read the page.
        case site(SiteProblem)
        /// The page was read but shows no article links, so following it would give nothing.
        case noArticles
        /// The API could not be asked.
        case unavailable
        /// The site was fine but could not be written to the phone.
        case notSaved

        var message: String {
            switch self {
            case .missingAddress:
                "Enter the address of a page to follow."
            case .missingCategory:
                "Give this site a category, such as Sci or News."
            case .invalidAddress:
                SiteProblem.invalidURL.message
            case .tooLong:
                "That address is too long to follow."
            case .alreadyFollowed:
                "You already follow that site."
            case .limitReached:
                "You can follow up to \(FeedModel.maxSites) sites. Remove one to add another."
            case .site(let problem):
                problem.message
            case .noArticles:
                "We found no articles on that page, so it wasn't added. Try the page that lists a section's stories, or the site's feed."
            case .unavailable:
                "We couldn't check that site. Check your connection and try again."
            case .notSaved:
                "That site couldn't be saved on this phone. Try again."
            }
        }
    }

    /// The API takes at most this many sites in one request.
    nonisolated static let maxSites = 50
    /// Longest stored site title.
    nonisolated static let siteTitleLimit = 120

    /// A full refresh younger than this is not repeated, unless a site has
    /// never been read. The API caches each site for 30 minutes.
    static let refreshInterval: TimeInterval = 15 * 60

    /// The followed sites, oldest first.
    private(set) var sites: [Site] = []
    /// Every cached item of the last 7 days, newest first.
    private(set) var entries: [FeedEntry] = []
    /// How each site went the last time it was read.
    private(set) var state = FeedState()
    /// True while a refresh is in flight.
    private(set) var isRefreshing = false

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let store: FeedStore
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Set for the DEBUG sample: nothing is fetched.
    @ObservationIgnored private var isFrozen = false

    init(
        api: SeasignAPI = SeasignAPI(),
        context: ModelContext,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.store = FeedStore(context: context)
        self.now = now
        sites = store.sites()
        let followed = Set(sites.map(\.id))
        store.prune(now: now(), keepingSites: followed)
        entries = store.items()
        if sites.isEmpty {
            if store.state() != nil { store.setState(nil) }
        } else {
            state = store.state()?.keeping(sites: followed) ?? FeedState()
        }
    }

    var canAddSite: Bool {
        sites.count < Self.maxSites
    }

    /// The categories in use, for reuse when adding a site.
    var categories: [String] {
        CategoryName.distinct(sites.map(\.category))
    }

    /// How the last read of `site` went; nil if it has not been read yet.
    func status(for site: Site) -> FeedState.Entry? {
        state.status(for: site.id)
    }

    /// How many cached items of the last 7 days came from `site`.
    func itemCount(for site: Site) -> Int {
        entries.reduce(0) { $0 + ($1.siteID == site.id ? 1 : 0) }
    }

    /// Today's candidates: items dated since the start of yesterday in
    /// `timeZone`, newest first. Today shows as many of these as fit.
    func headlines(now: Date, timeZone: TimeZone) -> [FeedEntry] {
        HeadlinePicker.sinceYesterday(entries, now: now, timeZone: timeZone)
    }

    /// Asks for every site's items, unless the last full refresh is younger
    /// than `refreshInterval` and every site has been read. If the request
    /// fails as a whole, the cached items stay; a site that fails keeps its
    /// items and shows its problem in Settings.
    func refresh(force: Bool = false) async {
        guard !isFrozen, !isRefreshing else { return }
        let current = now()
        store.prune(now: current, keepingSites: Set(sites.map(\.id)))
        reloadEntries()
        guard !sites.isEmpty else { return }
        let everySiteRead = Set(sites.map(\.id)).isSubset(of: Set(state.statuses.map(\.site)))
        if !force, everySiteRead, let last = state.refreshedAt,
           current >= last, current.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        await fetch(sites, isFullRefresh: true)
    }

    /// Checks a page typed in Settings with `POST /v1/sites/resolve` and
    /// follows it, then fetches its items. Throws an `AddProblem`, storing nothing.
    func add(address: String, category: String) async throws {
        let category = CategoryName.clean(category, existing: categories)
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AddProblem.missingAddress
        }
        guard !category.isEmpty else { throw AddProblem.missingCategory }
        guard let typed = SiteAddress.normalize(address) else { throw AddProblem.invalidAddress }
        guard SiteAddress.fits(url: typed, feedUrl: nil) else { throw AddProblem.tooLong }
        try checkRoom(url: typed, feedUrl: nil)

        let result: SiteResolveResult
        do {
            result = try await api.resolveSite(url: typed)
        } catch {
            throw AddProblem.unavailable
        }
        let resolved: SiteResolveResult.Resolved
        switch result {
        case .failed(let problem):
            throw AddProblem.site(problem)
        case .resolved(let value):
            resolved = value
        }
        if resolved.mode == .links, (resolved.linkCount ?? 0) == 0 {
            throw AddProblem.noArticles
        }
        guard ArticleLink.url(resolved.url) != nil,
              resolved.feedUrl.map({ ArticleLink.url($0) != nil }) ?? true
        else { throw AddProblem.site(.invalidURL) }
        guard SiteAddress.fits(url: resolved.url, feedUrl: resolved.feedUrl) else { throw AddProblem.tooLong }
        // The list may have changed while the request was in flight, and the
        // normal form may match a site already followed.
        try checkRoom(url: resolved.url, feedUrl: resolved.feedUrl)

        var title = SiteText.clean(resolved.title, limit: Self.siteTitleLimit)
        if title.isEmpty { title = LinkMask.host(of: resolved.url) ?? "Untitled site" }
        let site = Site(
            url: resolved.url,
            title: title,
            category: CategoryName.clean(category, existing: categories),
            mode: resolved.mode,
            feedUrl: resolved.feedUrl,
            createdAt: now()
        )
        guard store.insert(site) else { throw AddProblem.notSaved }
        sites = store.sites()
        // The new site's items, without asking for every other site again.
        await fetch([site], isFullRefresh: false)
    }

    /// Stops following a site; its items leave Today and the cache at once.
    func remove(_ site: Site) {
        guard store.delete(site) else { return }
        sites = store.sites()
        let followed = Set(sites.map(\.id))
        store.prune(now: now(), keepingSites: followed)
        setState(sites.isEmpty ? nil : state.keeping(sites: followed))
        reloadEntries()
    }

    // MARK: Fetching

    private func fetch(_ subset: [Site], isFullRefresh: Bool) async {
        let ids = subset.map(\.id)
        let request = subset.map { FeedAnswer.Request(url: $0.url, mode: $0.mode, feedUrl: $0.feedUrl) }
        guard !request.isEmpty, let answer = try? await api.feed(sites: request) else { return }
        apply(answer, ids: ids, isFullRefresh: isFullRefresh)
    }

    /// Merges an answer into the cache. `ids` are the sites in the order they
    /// were sent; a site removed while the request was in flight is skipped.
    private func apply(_ answer: FeedAnswer, ids: [UUID], isFullRefresh: Bool) {
        let current = now()
        let followed = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var incoming: [FeedEntry] = []
        for item in answer.items {
            guard ids.indices.contains(item.site), let site = followed[ids[item.site]],
                  let entry = Self.entry(from: item, site: site, now: current)
            else { continue }
            incoming.append(entry)
        }
        store.upsert(incoming)

        var statuses: [FeedState.Entry] = []
        for (index, id) in ids.enumerated() where followed[id] != nil {
            let problem: SiteProblem?
            if let status = answer.sites.first(where: { $0.index == index }) {
                problem = status.ok ? nil : (status.error ?? .fetchFailed)
            } else {
                // The API answers for every site; one without an answer was not read.
                problem = .fetchFailed
            }
            statuses.append(.init(site: id, problem: problem, checkedAt: current))
        }
        var next = state.merging(statuses).keeping(sites: Set(followed.keys))
        if isFullRefresh {
            next.refreshedAt = current
        }
        setState(next)
        store.prune(now: current, keepingSites: Set(followed.keys))
        reloadEntries()
    }

    /// One answer item as the app keeps it, or nil when it should not be kept:
    /// a link that is not https, an empty title, or a date over 7 days ago.
    static func entry(from item: FeedAnswer.Item, site: Site, now: Date) -> FeedEntry? {
        guard ArticleLink.url(item.link) != nil else { return nil }
        let title = SiteText.clean(item.title, limit: SiteText.titleLimit)
        guard !title.isEmpty else { return nil }
        var source = SiteText.clean(item.source, limit: SiteText.sourceLimit)
        if source.isEmpty { source = site.title }
        let excerpt = item.excerpt.map { SiteText.clean($0, limit: SiteText.excerptLimit) }
        let entry = FeedEntry(
            link: item.link,
            title: title,
            source: source,
            published: item.published,
            dateSource: item.dateSource,
            excerpt: excerpt?.isEmpty == false ? excerpt : nil,
            siteID: site.id,
            category: site.category,
            firstFetchedAt: now
        )
        return entry.isExpired(at: now) ? nil : entry
    }

    private func checkRoom(url: String, feedUrl: String?) throws {
        guard sites.count < Self.maxSites else { throw AddProblem.limitReached }
        let taken = sites.contains { site in
            site.url.caseInsensitiveCompare(url) == .orderedSame
                || (feedUrl != nil && site.feedUrl?.caseInsensitiveCompare(feedUrl ?? "") == .orderedSame)
        }
        guard !taken else { throw AddProblem.alreadyFollowed }
    }

    private func reloadEntries() {
        let fresh = store.items()
        if fresh != entries { entries = fresh }
    }

    private func setState(_ value: FeedState?) {
        state = value ?? FeedState()
        store.setState(value)
    }
}

#if DEBUG
extension FeedModel {
    /// Debug-only (`-debugFeed YES`): three sample sites and their items for
    /// screenshots, held in a store that lives in memory (`context`, or a new
    /// one). Five items are from the last half day, for Today; three more are
    /// two to six days old, for the 7-day history. Nothing is fetched and the
    /// user's own store is not touched.
    static func sample(now: Date = Date(), context: ModelContext? = nil) throws -> FeedModel {
        let context = try context ?? ModelContext(SeasignSchema.inMemoryContainer())
        let science = Site(
            url: "https://news.example.com/science/", title: "Science | Example News", category: "Sci",
            mode: .feed, feedUrl: "https://news.example.com/science/feed/", createdAt: now
        )
        let lakes = Site(
            url: "https://lakes.example.org/", title: "The Lakes Review", category: "Local",
            mode: .links, feedUrl: nil, createdAt: now.addingTimeInterval(1)
        )
        let wire = Site(
            url: "https://wire.example.net/world", title: "Example Wire: World", category: "News",
            mode: .links, feedUrl: nil, createdAt: now.addingTimeInterval(2)
        )
        for site in [science, lakes, wire] { context.insert(site) }

        let titles = PlaceholderHeadlines.all
        let excerpts: [String?] = [
            "Forecasters explain how warm water in the Pacific changes winters far away, in three minutes.",
            "Botanists say even the hardiest plants are struggling through the longest dry spell on record.",
            nil,
            nil,
            "Phones know where we are, but a folded map still teaches us where everything else is.",
        ]
        let siteFor = [science, science, lakes, lakes, wire]
        for (index, title) in titles.enumerated() {
            let site = siteFor[index]
            let published = now.addingTimeInterval(-Double(index + 1) * 2.5 * 3600)
            context.insert(FeedItem(FeedEntry(
                link: "https://\(URL(string: site.url)?.host() ?? "example.com")/sample/\(index)",
                title: title,
                source: site.title.components(separatedBy: " | ").last ?? site.title,
                published: published,
                dateSource: site.mode == .links ? .firstSeen : .published,
                excerpt: excerpts[index],
                siteID: site.id,
                category: site.category,
                firstFetchedAt: published
            )))
        }
        let older: [(title: String, site: Site, days: Double)] = [
            ("Lake-effect snow arrives early along the eastern shore", lakes, 2),
            ("Why the night sky looks brighter than it did a decade ago", science, 4),
            ("Ferries add a winter crossing for the first time in years", wire, 6),
        ]
        for (index, entry) in older.enumerated() {
            let published = now.addingTimeInterval(-entry.days * 86_400)
            context.insert(FeedItem(FeedEntry(
                link: "https://\(URL(string: entry.site.url)?.host() ?? "example.com")/sample/older-\(index)",
                title: entry.title,
                source: entry.site.title.components(separatedBy: " | ").last ?? entry.site.title,
                published: published,
                dateSource: .published,
                excerpt: nil,
                siteID: entry.site.id,
                category: entry.site.category,
                firstFetchedAt: published
            )))
        }
        try context.save()

        let model = FeedModel(context: context, now: { now })
        model.isFrozen = true
        model.setState(FeedState(
            statuses: [
                .init(site: science.id, problem: nil, checkedAt: now),
                .init(site: lakes.id, problem: nil, checkedAt: now),
                .init(site: wire.id, problem: .timeout, checkedAt: now),
            ],
            refreshedAt: now
        ))
        return model
    }
}
#endif
