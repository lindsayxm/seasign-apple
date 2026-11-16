import Foundation
import Observation
import SwiftData

/// AI search: the settings behind the pill toggle, the key (in the Keychain
/// only), the daily cap counted on the phone, and the searches themselves.
///
/// Rules, all enforced here and unit-tested:
/// - With Use My List selected no `POST /v1/discover` call is ever made
///   (`SearchGate`), and AI-found items are hidden (`FeedModel.showsAI`).
/// - A search is counted when it is sent, before the request leaves, in the
///   same main-actor turn as the check, so two refreshes that race can never
///   pass the cap. Only an answer that proves nothing was billed gives the
///   search back: 400 `invalid_request` and 401 `invalid_key`.
/// - Automatic searches (launch, return to the foreground) are spaced at
///   least 24 h / cap apart; "Search now" ignores the spacing, never the cap.
/// - After 401 `invalid_key`, automatic searches stop until the key or
///   provider changes.
/// - The key is read from the Keychain at send time and handed to the API
///   call; this model never keeps it in a property.
/// - "No key" and "the Keychain could not be read" are kept apart
///   (`KeyStatus`): an unreadable Keychain (before the first unlock after a
///   restart) sends nothing, switches nothing off and never asks for the key
///   again. It is read again on every search attempt, when the app becomes
///   active and when Settings opens.
@MainActor
@Observable
final class AISearchModel {
    /// Why a key typed in Settings was not saved or removed. Fixed text.
    enum KeyProblem: Error, Equatable {
        case invalidShape
        case notSaved
        case notRemoved

        var message: String {
            switch self {
            case .invalidShape:
                "That doesn't look like an API key. Keys are \(APIKey.minLength) to \(APIKey.maxLength) characters with no spaces."
            case .notSaved:
                "The key couldn't be saved on this phone. Try again."
            case .notRemoved:
                "The key couldn't be removed from this phone. Try again."
            }
        }
    }

    /// What the last search that came back found.
    struct LastSearch: Equatable {
        var at: Date
        var found: Int
    }

    private(set) var mode: AIMode = .myList
    private(set) var provider: AIProvider = .default
    /// The interests as typed.
    private(set) var interestsText = ""
    private(set) var dailyCap = DailyCap.default
    /// What the Keychain last said about the key. The key itself is never held here.
    private(set) var keyStatus: KeyStatus = .unknown
    /// The Keychain holds a key (and could be read).
    var hasKey: Bool { keyStatus == .saved }
    /// The provider refused the key; automatic searches are stopped.
    private(set) var keyRefused = false
    /// How the last search went wrong, for Settings only.
    private(set) var problem: AISearchProblem?
    private(set) var isSearching = false
    private(set) var lastSearch: LastSearch?
    /// The provider was changed while a key is saved: Settings reminds the
    /// user the key must be that provider's.
    private(set) var providerChangedSinceKey = false
    /// Searches sent per day (`SearchDay.key`).
    private(set) var counts: [String: Int] = [:]

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let keyStore: any APIKeyStore
    @ObservationIgnored private let feed: FeedModel
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let zone: () -> TimeZone
    @ObservationIgnored private let commit: (ModelContext) throws -> Void
    /// Changes whenever the key or provider does, so a 401 for an old key
    /// does not stop searches with the new one.
    @ObservationIgnored private var keyGeneration = 0
    /// Set for the DEBUG sample: nothing is ever sent.
    @ObservationIgnored private var isFrozen = false

    init(
        api: SeasignAPI = SeasignAPI(),
        context: ModelContext,
        keyStore: any APIKeyStore = KeychainKeyStore(),
        feed: FeedModel,
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping () -> TimeZone = { .autoupdatingCurrent },
        commit: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.api = api
        self.context = context
        self.keyStore = keyStore
        self.feed = feed
        self.now = now
        self.zone = zone
        self.commit = commit
        let settings = settingsRow()
        mode = settings.aiModeRaw.flatMap(AIMode.init(rawValue:)) ?? .myList
        provider = settings.aiProviderRaw.flatMap(AIProvider.init(rawValue:)) ?? .default
        interestsText = settings.aiInterestsText ?? ""
        dailyCap = DailyCap.clamp(settings.aiDailyCap)
        keyRefused = settings.aiKeyRefused ?? false
        problem = settings.aiLastProblemRaw.flatMap(AISearchProblem.init(rawValue:))
        // The pill never shows a state that is not true: a store restored to
        // another phone arrives without the key (it never leaves the device),
        // and interests may have been emptied. A Keychain that cannot be read
        // right now leaves the choice alone (see `readKey`).
        _ = readKey()
        if mode == .aiSearch, interests.isEmpty {
            mode = .myList
            write { $0.aiModeRaw = AIMode.myList.rawValue }
        }
        reloadCounts()
        updateVisibility()
    }

