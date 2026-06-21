import SwiftUI
import SwiftData

@main
struct TimecardApp: App {
    /// The SwiftData store (Phase 2). Local default location for now; the App
    /// Group container + CloudKit mirror arrive with widgets (Phase 7).
    let container: ModelContainer

    init() {
        do {
            container = try TimecardStore.makeContainer()
        } catch {
            fatalError("Failed to create the SwiftData ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
