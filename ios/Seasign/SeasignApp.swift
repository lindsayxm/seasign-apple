import SwiftData
import SwiftUI

@main
struct SeasignApp: App {
    /// The local stores and the models that read them, or the fact that the
    /// user's store would not open (see `LocalStore`).
    private enum Session {
        case ready(ModelContainer, TodayModel, ListsModel, EventsModel, FeedModel, SavedModel)
        case storeUnreadable
    }

    @State private var session: Session

    init() {
        _session = State(initialValue: Self.start())
    }

    var body: some Scene {
        WindowGroup {
            switch session {
            case .ready(let container, let today, let lists, let events, let feed, let saved):
                TodayView()
                    .environment(today)
                    .environment(lists)
                    .environment(events)
                    .environment(feed)
                    .environment(saved)
                    .modelContainer(container)
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
            let today = TodayModel(context: container.mainContext)
            let live = EventsModel(context: container.mainContext) {
                // The zip's time zone when a zip is set, otherwise the phone's.
                EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: .autoupdatingCurrent)
            }
            let lists = ListsModel(context: container.mainContext)
            let feed = FeedModel(context: container.mainContext)
            let saved = SavedModel(context: container.mainContext)
            #if DEBUG
            // `-debugEvents YES` shows sample links and events held in memory;
            // `-debugFeed YES` sample sites and headlines, likewise;
            // `-debugSaved YES` sample saved articles, likewise.
            let defaults = UserDefaults.standard
            let events = defaults.bool(forKey: "debugEvents") ? (try? EventsModel.sample()) ?? live : live
            let sample = debugFeedAndSaved(
                feed: feed,
                saved: saved,
                showFeed: defaults.bool(forKey: "debugFeed"),
                showSaved: defaults.bool(forKey: "debugSaved")
            )
            return .ready(container, today, lists, events, sample.feed, sample.saved)
            #else
            return .ready(container, today, lists, live, feed, saved)
            #endif
        } catch {
            return .storeUnreadable
        }
    }

    #if DEBUG
    /// The DEBUG feed and saved samples share one store in memory. With
    /// either flag on, Saved uses that store too (empty unless `showSaved`),
    /// so saving a sample headline never writes into the user's own store.
    private static func debugFeedAndSaved(
        feed: FeedModel,
        saved: SavedModel,
        showFeed: Bool,
        showSaved: Bool
    ) -> (feed: FeedModel, saved: SavedModel) {
        guard showFeed || showSaved,
              let container = try? SeasignSchema.inMemoryContainer()
        else { return (feed, saved) }
        let context = ModelContext(container)
        let sampleFeed = showFeed ? (try? FeedModel.sample(context: context)) ?? feed : feed
        let sampleSaved = showSaved
            ? (try? SavedModel.sample(context: context)) ?? SavedModel(context: context)
            : SavedModel(context: context)
        return (sampleFeed, sampleSaved)
    }
    #endif
}
