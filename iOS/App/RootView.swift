import SwiftUI

/// App shell. Timecard mode (the calm, work-shareable default) shows Period /
/// Metrics / Settings. Flipping the sticky **Calendar mode** toggle in Settings
/// reveals the Calendar tab (events + EventKit device-calendar sync) — mirroring
/// the PWA's `calendarMode` setting (default off).
struct RootView: View {
    @AppStorage("calendarMode") private var calendarMode = false

    var body: some View {
        TabView {
            PeriodView()
                .tabItem { Label(AppRoute.period.title, systemImage: AppRoute.period.systemImage) }

            if calendarMode {
                CalendarView()
                    .tabItem { Label(AppRoute.calendar.title, systemImage: AppRoute.calendar.systemImage) }
            }

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
