import SwiftData
import SwiftUI

@main
struct SeasignApp: App {
    /// The local stores and the models that read them, or the fact that the
    /// user's store would not open (see `LocalStore`).
    private enum Session {
        case ready(ModelContainer, TodayModel, ListsModel)
        case storeUnreadable
    }

    @State private var session: Session

    init() {
        _session = State(initialValue: Self.start())
    }

    var body: some Scene {
        WindowGroup {
            switch session {
            case .ready(let container, let today, let lists):
                TodayView()
                    .environment(today)
                    .environment(lists)
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
            return .ready(
                container,
                TodayModel(context: container.mainContext),
                ListsModel(context: container.mainContext)
            )
        } catch {
            return .storeUnreadable
        }
    }
}
