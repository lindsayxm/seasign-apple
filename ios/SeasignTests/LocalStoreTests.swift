import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Seasign

/// Task 17, item 5: what happens when a store on disk will not open. Each test
/// works on real SQLite files in its own temporary directory.
@Suite(.serialized) @MainActor struct LocalStoreTests {
    private let directory: URL
    private let files: LocalStore.Files

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "LocalStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = LocalStore.Files(
            user: directory.appending(path: "default.store"),
            cache: directory.appending(path: "SkyCache.store")
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes one list item, a zip and a cached sky, then closes the stores.
    private func seed() throws {
        let opened = try LocalStore.open(files)
        #expect(opened.cache == .kept)
        let context = ModelContext(opened.container)
        context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
        context.insert(Settings(zip: "10001"))
        context.insert(CachedSky(zip: "10001", payload: Data("{}".utf8), fetchedAt: instant("2026-11-15T12:00:00Z")))
        try context.save()
    }

    private func titles(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<ListItem>()).map(\.title)
    }

    private func overwriteWithJunk(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        try Data(repeating: 0x5A, count: 8192).write(to: url)
    }

    @Test func opensAndKeepsDataAcrossLaunches() throws {
        defer { cleanUp() }
        try seed()
        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        let context = ModelContext(again.container)
        #expect(try titles(again.container) == ["Oat milk"])
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
    }

    /// Task 6 added `CalendarLink` to the user store and `CachedEvents` to the
    /// cache store. Stores written by the build before that must open as they
    /// are, with nothing lost and neither file thrown away.
    @Test func storesFromBeforeCalendarLinksOpenAndKeepEverything() throws {
        defer { cleanUp() }
        do {
            let user: [any PersistentModel.Type] = [Settings.self, ListItem.self]
            let cache: [any PersistentModel.Type] = [CachedSky.self]
            let old = try ModelContainer(
                for: Schema(user + cache),
                configurations: [
                    ModelConfiguration("user", schema: Schema(user), url: files.user),
                    ModelConfiguration("cache", schema: Schema(cache), url: files.cache),
                ]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
            context.insert(Settings(zip: "10001"))
            context.insert(CachedSky(zip: "10001", payload: Data("{}".utf8), fetchedAt: instant("2026-11-15T12:00:00Z")))
            try context.save()
        }

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept)
            let context = ModelContext(opened.container)
            #expect(try titles(opened.container) == ["Oat milk"])
            #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CalendarLink>()).isEmpty)
            context.insert(CalendarLink(name: "Family", url: "https://cal.example.com/a.ics", createdAt: .now))
            context.insert(CachedEvents(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        // The next launch finds the link, and it is in the user store's file.
        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        #expect(try ModelContext(again.container).fetch(FetchDescriptor<CalendarLink>()).map(\.name) == ["Family"])
        #expect(try titles(again.container) == ["Oat milk"])
    }

    /// Task 8 added `Site` to the user store and `FeedItem` and
    /// `CachedFeedState` to the cache store. Stores written with the schema
    /// of the build before that (listed here by hand, not from
    /// `SeasignSchema`) must open with nothing lost and neither file thrown away.
    @Test func storesFromBeforeSitesOpenAndKeepEverything() throws {
        defer { cleanUp() }
        do {
            let user: [any PersistentModel.Type] = [Settings.self, ListItem.self, CalendarLink.self]
            let cache: [any PersistentModel.Type] = [CachedSky.self, CachedEvents.self]
            let old = try ModelContainer(
                for: Schema(user + cache),
                configurations: [
                    ModelConfiguration("user", schema: Schema(user), url: files.user),
                    ModelConfiguration("cache", schema: Schema(cache), url: files.cache),
                ]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
            context.insert(Settings(zip: "10001"))
            context.insert(CalendarLink(name: "Family", url: "https://cal.example.com/a.ics", createdAt: .now))
            context.insert(CachedSky(zip: "10001", payload: Data("{}".utf8), fetchedAt: instant("2026-11-15T12:00:00Z")))
            context.insert(CachedEvents(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept)
            let context = ModelContext(opened.container)
            #expect(try titles(opened.container) == ["Oat milk"])
            #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CalendarLink>()).map(\.name) == ["Family"])
            #expect(try context.fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CachedEvents>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<Site>()).isEmpty)
            context.insert(sampleSite())
            context.insert(sampleItem())
            context.insert(CachedFeedState(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        // The next launch finds everything, and each model is in its own file.
        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        let context = ModelContext(again.container)
        #expect(try context.fetch(FetchDescriptor<Site>()).map(\.category) == ["Sci"])
        #expect(try context.fetch(FetchDescriptor<FeedItem>()).count == 1)
        #expect(try titles(again.container) == ["Oat milk"])

        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<Site>()).count == 1)
        let cacheOnly = try ModelContainer(
            for: Schema(SeasignSchema.cacheModels),
            configurations: [ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache)]
        )
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<FeedItem>()).count == 1)
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<CachedFeedState>()).count == 1)
    }

    /// Task 9 added `SavedItem` to the user store. Stores written with the
    /// schema of the build before that (listed here by hand, not from
    /// `SeasignSchema`) must open with nothing lost and neither file thrown
    /// away, and a saved article must land in the user store's file.
    @Test func storesFromBeforeSavedItemsOpenAndKeepEverything() throws {
        defer { cleanUp() }
        do {
            let user: [any PersistentModel.Type] = [Settings.self, ListItem.self, CalendarLink.self, Site.self]
            let cache: [any PersistentModel.Type] = [CachedSky.self, CachedEvents.self, FeedItem.self, CachedFeedState.self]
            let old = try ModelContainer(
                for: Schema(user + cache),
                configurations: [
                    ModelConfiguration("user", schema: Schema(user), url: files.user),
                    ModelConfiguration("cache", schema: Schema(cache), url: files.cache),
                ]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
            context.insert(Settings(zip: "10001"))
            context.insert(CalendarLink(name: "Family", url: "https://cal.example.com/a.ics", createdAt: .now))
            context.insert(sampleSite())
            context.insert(CachedSky(zip: "10001", payload: Data("{}".utf8), fetchedAt: instant("2026-11-15T12:00:00Z")))
            context.insert(CachedEvents(payload: Data("{}".utf8), fetchedAt: .now))
            context.insert(sampleItem())
            context.insert(CachedFeedState(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept)
            let context = ModelContext(opened.container)
            #expect(try titles(opened.container) == ["Oat milk"])
            #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CalendarLink>()).map(\.name) == ["Family"])
            #expect(try context.fetch(FetchDescriptor<Site>()).map(\.category) == ["Sci"])
            #expect(try context.fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CachedEvents>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<FeedItem>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<CachedFeedState>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<SavedItem>()).isEmpty)
            context.insert(sampleSaved())
            try context.save()
        }

        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        #expect(try ModelContext(again.container).fetch(FetchDescriptor<SavedItem>()).map(\.notes) == ["Mine"])
        #expect(try titles(again.container) == ["Oat milk"])

        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<SavedItem>()).map(\.notes) == ["Mine"])
        let cacheOnly = try ModelContainer(
            for: Schema(SeasignSchema.cacheModels),
            configurations: [ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache)]
        )
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<FeedItem>()).count == 1)
    }

    /// Task 12 added optional fields to `Settings`, `SavedItem` and
    /// `FeedItem`, and the `SearchCount` model. Stores written with the
    /// schema before that (the three changed models declared again, as they
    /// were, in `Task11Schema`) must open with nothing lost and neither file
    /// thrown away; old rows read as "from a followed site" and "Use My List".
    @Test func storesFromBeforeAISearchOpenAndKeepEverything() throws {
        defer { cleanUp() }
        let siteID = UUID()
        do {
            let user: [any PersistentModel.Type] = [
                Task11Schema.Settings.self, ListItem.self, CalendarLink.self, Site.self, Task11Schema.SavedItem.self,
            ]
            let cache: [any PersistentModel.Type] = [
                CachedSky.self, CachedEvents.self, Task11Schema.FeedItem.self, CachedFeedState.self,
            ]
            let old = try ModelContainer(
                for: Schema(user + cache),
                configurations: [
                    ModelConfiguration("user", schema: Schema(user), url: files.user),
                    ModelConfiguration("cache", schema: Schema(cache), url: files.cache),
                ]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
            context.insert(Task11Schema.Settings(zip: "10001"))
            context.insert(CalendarLink(name: "Family", url: "https://cal.example.com/a.ics", createdAt: .now))
            context.insert(sampleSite())
            context.insert(Task11Schema.SavedItem(link: "https://news.example.com/science/a", notes: "Mine"))
            context.insert(CachedSky(zip: "10001", payload: Data("{}".utf8), fetchedAt: instant("2026-11-15T12:00:00Z")))
            context.insert(Task11Schema.FeedItem(link: "https://news.example.com/science/a", siteID: siteID))
            context.insert(CachedFeedState(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept)
            let context = ModelContext(opened.container)
            #expect(try titles(opened.container) == ["Oat milk"])
            let settings = try #require(try context.fetch(FetchDescriptor<Settings>()).first)
            #expect(settings.zip == "10001")
            #expect(settings.aiModeRaw == nil)
            #expect(settings.aiInterestsText == nil)
            #expect(settings.aiDailyCap == nil)
            #expect(try context.fetch(FetchDescriptor<CalendarLink>()).map(\.name) == ["Family"])
            #expect(try context.fetch(FetchDescriptor<Site>()).map(\.category) == ["Sci"])
            let saved = try #require(try context.fetch(FetchDescriptor<SavedItem>()).first)
            #expect(saved.notes == "Mine")
            #expect(saved.readingItem.title == "A")
            #expect(saved.readingItem.origin == .site)
            #expect(saved.readingItem.category == "Sci")
            let item = try #require(try context.fetch(FetchDescriptor<FeedItem>()).first)
            #expect(item.entry.origin == .site)
            #expect(item.entry.siteID == siteID)
            #expect(item.entry.title == "A")
            #expect(try context.fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CachedFeedState>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<SearchCount>()).isEmpty)

            settings.aiModeRaw = AIMode.aiSearch.rawValue
            settings.aiInterestsText = "tide pools"
            context.insert(SearchCount(day: "2026-11-16", count: 2))
            context.insert(SavedItem(ReadingItem(
                link: "https://coast.example.org/a", title: "Pools", source: "Coast", published: .now,
                dateSource: .firstSeen, excerpt: nil, category: "tide pools",
                origin: .ai, interest: "tide pools", provider: .openai
            ), savedAt: .now))
            try context.save()
        }

        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        let context = ModelContext(again.container)
        #expect(try context.fetch(FetchDescriptor<SearchCount>()).map(\.count) == [2])
        #expect(try context.fetch(FetchDescriptor<Settings>()).first?.aiInterestsText == "tide pools")
        let ai = try #require(try context.fetch(FetchDescriptor<SavedItem>()).first { $0.link == "https://coast.example.org/a" })
        #expect(ai.readingItem.isAI)
        #expect(ai.readingItem.provider == .openai)
        #expect(try titles(again.container) == ["Oat milk"])

        // The count is in the user store's file.
        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<SearchCount>()).count == 1)
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<SavedItem>()).count == 2)
    }

    /// Task 154 added `GoogleAccount` and `GoogleCalendarChoice` to the user
    /// store and `CachedGoogleEvents` to the cache. Stores written with the
    /// schema before that (listed by hand) open with nothing lost, neither
    /// file thrown away, and the new models land in the right files.
    @Test func storesFromBeforeGoogleCalendarOpenAndKeepEverything() throws {
        defer { cleanUp() }
        do {
            let user: [any PersistentModel.Type] = [
                Settings.self, ListItem.self, CalendarLink.self, Site.self, SavedItem.self, SearchCount.self,
            ]
            let cache: [any PersistentModel.Type] = [CachedSky.self, CachedEvents.self, FeedItem.self, CachedFeedState.self]
            let old = try ModelContainer(
                for: Schema(user + cache),
                configurations: [
                    ModelConfiguration("user", schema: Schema(user), url: files.user),
                    ModelConfiguration("cache", schema: Schema(cache), url: files.cache),
                ]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
            context.insert(Settings(zip: "10001"))
            context.insert(CalendarLink(name: "Family", url: "https://cal.example.com/a.ics", createdAt: .now))
            context.insert(CachedEvents(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept)
            let context = ModelContext(opened.container)
            #expect(try titles(opened.container) == ["Oat milk"])
            #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CalendarLink>()).map(\.name) == ["Family"])
            #expect(try context.fetch(FetchDescriptor<CachedEvents>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<GoogleCalendarChoice>()).isEmpty)
            context.insert(GoogleAccount(stateRaw: "connected"))
            context.insert(GoogleCalendarChoice(calendarID: "primary", name: "Me", isPrimary: true, isOn: true, order: 0))
            context.insert(CachedGoogleEvents(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<GoogleCalendarChoice>()).map(\.name) == ["Me"])
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<GoogleAccount>()).map(\.stateRaw) == ["connected"])
        let cacheOnly = try ModelContainer(
            for: Schema(SeasignSchema.cacheModels),
            configurations: [ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache)]
        )
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<CachedGoogleEvents>()).count == 1)
    }

    /// Task 169 added optional fields to `GoogleAccount` (granted scopes, the
    /// calendar for new events) and `GoogleCalendarChoice` (access role).
    /// Stores written with the schema just before that (the two models
    /// declared again, as they were, in `Task168Schema`; every other model
    /// as it is) open with nothing lost and neither file thrown away; the
    /// connection reads as connected and polls, with no write access.
    @Test func storesFromBeforeGoogleWriteAccessOpenAndKeepEverything() throws {
        defer { cleanUp() }
        let choiceID = UUID()
        do {
            let user: [any PersistentModel.Type] = [
                Settings.self, ListItem.self, CalendarLink.self, Site.self, SavedItem.self, SearchCount.self,
                Task168Schema.GoogleAccount.self, Task168Schema.GoogleCalendarChoice.self,
            ]
            let old = try ModelContainer(
                for: Schema(user + SeasignSchema.cacheModels),
                configurations: [
                    ModelConfiguration("user", schema: Schema(user), url: files.user),
                    ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache),
                ]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
            context.insert(Settings(zip: "10001"))
            context.insert(Task168Schema.GoogleAccount(stateRaw: "connected"))
            context.insert(Task168Schema.GoogleCalendarChoice(
                id: choiceID, calendarID: "me@example.test", name: "Me", isPrimary: true, isOn: true, order: 0
            ))
            context.insert(CachedGoogleEvents(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept)
            let context = ModelContext(opened.container)
            #expect(try titles(opened.container) == ["Oat milk"])
            #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
            #expect(try context.fetch(FetchDescriptor<CachedGoogleEvents>()).count == 1)
            let account = try #require(try context.fetch(FetchDescriptor<GoogleAccount>()).first)
            #expect(account.stateRaw == "connected")
            #expect(account.grantedScopes == nil)
            #expect(account.newEventsCalendarID == nil)
            let choice = try #require(try context.fetch(FetchDescriptor<GoogleCalendarChoice>()).first)
            #expect(choice.id == choiceID)
            #expect(choice.isOn)
            #expect(choice.accessRoleRaw == nil)

            let model = GoogleCalendarModel(
                api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: GoogleAPIStub()),
                context: context,
                config: FakeGoogle.config,
                tokens: InMemoryGoogleTokenStore(GoogleSecret(FakeGoogle.refresh)),
                http: FakeGoogleEndpoint().http,
                timeZone: { .gmt }
            )
            #expect(model.connection == .connected)
            #expect(model.canPoll)
            #expect(model.chosen.map(\.id) == [choiceID])
            #expect(model.grantedScopes == nil)
            #expect(!model.canAddEvents)
            #expect(model.newEventsCalendar == nil)

            account.grantedScopes = GoogleOAuthConfig.joined(Set(GoogleOAuthConfig.scopes))
            account.newEventsCalendarID = "me@example.test"
            choice.accessRoleRaw = GoogleAccessRole.owner.rawValue
            try context.save()
        }

        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        let context = ModelContext(again.container)
        #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).first?.newEventsCalendarID == "me@example.test")
        #expect(try context.fetch(FetchDescriptor<GoogleCalendarChoice>()).first?.accessRole == .owner)
        #expect(try titles(again.container) == ["Oat milk"])
        // Still in the user store's file.
        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        let account = try #require(try ModelContext(userOnly).fetch(FetchDescriptor<GoogleAccount>()).first)
        #expect(GoogleOAuthConfig.split(account.grantedScopes) == Set(GoogleOAuthConfig.scopes))
    }

    /// Task 172 added the optional `Settings.voiceIdentifier`. Stores written
    /// with the schema just before it (`Settings` declared again, as it was,
    /// in `Task171Schema`; every other model as it is) open with nothing
    /// lost and neither file thrown away; the voice reads as the system
    /// default until one is chosen, and a chosen one is kept.
    @Test func storesFromBeforeTheVoiceSettingOpenAndKeepEverything() throws {
        defer { cleanUp() }
        do {
            let user: [any PersistentModel.Type] = [
                Task171Schema.Settings.self, ListItem.self, CalendarLink.self, Site.self, SavedItem.self, SearchCount.self,
                GoogleAccount.self, GoogleCalendarChoice.self,
            ]
            let old = try ModelContainer(
                for: Schema(user + SeasignSchema.cacheModels),
                configurations: [
                    ModelConfiguration("user", schema: Schema(user), url: files.user),
                    ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache),
                ]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .get, title: "Oat milk", createdAt: instant("2026-11-15T12:00:00Z")))
            let settings = Task171Schema.Settings(zip: "10001")
            settings.aiInterestsText = "tide pools"
            settings.aiDailyCap = 3
            context.insert(settings)
            context.insert(GoogleAccount(stateRaw: "connected"))
            context.insert(CachedSky(zip: "10001", payload: Data("{}".utf8), fetchedAt: instant("2026-11-15T12:00:00Z")))
            try context.save()
        }

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept)
            let context = ModelContext(opened.container)
            #expect(try titles(opened.container) == ["Oat milk"])
            let settings = try #require(try context.fetch(FetchDescriptor<Settings>()).first)
            #expect(settings.zip == "10001")
            #expect(settings.aiInterestsText == "tide pools")
            #expect(settings.aiDailyCap == 3)
            #expect(settings.voiceIdentifier == nil)
            #expect(try context.fetch(FetchDescriptor<GoogleAccount>()).map(\.stateRaw) == ["connected"])
            #expect(try context.fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
            settings.voiceIdentifier = "com.apple.voice.compact.en-US.Samantha"
            try context.save()
        }

        let again = try LocalStore.open(files)
        #expect(again.cache == .kept)
        let context = ModelContext(again.container)
        #expect(try context.fetch(FetchDescriptor<Settings>()).first?.voiceIdentifier == "com.apple.voice.compact.en-US.Samantha")
        #expect(try titles(again.container) == ["Oat milk"])
        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<Settings>()).first?.zip == "10001")
    }

    /// A saved article and its notes are the user's: they survive the loss
    /// of the cache, where its feed item was.
    @Test func savedItemsSurviveABrokenCache() throws {
        defer { cleanUp() }
        do {
            let opened = try LocalStore.open(files)
            let context = ModelContext(opened.container)
            context.insert(sampleItem())
            context.insert(sampleSaved())
            try context.save()
        }
        try overwriteWithJunk(files.cache)
        let opened = try LocalStore.open(files)
        #expect(opened.cache == .recreated)
        let context = ModelContext(opened.container)
        #expect(try context.fetch(FetchDescriptor<FeedItem>()).isEmpty)
        let saved = try #require(try context.fetch(FetchDescriptor<SavedItem>()).first)
        #expect(saved.notes == "Mine")
        #expect(saved.readingItem.link == "https://news.example.com/science/a")
        #expect(saved.readingItem.title == "A")
    }

    private func sampleSaved() -> SavedItem {
        SavedItem(ReadingItem(sampleItem().entry), notes: "Mine", savedAt: .now)
    }

    /// A followed site is something the user entered: it survives the loss of
    /// the cache, and the cached items go with the cache.
    @Test func sitesSurviveABrokenCache() throws {
        defer { cleanUp() }
        do {
            let opened = try LocalStore.open(files)
            let context = ModelContext(opened.container)
            context.insert(sampleSite())
            context.insert(sampleItem())
            try context.save()
        }
        try overwriteWithJunk(files.cache)
        let opened = try LocalStore.open(files)
        #expect(opened.cache == .recreated)
        let context = ModelContext(opened.container)
        #expect(try context.fetch(FetchDescriptor<Site>()).map(\.url) == ["https://news.example.com/science/"])
        #expect(try context.fetch(FetchDescriptor<FeedItem>()).isEmpty)
    }

    private func sampleSite() -> Site {
        Site(
            url: "https://news.example.com/science/", title: "Science | Example News", category: "Sci",
            mode: .feed, feedUrl: "https://news.example.com/science/feed/", createdAt: .now
        )
    }

    private func sampleItem() -> FeedItem {
        FeedItem(FeedEntry(
            link: "https://news.example.com/science/a", title: "A", source: "Example News",
            published: .now, dateSource: .published, excerpt: nil, siteID: UUID(),
            category: "Sci", firstFetchedAt: .now
        ))
    }

    /// A calendar link is something the user entered: it survives the loss of
    /// the cache, and the cached events go with the cache.
    @Test func calendarLinksSurviveABrokenCache() throws {
        defer { cleanUp() }
        do {
            let opened = try LocalStore.open(files)
            let context = ModelContext(opened.container)
            context.insert(CalendarLink(name: "Family", url: "https://cal.example.com/a.ics", createdAt: .now))
            context.insert(CachedEvents(payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }
        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<CalendarLink>()).count == 1)

        try overwriteWithJunk(files.cache)
        let opened = try LocalStore.open(files)
        #expect(opened.cache == .recreated)
        let context = ModelContext(opened.container)
        #expect(try context.fetch(FetchDescriptor<CalendarLink>()).map(\.name) == ["Family"])
        #expect(try context.fetch(FetchDescriptor<CachedEvents>()).isEmpty)
    }

    /// A new install: not even the folder exists yet.
    @Test func firstLaunchCreatesTheFolderAndBothStores() throws {
        defer { cleanUp() }
        let folder = directory.appending(path: "Library/Application Support")
        let fresh = LocalStore.Files(
            user: folder.appending(path: "default.store"),
            cache: folder.appending(path: "SkyCache.store")
        )
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        let opened = try LocalStore.open(fresh)
        #expect(opened.cache == .kept)
        let context = ModelContext(opened.container)
        context.insert(ListItem(kind: .todo, title: "First", createdAt: .now))
        context.insert(CachedSky(zip: "10001", payload: Data(), fetchedAt: .now))
        try context.save()
        #expect(FileManager.default.fileExists(atPath: fresh.user.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fresh.cache.path(percentEncoded: false)))
    }

    /// Opening again the moment the last container is let go is what a quick
    /// relaunch, "Try again" and the recovery path itself do. A store that is
    /// still closing must never be taken for a broken one: that would delete
    /// the cache or show the error screen for nothing.
    @Test func reopeningStraightAfterClosingAlwaysWorks() throws {
        defer { cleanUp() }
        try seed()
        for round in 1...30 {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .kept, "round \(round)")
            let context = ModelContext(opened.container)
            context.insert(ListItem(kind: .todo, title: "Item \(round)", createdAt: .now))
            context.insert(CachedSky(zip: "\(round)", payload: Data(), fetchedAt: .now))
            try context.save()
        }
        let last = try LocalStore.open(files)
        #expect(last.cache == .kept)
        #expect(try titles(last.container).count == 31)
        #expect(try ModelContext(last.container).fetch(FetchDescriptor<CachedSky>()).count == 31)
    }

    /// Each model is in the file it is meant to be in: opening one file alone
    /// finds its own rows, and the cache file can go without the lists going too.
    @Test func modelsLandInTheirOwnFiles() throws {
        defer { cleanUp() }
        try seed()
        let userOnly = try ModelContainer(
            for: Schema(SeasignSchema.userModels),
            configurations: [ModelConfiguration("user", schema: Schema(SeasignSchema.userModels), url: files.user)]
        )
        #expect(try titles(userOnly) == ["Oat milk"])
        #expect(try ModelContext(userOnly).fetch(FetchDescriptor<Settings>()).count == 1)

        let cacheOnly = try ModelContainer(
            for: Schema(SeasignSchema.cacheModels),
            configurations: [ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache)]
        )
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<CachedSky>()).count == 1)
    }

    @Test func aBrokenCacheIsReplacedAndTheListsSurvive() throws {
        defer { cleanUp() }
        try seed()
        try overwriteWithJunk(files.cache)

        let opened = try LocalStore.open(files)
        #expect(opened.cache == .recreated)
        #expect(try titles(opened.container) == ["Oat milk"])
        let context = ModelContext(opened.container)
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["10001"])
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).isEmpty)
        // The new cache works.
        context.insert(CachedSky(zip: "10001", payload: Data(), fetchedAt: .now))
        try context.save()
    }

    /// Every table, index and trigger of a store file with its SQL, the
    /// store's Core Data metadata row, and SQLite's schema counter, read with
    /// SQLite directly. The counter goes up on every schema change, so it also
    /// shows a table that was dropped and then created again.
    private func schemaDump(_ url: URL) throws -> [String] {
        var db: OpaquePointer?
        let opening = sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opening == SQLITE_OK else { throw SQLiteFailure(db, opening, "open") }
        // A container that has just been let go may still be closing its
        // connection, and SQLite's last close folds the write-ahead log in
        // under a lock. Core Data's own connections wait for such locks; a
        // plain connection does not unless told to, and fails at once with
        // SQLITE_BUSY (seen in half the runs on iOS 27.2, never on 18.3).
        sqlite3_busy_timeout(db, 10_000)
        var rows: [String] = []
        for query in [
            "SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master ORDER BY type, name",
            "SELECT 'schema_version ' || schema_version FROM pragma_schema_version",
            "SELECT 'metadata ' || Z_VERSION || ' ' || Z_UUID || ' ' || hex(Z_PLIST) FROM Z_METADATA",
        ] {
            var statement: OpaquePointer?
            let preparing = sqlite3_prepare_v2(db, query, -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            guard preparing == SQLITE_OK else { throw SQLiteFailure(db, preparing, "prepare \(query.prefix(30))") }
            var stepping = sqlite3_step(statement)
            while stepping == SQLITE_ROW {
                rows.append(String(cString: sqlite3_column_text(statement, 0)))
                stepping = sqlite3_step(statement)
            }
            guard stepping == SQLITE_DONE else { throw SQLiteFailure(db, stepping, "step \(query.prefix(30))") }
        }
        return rows
    }

    /// What SQLite said, so a failure of the helper is not mistaken for one of the store.
    private struct SQLiteFailure: Error, CustomStringConvertible {
        var description: String
        init(_ db: OpaquePointer?, _ code: Int32, _ stage: String) {
            description = "SQLite \(stage): code \(code), extended \(sqlite3_extended_errcode(db)), \(String(cString: sqlite3_errmsg(db)))"
        }
    }

    /// Review of task 17: recovering the cache must not migrate the user
    /// store. Opening it with a schema that lacks `CachedSky` would make Core
    /// Data treat the model as removed and rewrite the file's schema.
    @Test func cacheRecoveryDoesNotChangeTheUserStoreSchema() throws {
        defer { cleanUp() }
        try seed()
        let before = try schemaDump(files.user)
        #expect(before.contains { $0.contains("ZLISTITEM") })
        try overwriteWithJunk(files.cache)

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .recreated)
            #expect(try titles(opened.container) == ["Oat milk"])
        }
        #expect(try schemaDump(files.user) == before)
    }

    /// The same for a store written by a build from before the split, which
    /// still has the old cache table in `default.store`.
    @Test func cacheRecoveryLeavesAnEarlierSingleStoreAsItWas() throws {
        defer { cleanUp() }
        do {
            let schema = Schema(SeasignSchema.models)
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: files.user)])
            let context = ModelContext(old)
            context.insert(ListItem(kind: .todo, title: "Call the vet", createdAt: instant("2026-11-14T12:00:00Z")))
            try context.save()
        }
        // First launch of the split build, which may bring the file up to date.
        do { _ = try LocalStore.open(files) }
        let before = try schemaDump(files.user)
        try overwriteWithJunk(files.cache)

        do {
            let opened = try LocalStore.open(files)
            #expect(opened.cache == .recreated)
            #expect(try titles(opened.container) == ["Call the vet"])
        }
        #expect(try schemaDump(files.user) == before)
    }

    /// When no cache file can be made at all, the app still starts: the user
    /// store is healthy, so this is not the error screen's case.
    @Test func aCacheThatCannotBeCreatedLivesInMemory() throws {
        defer { cleanUp() }
        try seed()
        // A plain file where the cache's folder should be.
        let blocker = directory.appending(path: "blocker")
        try Data("x".utf8).write(to: blocker)
        let blocked = LocalStore.Files(user: files.user, cache: blocker.appending(path: "SkyCache.store"))

        let opened = try LocalStore.open(blocked)
        #expect(opened.cache == .inMemory)
        #expect(try titles(opened.container) == ["Oat milk"])
        let context = ModelContext(opened.container)
        context.insert(CachedSky(zip: "10001", payload: Data(), fetchedAt: .now))
        context.insert(ListItem(kind: .get, title: "Bread", createdAt: .now))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).count == 1)
        // The list item went to disk, not into the in-memory store.
        #expect(try titles(try LocalStore.open(files).container).sorted() == ["Bread", "Oat milk"])
    }

    @Test func aBrokenUserStoreIsReportedAndLeftAlone() throws {
        defer { cleanUp() }
        try seed()
        try overwriteWithJunk(files.user)
        let before = try Data(contentsOf: files.user)

        #expect(throws: LocalStore.UserStoreUnreadable.self) {
            _ = try LocalStore.open(files)
        }
        // Not deleted, not rewritten.
        #expect(try Data(contentsOf: files.user) == before)
        // The cache is not thrown away either. (Its bytes are not compared:
        // merely opening a healthy SQLite file may fold its write-ahead log in.)
        let cacheOnly = try ModelContainer(
            for: Schema(SeasignSchema.cacheModels),
            configurations: [ModelConfiguration("cache", schema: Schema(SeasignSchema.cacheModels), url: files.cache)]
        )
        #expect(try ModelContext(cacheOnly).fetch(FetchDescriptor<CachedSky>()).map(\.zip) == ["10001"])
    }

    /// Builds made before the split kept all three models in `default.store`.
    @Test func aSingleStoreFromAnEarlierBuildKeepsItsLists() throws {
        defer { cleanUp() }
        do {
            let schema = Schema(SeasignSchema.models)
            let old = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: files.user)]
            )
            let context = ModelContext(old)
            context.insert(ListItem(kind: .todo, title: "Call the vet", createdAt: instant("2026-11-14T12:00:00Z")))
            context.insert(Settings(zip: "94103"))
            context.insert(CachedSky(zip: "94103", payload: Data("{}".utf8), fetchedAt: .now))
            try context.save()
        }

        let opened = try LocalStore.open(files)
        #expect(opened.cache == .kept)
        #expect(try titles(opened.container) == ["Call the vet"])
        let context = ModelContext(opened.container)
        #expect(try context.fetch(FetchDescriptor<Settings>()).map(\.zip) == ["94103"])
        // The old cached sky is not carried over; the next refresh fetches one.
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).isEmpty)
    }
}

