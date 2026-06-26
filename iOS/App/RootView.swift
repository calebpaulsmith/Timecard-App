import SwiftUI
import SwiftData

/// App shell. Timecard mode (the calm, work-shareable default) shows Period /
/// Metrics / Settings. Flipping the sticky **Calendar mode** toggle in Settings
/// reveals the Calendar tab (events + EventKit device-calendar sync) — mirroring
/// the PWA's `calendarMode` setting (default off).
struct RootView: View {
    @AppStorage("calendarMode") private var calendarMode = false
    @AppStorage("appTheme") private var themeId = AppTheme.classic.rawValue
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    private var theme: AppTheme { AppTheme(rawValue: themeId) ?? .classic }

    var body: some View {
        content
            // Themed backdrop: hide every List/Form's opaque system background
            // (this modifier propagates to all scroll views below) and paint the
            // theme's tinted gradient + accent glow behind the whole app, so each
            // theme has a distinct backdrop AND the glass cards/chips have a
            // colorful surface to refract. Classic → the plain system background.
            .scrollContentBackground(.hidden)
            .background { theme.palette.backgroundView.ignoresSafeArea() }
            // Selectable color theme: inject the palette + tint the whole app.
            // Changing `themeId` re-renders the tree, so every `@Environment(\.palette)`
            // reader picks up the new colors live (system dark mode still resolves
            // per theme via the dynamic colors).
            .environment(\.palette, theme.palette)
            .tint(theme.palette.accent)
            // Re-evaluate local reminders on launch and every foreground (period
            // progress and the open-entry timer drift between sessions).
            .task { await ReminderScheduler.refresh(store: TimecardStore(context: context)) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await ReminderScheduler.refresh(store: TimecardStore(context: context)) }
                }
            }
    }

    private var content: some View {
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
