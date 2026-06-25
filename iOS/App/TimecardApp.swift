import SwiftUI
import SwiftData

@main
struct TimecardApp: App {
    /// The SwiftData store (Phase 2). Process-wide shared container so the Clock
    /// App Intents (Siri / Shortcuts / future Control Center) hit the same store.
    /// The App Group container + CloudKit mirror arrive with widgets (Phase 7).
    let container = TimecardStore.sharedContainer

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
