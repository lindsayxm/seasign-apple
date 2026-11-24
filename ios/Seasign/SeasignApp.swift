import SwiftData
import SwiftUI

@main
struct SeasignApp: App {
    /// The local stores and the models that read them, or the fact that the
    /// user's store would not open (see `LocalStore`).
    private enum Session {
        case ready(ModelContainer, TodayModel, ListsModel, EventsModel, GoogleCalendarModel, FeedModel, SavedModel, AISearchModel)
        case storeUnreadable
    }

    @State private var session: Session
    /// Remote-notification callbacks (Google Calendar push, task 158).
    @UIApplicationDelegateAdaptor(SeasignAppDelegate.self) private var appDelegate

    init() {
        _session = State(initialValue: Self.start())
    }

    var body: some Scene {
        WindowGroup {
            switch session {
            case .ready(let container, let today, let lists, let events, let google, let feed, let saved, let ai):
                // The HUD accent comes from the settings row (design v12);
                // the four main pages switch in place (`MainTabsView`).
                HUDAccentRoot { MainTabsView() }
                    .environment(today)
                    .environment(lists)
                    .environment(events)
                    .environment(google)
                    .environment(feed)
                    .environment(saved)
                    .environment(ai)
                    .modelContainer(container)
                    // The phone's 12- or 24-hour setting for every time shown,
                    // kept current while the app runs.
                    .followsSystemClockStyle()
            case .storeUnreadable:
                StoreErrorView {
                    session = Self.start()
                }
            }
        }
    }