    // MARK: Reading

    var parsedInterests: InterestList.Parsed {
        InterestList.parse(interestsText)
    }

    var interests: [String] {
        parsedInterests.interests
    }

    var precondition: AIPrecondition {
        AIPrecondition(key: keyStatus, interests: interests)
    }

    /// AI search is on and can run: the toggle is on Let AI Search, and a key
    /// and at least one interest are set.
    var isActive: Bool {
        mode == .aiSearch && precondition == .ready
    }

    /// The day searches are counted on now: in the zip's time zone when it is
    /// known, else the phone's.
    var today: String {
        SearchDay.key(now(), timeZone: zone())
    }

    var usedToday: Int {
        counts[today] ?? 0
    }

    var capReached: Bool {
        usedToday >= dailyCap
    }

    /// "2 of 3 searches used today".
    var usageLine: String {
        DailyCap.usage(used: usedToday, cap: dailyCap)
    }

    /// Whether "Search now" can be tapped.
    var canSearchNow: Bool {
        gate(now: now()).decide(.manual, now: now()) == .send
    }

    // MARK: Changing settings

    /// Moves the pill. Let AI Search is refused (returns false) until a key
    /// and an interest are set; `precondition.message` says why.
    @discardableResult
    func setMode(_ newMode: AIMode) -> Bool {
        if newMode == .aiSearch, precondition != .ready { return false }
        guard newMode != mode else { return true }
        mode = newMode
        write { $0.aiModeRaw = newMode.rawValue }
        updateVisibility()
        return true
    }

    func setProvider(_ newProvider: AIProvider) {
        guard newProvider != provider else { return }
        provider = newProvider
        keyGeneration += 1
        if hasKey { providerChangedSinceKey = true }
        keyRefused = false
        if problem == .invalidKey { problem = nil }
        write {
            $0.aiProviderRaw = newProvider.rawValue
            $0.aiKeyRefused = nil
            $0.aiLastProblemRaw = self.problem?.rawValue
        }
    }

    /// Stores the interests as typed. With none left, the toggle goes back to
    /// Use My List and AI-found items are hidden.
    func setInterests(_ text: String) {
        guard text != interestsText else { return }
        interestsText = text
        write { $0.aiInterestsText = text }
        if mode == .aiSearch, interests.isEmpty {
            setMode(.myList)
        }
        updateVisibility()
    }

    func setDailyCap(_ value: Int) {
        let clamped = DailyCap.clamp(value)
        guard clamped != dailyCap else { return }
        dailyCap = clamped
        write { $0.aiDailyCap = clamped }
    }

    /// Saves a key typed or pasted in Settings into the Keychain. Throws a
    /// `KeyProblem`; the error never holds the key.
    func saveKey(_ typed: String) throws(KeyProblem) {
        guard let key = APIKey(typed: typed) else { throw .invalidShape }
        do {
            try keyStore.save(key)
        } catch {
            throw .notSaved
        }
        keyStatus = .saved
        keyGeneration += 1
        keyRefused = false
        providerChangedSinceKey = false
        if problem == .invalidKey || problem == .keyUnreadable { problem = nil }
        write {
            $0.aiKeyRefused = nil
            $0.aiLastProblemRaw = self.problem?.rawValue
        }
        updateVisibility()
    }