/// The three models task 12 changed, exactly as they were before it, for
/// `storesFromBeforeAISearchOpenAndKeepEverything`. Same class names, so
/// SwiftData gives them the same entity names as the current models.
enum Task11Schema {
    @Model
    final class Settings {
        var zip: String?

        init(zip: String? = nil) {
            self.zip = zip
        }
    }

    @Model
    final class FeedItem {
        var id: UUID
        var link: String
        var title: String
        var source: String
        var published: Date
        var dateSourceRaw: String
        var excerpt: String?
        var siteID: UUID
        var category: String
        var firstFetchedAt: Date

        init(link: String, siteID: UUID) {
            id = UUID()
            self.link = link
            title = "A"
            source = "Example News"
            published = .now
            dateSourceRaw = "published"
            excerpt = nil
            self.siteID = siteID
            category = "Sci"
            firstFetchedAt = .now
        }
    }

    @Model
    final class SavedItem {
        var id: UUID
        var link: String
        var title: String
        var source: String
        var published: Date
        var dateSourceRaw: String
        var excerpt: String?
        var category: String
        var notes: String
        var savedAt: Date
        var updatedAt: Date

        init(link: String, notes: String) {
            id = UUID()
            self.link = link
            title = "A"
            source = "Example News"
            published = .now
            dateSourceRaw = "published"
            excerpt = nil
            category = "Sci"
            self.notes = notes
            savedAt = .now
            updatedAt = .now
        }
    }
}

