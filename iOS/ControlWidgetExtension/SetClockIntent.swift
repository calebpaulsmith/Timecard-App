import AppIntents
import SwiftData

// SET-VALUE INTENT for the Control Center toggle.
//
// A `ControlWidgetToggle` drives a `SetValueIntent`: the new on/off value comes
// in as `value`, and we clock in (true) or out (false). It reuses the exact same
// `TimecardStore` clock authority as the in-app button and the Siri intents.
//
// NOTE: this file is STAGED — it is not in any Xcode target until you wire the
// extension per docs/CONTROL-WIDGET-SETUP.md. It does not affect the app build.

struct SetClockIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Timecard Clock"
    static var description = IntentDescription("Clock in or out from Control Center.")

    @Parameter(title: "Clocked In")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = TimecardStore(context: ModelContext(TimecardStore.sharedContainer))
        // Idempotent: clockIn/clockOut no-op if already in the requested state.
        if value { store.clockIn() } else { store.clockOut() }
        await ReminderScheduler.refresh(store: store)
        return .result()
    }
}

// VALUE PROVIDER — reads the current clock state so the toggle shows in/out.
// Runs in the extension; reads the SHARED App Group store (hence the entitlement).
struct ClockControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    @MainActor
    func currentValue() async throws -> Bool {
        let store = TimecardStore(context: ModelContext(TimecardStore.sharedContainer))
        return store.isClockedInToday()
    }
}