    /// Removes the key from the Keychain. The toggle goes back to Use My List
    /// and AI-found items are hidden; a saved AI-found article stays saved.
    func removeKey() throws(KeyProblem) {
        do {
            try keyStore.delete()
        } catch {
            throw .notRemoved
        }
        keyStatus = .missing
        keyGeneration += 1
        keyRefused = false
        providerChangedSinceKey = false
        problem = nil
        write {
            $0.aiKeyRefused = nil
            $0.aiLastProblemRaw = nil
        }
        if mode == .aiSearch { setMode(.myList) }
        updateVisibility()
    }

    // MARK: The key's status

    /// Asks the Keychain again whether a key is stored. Called when the app
    /// becomes active and when Settings opens, so a Keychain that could not
    /// be read at launch (the phone not yet unlocked) is noticed once it can.
    func refreshKeyStatus() {
        _ = readKey()
    }

    /// Reads the key and records what the Keychain said. Returns the key for
    /// the caller's local use only. A key found clears an unreadable-key
    /// problem; no key moves the pill back to Use My List; a read that fails
    /// marks the status unknown and changes nothing else.
    private func readKey() -> APIKey? {
        let key: APIKey?
        do {
            key = try keyStore.read()
        } catch {
            keyStatus = .unknown
            setProblem(.keyUnreadable)
            updateVisibility()
            return nil
        }
        keyStatus = key == nil ? .missing : .saved
        if problem == .keyUnreadable { setProblem(nil) }
        if key == nil, mode == .aiSearch {
            setMode(.myList)
        }
        updateVisibility()
        return key
    }

    // MARK: Searching

    /// Called with each feed refresh (launch, return to the foreground). Sends
    /// a search only when `SearchGate` allows an automatic one.
    func refreshIfDue() async {
        await run(.automatic)
    }

    /// "Search now" in Settings: ignores the spacing, never the cap.
    func searchNow() async {
        await run(.manual)
    }

    private func gate(now: Date) -> SearchGate {
        SearchGate(
            mode: mode,
            key: keyStatus,
            interests: interests,
            cap: dailyCap,
            usedToday: counts[SearchDay.key(now, timeZone: zone())] ?? 0,
            lastSentAt: settingsRow().aiLastSentAt,
            keyRefused: keyRefused,
            isSearching: isSearching
        )
    }

    private func run(_ trigger: SearchGate.Trigger) async {
        guard !isFrozen else { return }
        // Everything up to the request is synchronous on the main actor: the
        // check, the count and `isSearching` change together, so a second
        // call that arrives meanwhile sees them and is dropped.
        let current = now()
        let timeZone = zone()
        let day = SearchDay.key(current, timeZone: timeZone)
        // The Keychain is asked first, so the gate sees what it says now: a
        // key that could not be read at launch counts once it can, and one
        // that cannot be read now sends nothing.
        let stored = readKey()
        guard gate(now: current).decide(trigger, now: current) == .send,
              let key = stored
        else { return }
        guard charge(day: day, at: current) else {
            setProblem(.countNotSaved)
            return
        }
        isSearching = true
        defer { isSearching = false }

        let provider = provider
        let generation = keyGeneration
        do {
            let answer = try await api.discover(
                key: key,
                provider: provider,
                interests: interests,
                timezone: SearchDay.ianaName(timeZone)
            )
            feed.applyDiscovered(answer, provider: provider)
            lastSearch = LastSearch(at: now(), found: answer.items.count)
            setProblem(nil)
        } catch {
            let failure = (error as? SeasignAPI.DiscoverFailure).map(AISearchProblem.init) ?? .unavailable
            if failure.refundsSearch {
                refund(day: day)
            }
            if failure.stopsAutomaticSearch, generation == keyGeneration {
                keyRefused = true
                write { $0.aiKeyRefused = true }
            }
            setProblem(failure)
        }
    }

    // MARK: Store

    private func settingsRow() -> Settings {
        SkyStore(context: context).settings()
    }

    /// Changes the settings row and saves; on failure the change is rolled
    /// back so memory and the store agree on the next launch.
    private func write(_ change: (Settings) -> Void) {
        change(settingsRow())
        do {
            try commit(context)
        } catch {
            context.rollback()
        }
    }

    private func setProblem(_ value: AISearchProblem?) {
        guard value != problem else { return }
        problem = value
        write { $0.aiLastProblemRaw = value?.rawValue }
    }

