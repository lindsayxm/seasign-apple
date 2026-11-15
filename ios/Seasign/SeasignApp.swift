import SwiftData
import SwiftUI

@main
struct SeasignApp: App {
    /// The local store. The schema is empty until the first models arrive (task 4).
    private let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Schema([]))
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            TodayView()
        }
        .modelContainer(modelContainer)
    }
}
