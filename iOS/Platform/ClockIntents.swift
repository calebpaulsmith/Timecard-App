import AppIntents
import SwiftData
import Foundation

/// App Intents for clocking in/out — the foundation for Siri, Shortcuts, and a
/// future Control Center button. They run in the app's process and hit the same
/// `TimecardStore.sharedContainer`, so a clock from Siri shows up in the app.
///
/// The Control Center *tile* itself (a `ControlWidget`) is a follow-up: it needs
/// a widget-extension target + the App Group entitlement + its own provisioning
/// profile. These intents are exactly what that tile will invoke.

/// Toggle today's clock: clock out if running, otherwise clock in.
struct ToggleClockIntent: AppIntent {
    static var title: LocalizedStringResource = "Clock In or Out"
    static var description = IntentDescription("Clocks out if you're running, otherwise clocks in.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TimecardStore(context: ModelContext(TimecardStore.sharedContainer))
        let outcome = store.toggleClock()
        await ReminderScheduler.refresh(store: store)
        return .result(dialog: clockDialog(outcome, use24h: store.use24h))
    }
}

/// Start a new entry now (no-op if already clocked in).
struct ClockInIntent: AppIntent {
    static var title: LocalizedStringResource = "Clock In"
    static var description = IntentDescription("Starts a new Timecard entry now.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TimecardStore(context: ModelContext(TimecardStore.sharedContainer))
        let outcome = store.clockIn()
        await ReminderScheduler.refresh(store: store)
        return .result(dialog: clockDialog(outcome, use24h: store.use24h))
    }
}

/// End the running entry now (no-op if not clocked in).
struct ClockOutIntent: AppIntent {
    static var title: LocalizedStringResource = "Clock Out"
    static var description = IntentDescription("Ends the running Timecard entry now.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TimecardStore(context: ModelContext(TimecardStore.sharedContainer))
        let outcome = store.clockOut()
        await ReminderScheduler.refresh(store: store)
        return .result(dialog: clockDialog(outcome, use24h: store.use24h))
    }
}

/// The spoken/written confirmation for a clock action.
private func clockDialog(_ outcome: TimecardStore.ClockOutcome, use24h: Bool) -> IntentDialog {
    let message: String
    switch outcome {
    case .clockedIn(let start):
        message = "Clocked in at \(formatTime(start, use24h: use24h))."
    case .clockedOut:
        message = "Clocked out."
    case .alreadyClockedIn(let start):
        message = "Already clocked in since \(formatTime(start, use24h: use24h))."
    case .notClockedIn:
        message = "You're not clocked in."
    }
    return IntentDialog(stringLiteral: message)
}

/// Siri phrases + Shortcuts entries. Each phrase must reference the app name.
struct TimecardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ClockInIntent(),
                    phrases: ["Clock in with \(.applicationName)"],
                    shortTitle: "Clock In",
                    systemImageName: "play.circle.fill")
        AppShortcut(intent: ClockOutIntent(),
                    phrases: ["Clock out with \(.applicationName)"],
                    shortTitle: "Clock Out",
                    systemImageName: "stop.circle.fill")
        AppShortcut(intent: ToggleClockIntent(),
                    phrases: ["Toggle the clock with \(.applicationName)"],
                    shortTitle: "Clock In or Out",
                    systemImageName: "clock.arrow.2.circlepath")
    }
}
