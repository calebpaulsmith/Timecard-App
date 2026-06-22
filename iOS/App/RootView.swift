import SwiftUI

/// App shell: the three timecard tabs. Calendar mode lands in a later phase.
struct RootView: View {
    var body: some View {
        TabView {
            PeriodView()
                .tabItem { Label(AppRoute.period.title, systemImage: AppRoute.period.systemImage) }

            MetricsView()
                .tabItem { Label(AppRoute.metrics.title, systemImage: AppRoute.metrics.systemImage) }

            SettingsView()
                .tabItem { Label(AppRoute.settings.title, systemImage: AppRoute.settings.systemImage) }
        }
    }
}

#Preview {
    RootView()
}
