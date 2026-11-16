import SwiftData
import SwiftUI

@main
struct SeasignApp: App {
    /// The local store: settings, the cached sky and the Do/Get lists (see `Store/Models.swift`).
    private let modelContainer: ModelContainer
    @State private var today: TodayModel
    @State private var lists: ListsModel

    init() {
        do {
            modelContainer = try SeasignSchema.container()
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
        _today = State(initialValue: TodayModel(context: modelContainer.mainContext))
        _lists = State(initialValue: ListsModel(context: modelContainer.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            TodayView()
                .environment(today)
                .environment(lists)
        }
        .modelContainer(modelContainer)
    }
}
