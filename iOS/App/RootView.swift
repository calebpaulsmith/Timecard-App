import SwiftUI

/// App shell: the timecard tabs plus the Calendar tab (events + EventKit sync).
struct RootView: View {
    var body: some View {
        TabView {
            PeriodView()
                .tabItem { Label(AppRoute.period.title, systemImage: AppRoute.period.systemImage) }

            CalendarView()
                .tabItem { Label(AppRoute.calendar.title, systemImage: AppRoute.calendar.systemImage) }

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
