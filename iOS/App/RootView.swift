import SwiftUI

/// App shell. The Period tab is the real Phase 3 screen; Metrics + Settings
/// land in later increments.
struct RootView: View {
    var body: some View {
        TabView {
            PeriodView()
                .tabItem { Label(AppRoute.period.title, systemImage: AppRoute.period.systemImage) }

            ComingSoonView(title: "Metrics")
                .tabItem { Label(AppRoute.metrics.title, systemImage: AppRoute.metrics.systemImage) }

            ComingSoonView(title: "Settings")
                .tabItem { Label(AppRoute.settings.title, systemImage: AppRoute.settings.systemImage) }
        }
    }
}

private struct ComingSoonView: View {
    let title: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("Coming in a later phase."))
    }
}

#Preview {
    RootView()
}