/// The two models task 169 changed, exactly as they were before it, for
/// `storesFromBeforeGoogleWriteAccessOpenAndKeepEverything`. Same class
/// names, so SwiftData gives them the same entity names as the current models.
enum Task168Schema {
    @Model
    final class GoogleAccount {
        var stateRaw: String

        init(stateRaw: String) {
            self.stateRaw = stateRaw
        }
    }

    @Model
    final class GoogleCalendarChoice {
        var id: UUID
        var calendarID: String
        var name: String
        var isPrimary: Bool
        var isOn: Bool
        var order: Int

        init(id: UUID, calendarID: String, name: String, isPrimary: Bool, isOn: Bool, order: Int) {
            self.id = id
            self.calendarID = calendarID
            self.name = name
            self.isPrimary = isPrimary
            self.isOn = isOn
            self.order = order
        }
    }
}

/// `Settings` exactly as it was before task 172 added `voiceIdentifier`, for
/// `storesFromBeforeTheVoiceSettingOpenAndKeepEverything`. Same class name,
/// so SwiftData gives it the same entity name as the current model.
enum Task171Schema {
    @Model
    final class Settings {
        var zip: String?
        var aiModeRaw: String?
        var aiProviderRaw: String?
        var aiInterestsText: String?
        var aiDailyCap: Int?
        var aiLastSentAt: Date?
        var aiKeyRefused: Bool?
        var aiLastProblemRaw: String?

        init(zip: String? = nil) {
            self.zip = zip
        }
    }
}
