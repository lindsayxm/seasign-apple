import SwiftData
import SwiftUI

@main
struct SeasignApp: App {
    /// The local stores and the models that read them, or the fact that the
    /// user's store would not open (see `LocalStore`).
    private enum Session {
        case ready(ModelContainer, TodayModel, ListsModel, EventsModel, FeedModel)
        case storeUnreadable
    }

    @State private var session: Session

    init() {
        _session = State(initialValue: Self.start())
    }

    var body: some Scene {
        WindowGroup {
            switch session {
            case .ready(let container, let today, let lists, let events, let feed):
                TodayView()
                    .environment(today)
                    .environment(lists)
                    .environment(events)
                    .environment(feed)
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
            #if DEBUG
            // `-debugEvents YES` shows sample links and events held in memory;
            // `-debugFeed YES` sample sites and headlines, likewise.
            let defaults = UserDefaults.standard
            let events = defaults.bool(forKey: "debugEvents") ? (try? EventsModel.sample()) ?? live : live
            let headlines = defaults.bool(forKey: "debugFeed") ? (try? FeedModel.sample()) ?? feed : feed
            return .ready(container, today, lists, events, headlines)
            #else
            return .ready(container, today, lists, live, feed)
            #endif
        } catch {
            return .storeUnreadable
        }
    }
}