    private static func start() -> Session {
        #if DEBUG
        // `-debugStoreFailure YES` shows the error screen without harming a store.
        if UserDefaults.standard.bool(forKey: "debugStoreFailure") {
            return .storeUnreadable
        }
        #endif
        do {
            let container = try LocalStore.open().container
            #if DEBUG
            // `-debugNoZip YES`: Today and Settings on a store held in memory
            // with no zip, so neither the user's zip, its place nor its
            // weather shows and nothing is asked (the zip prompt shows).
            let today = UserDefaults.standard.bool(forKey: "debugNoZip")
                ? Self.debugTodayWithoutZip() ?? TodayModel(context: container.mainContext)
                : TodayModel(context: container.mainContext)
            #else
            let today = TodayModel(context: container.mainContext)
            #endif
            let live = EventsModel(context: container.mainContext) {
                // The zip's time zone when a zip is set, otherwise the phone's.
                EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: .autoupdatingCurrent)
            }
            let liveGoogle = GoogleCalendarModel(context: container.mainContext) {
                EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: .autoupdatingCurrent)
            }
            // Asked only while Google is connected (`GoogleWatchKeeper`).
            liveGoogle.watch.register = { UIApplication.shared.registerForRemoteNotifications() }
            #if DEBUG
            // `-debugLists YES`: sample Do and Get items in a store held in memory.
            let lists = UserDefaults.standard.bool(forKey: "debugLists")
                ? (try? SeasignSchema.inMemoryContainer()).flatMap { try? ListsModel.sample(context: ModelContext($0)) }
                    ?? ListsModel(context: container.mainContext)
                : ListsModel(context: container.mainContext)
            #else
            let lists = ListsModel(context: container.mainContext)
            #endif
            let feed = FeedModel(context: container.mainContext)
            let saved = SavedModel(context: container.mainContext)
            // Searches are counted per day in the zip's time zone when known.
            let zone = { EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: .autoupdatingCurrent) }
            #if DEBUG
            // `-debugEvents YES` shows sample links and events held in memory;
            // `-debugFeed YES` sample sites and headlines, likewise;
            // `-debugSaved YES` sample saved articles, likewise;
            // `-debugAI YES` AI search configured with a fake key and
            // AI-found items, likewise (it implies the feed sample).
            // `-debugSeedLink <link>` one public calendar link in a store held
            // in memory, asked for from the API as usual (`EventsModel.seeded`).
            let defaults = UserDefaults.standard
            let seeded = defaults.string(forKey: "debugSeedLink").flatMap { link in
                try? EventsModel.seeded(link: link) {
                    EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: .autoupdatingCurrent)
                }
            }
            let events = defaults.bool(forKey: "debugEvents") ? (try? EventsModel.sample()) ?? live : seeded ?? live
            // `-debugGoogle YES`: a connected Google account with sample
            // calendars and events, in memory, with no token and no requests;
            // `-debugGoogleReadOnly YES` the same without write access.
            // `-debugGoogleConnectProblem <case>` (with either) shows that
            // Connect problem's note on the sample, e.g. `accountNotShown`.
            let googleReadOnly = defaults.bool(forKey: "debugGoogleReadOnly")
            let google = defaults.bool(forKey: "debugGoogle") || googleReadOnly
                ? (try? GoogleCalendarModel.sample(
                    readOnly: googleReadOnly,
                    connectProblem: .debugNamed(defaults.string(forKey: "debugGoogleConnectProblem"))
                )) ?? liveGoogle
                : liveGoogle
            // `-debugSavedProblem <case>` shows that problem's line on Saved
            // (`notSaved`, `notRemoved`, `notesNotSaved`), on the in-memory
            // Saved store; `-debugSavedNotesFull YES` (with `-debugSaved`)
            // the first sample's notes at the limit; `-debugAIKeyUnreadable YES` (with `-debugAI`) a
            // key store that will not answer, as a locked Keychain.
            let showAI = defaults.bool(forKey: "debugAI")
            let savedProblem = SavedModel.Problem.debugNamed(defaults.string(forKey: "debugSavedProblem"))
            let sample = debugSamples(
                feed: feed,
                saved: saved,
                showFeed: defaults.bool(forKey: "debugFeed") || showAI,
                showSaved: defaults.bool(forKey: "debugSaved"),
                showAI: showAI,
                savedProblem: savedProblem,
                savedNotesFull: defaults.bool(forKey: "debugSavedNotesFull"),
                aiKeyUnreadable: defaults.bool(forKey: "debugAIKeyUnreadable")
            )
            // With `-debugAI` the real Keychain is never used, even when the
            // samples could not be built: the fallback holds the fake key in
            // memory and sends nothing.
            let ai = sample.ai ?? (showAI
                ? AISearchModel.debugFallback(feed: sample.feed, context: container.mainContext)
                : AISearchModel(context: container.mainContext, feed: sample.feed, zone: zone))
            RemotePushRelay.shared.attach(google)
            return .ready(container, today, lists, events, google, sample.feed, sample.saved, ai)
            #else
            let ai = AISearchModel(context: container.mainContext, feed: feed, zone: zone)
            RemotePushRelay.shared.attach(liveGoogle)
            return .ready(container, today, lists, live, liveGoogle, feed, saved, ai)
            #endif
        } catch {
            return .storeUnreadable
        }
    }

    #if DEBUG
    /// The DEBUG feed, saved and AI samples share one store in memory. With
    /// any flag on, Saved uses that store too (empty unless `showSaved`),
    /// so saving a sample headline never writes into the user's own store.
    /// The AI sample also keeps its settings, its count and its fake key in
    /// memory, so the user's store and the real Keychain are not touched;
    /// if the feed sample cannot be built, the AI model is still the frozen
    /// in-memory fallback, never one on the real Keychain. `ai` is nil only
    /// when `showAI` is off or no in-memory store could be made.
    /// A Saved problem (`savedProblem`) also puts Saved on that store, and
    /// is shown there.
    static func debugSamples(
        feed: FeedModel,
        saved: SavedModel,
        showFeed: Bool,
        showSaved: Bool,
        showAI: Bool,
        savedProblem: SavedModel.Problem? = nil,
        savedNotesFull: Bool = false,
        aiKeyUnreadable: Bool = false,
        feedSample: (ModelContext) throws -> FeedModel = { try FeedModel.sample(context: $0) }
    ) -> (feed: FeedModel, saved: SavedModel, ai: AISearchModel?) {
        guard showFeed || showSaved || showAI || savedProblem != nil,
              let container = try? SeasignSchema.inMemoryContainer()
        else { return (feed, saved, nil) }
        let context = ModelContext(container)
        let sampleFeed = showFeed ? (try? feedSample(context)) ?? feed : feed
        let sampleSaved = showSaved
            ? (try? SavedModel.sample(context: context, includingAI: showAI, notesFull: savedNotesFull)) ?? SavedModel(context: context)
            : SavedModel(context: context)
        sampleSaved.problem = savedProblem
        var ai: AISearchModel?
        if showAI {
            if sampleFeed !== feed {
                sampleFeed.addSampleAIItems()
                ai = AISearchModel.sample(feed: sampleFeed, context: context, keyUnreadable: aiKeyUnreadable)
            } else {
                ai = AISearchModel.debugFallback(feed: sampleFeed, context: context)
            }
        }
        return (sampleFeed, sampleSaved, ai)
    }

    /// `-debugNoZip`: a Today model on a store held in memory, its zip
    /// removed (a fresh store starts with the default one).
    @MainActor
    static func debugTodayWithoutZip() -> TodayModel? {
        guard let container = try? SeasignSchema.inMemoryContainer() else { return nil }
        let today = TodayModel(context: ModelContext(container))
        today.clearZip()
        return today
    }
    #endif
}
