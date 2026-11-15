import SwiftData
import SwiftUI

@main
struct SeasignApp: App {
    /// The local store: settings and the cached sky (see `Store/Models.swift`).
    private let modelContainer: ModelContainer
    @State private var today: TodayModel

    init() {
        do {
            modelContainer = try SeasignSchema.container()
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
        _today = State(initialValue: TodayModel(context: modelContainer.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            TodayView()
                .environment(today)
        }
        .modelContainer(modelContainer)
    }
}
