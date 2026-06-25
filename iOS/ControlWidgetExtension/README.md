# ControlWidgetExtension (STAGED — not yet a build target)

These files are the drafted **iOS 18 Control Center tile** for clocking in/out.
They are intentionally **not** referenced by `project.yml`, so XcodeGen does not
compile them and the app build is unaffected.

Wire them on by following **`../docs/CONTROL-WIDGET-SETUP.md`** (App Group + a
widget-extension target + signing). Until then this is reference material that
already compiles against the shared `TimecardStore` clock API from PR #79.

Files:
- `ClockControl.swift` — the `ControlWidget` toggle (iOS 18+).
- `SetClockIntent.swift` — the `SetValueIntent` it fires + the value provider.
- `TimecardWidgetBundle.swift` — the extension's `@main` bundle.
- `Timecard.entitlements` — App Group for the **main app** (move to `App/`).
- `TimecardWidgets.entitlements` — App Group for the **extension**.
