import SwiftUI
import SwiftData

/// App shell. Timecard mode (the calm, work-shareable default) shows Period /
/// Metrics / Settings. Flipping the sticky **Calendar mode** toggle in Settings
/// reveals the Calendar tab (events + EventKit device-calendar sync) — mirroring
/// the PWA's `calendarMode` setting (default off).
struct RootView: View {
    @AppStorage("calendarMode") private var calendarMode = false
    @AppStorage("appTheme") private var themeId = AppTheme.classic.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// Handles an opened activity (a `.ics` file or `webcal://` link) → the add flow.
    @State private var opener = ActivityOpener()

    private var theme: AppTheme { AppTheme(rawValue: themeId) ?? .classic }
    /// Force light/dark regardless of the OS setting ("a real light mode"); nil =
    /// follow the system.
    private var forcedScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

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
            .preferredColorScheme(forcedScheme)
            // Re-evaluate local reminders on launch and every foreground (period
            // progress and the open-entry timer drift between sessions).
            .task {
                let store = TimecardStore(context: context)
                await ReminderScheduler.refresh(store: store)
                await EventReminderScheduler.refresh(store: store)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    let store = TimecardStore(context: context)
                    Task {
                        await ReminderScheduler.refresh(store: store)
                        await EventReminderScheduler.refresh(store: store)
                    }
                }
            }
            // Opening a calendar activity (a .ics file or webcal:// link) from
            // another app → parse it and walk the user through adding it. Reveal the
            // Calendar tab so the added event is visible/manageable afterwards.
            .onOpenURL { url in
                if opener.store == nil { opener.store = TimecardStore(context: context) }
                calendarMode = true
                opener.open(url)
            }
            .sheet(item: $opener.current,
                   onDismiss: { Task { @MainActor in opener.presentNext() } }) { draft in
                EventEditView(draft: draft, model: opener, calendars: opener.calendars)
            }
            .alert("Couldn't add activity", isPresented: activityErrorPresented) {
                Button("OK", role: .cancel) { opener.message = nil }
            } message: {
                Text(opener.message ?? "")
            }
    }

    /// Bridges `opener.message` (String?) to the alert's Bool presentation binding.
    private var activityErrorPresented: Binding<Bool> {
        Binding(get: { opener.message != nil },
                set: { if !$0 { opener.message = nil } })
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