    /// Counts one search on `day` and records when it was sent, before the
    /// request leaves. Returns false, sending nothing, if that cannot be written.
    private func charge(day: String, at date: Date) -> Bool {
        let rows = countRows(day: day)
        if let row = rows.first {
            row.count += 1
        } else {
            context.insert(SearchCount(day: day, count: 1))
        }
        settingsRow().aiLastSentAt = date
        // Days more than a week old are no longer needed.
        let oldest = SearchDay.key(date.addingTimeInterval(-8 * 86_400), timeZone: zone())
        for row in allCountRows() where row.day < oldest {
            context.delete(row)
        }
        do {
            try commit(context)
        } catch {
            context.rollback()
            reloadCounts()
            return false
        }
        reloadCounts()
        return true
    }

    /// Gives back a search counted on `day` (the day it was charged to, even
    /// if midnight has passed since).
    private func refund(day: String) {
        guard let row = countRows(day: day).first(where: { $0.count > 0 }) else { return }
        row.count -= 1
        do {
            try commit(context)
        } catch {
            context.rollback()
        }
        reloadCounts()
    }

    private func countRows(day: String) -> [SearchCount] {
        let descriptor = FetchDescriptor<SearchCount>(predicate: #Predicate { $0.day == day })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func allCountRows() -> [SearchCount] {
        (try? context.fetch(FetchDescriptor<SearchCount>())) ?? []
    }

    /// Rows for the same day are summed, in case one was ever written twice.
    private func reloadCounts() {
        var fresh: [String: Int] = [:]
        for row in allCountRows() {
            fresh[row.day, default: 0] += row.count
        }
        if fresh != counts { counts = fresh }
    }

    private func updateVisibility() {
        let visible = isActive
        if feed.showsAI != visible { feed.showsAI = visible }
    }
}

#if DEBUG
extension AISearchModel {
    /// The obviously fake key the DEBUG sample and the tests use. It is never
    /// sent anywhere: the sample sends nothing.
    nonisolated static let sampleKey = "test-key-not-real-0000"

    /// Debug-only (`-debugAI YES`): AI search configured and on, with a fake
    /// key held in memory, three interests, and two of three searches used
    /// today, written into `context` (an in-memory store, see `SeasignApp`).
    /// Nothing is sent, and neither the user's store nor the real Keychain is
    /// touched. The AI-found items themselves come from `FeedModel.addSampleAIItems`.
    static func sample(feed: FeedModel, context: ModelContext, now: Date = Date()) -> AISearchModel {
        let settings = SkyStore(context: context).settings()
        settings.aiModeRaw = AIMode.aiSearch.rawValue
        settings.aiProviderRaw = AIProvider.anthropic.rawValue
        settings.aiInterestsText = "tide pools, new telescopes, lake ice"
        settings.aiDailyCap = 3
        settings.aiLastSentAt = now.addingTimeInterval(-2 * 3600)
        context.insert(SearchCount(day: SearchDay.key(now, timeZone: .autoupdatingCurrent), count: 2))
        try? context.save()
        let model = AISearchModel(
            context: context,
            keyStore: InMemoryKeyStore(APIKey(typed: sampleKey)),
            feed: feed,
            now: { Date() }
        )
        model.isFrozen = true
        model.lastSearch = LastSearch(at: now.addingTimeInterval(-2 * 3600), found: 3)
        return model
    }

    /// Debug-only: what `-debugAI` uses when its sample could not be built.
    /// The fake key in an `InMemoryKeyStore`, never the real Keychain, and
    /// frozen, so nothing is ever sent. With a key present, opening it
    /// changes nothing in `context` that a normal launch would not.
    static func debugFallback(feed: FeedModel, context: ModelContext) -> AISearchModel {
        let model = AISearchModel(
            context: context,
            keyStore: InMemoryKeyStore(APIKey(typed: sampleKey)),
            feed: feed
        )
        model.isFrozen = true
        return model
    }

    /// For the tests: whether this model sends nothing and keeps its key in memory.
    var isDebugFrozenInMemory: Bool {
        isFrozen && keyStore is InMemoryKeyStore
    }
}
#endif
