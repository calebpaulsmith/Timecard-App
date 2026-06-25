# Control Center tile + widget extension — setup runbook

This is the **part-2** of the "Control + App Intent" native bet. Part 1 (PR #79)
shipped the clock App Intents + Siri/Shortcuts. This adds the **iOS 18 Control
Center tile** that clocks you in/out from Control Center.

It can't be merged-and-shipped purely from code: a widget **extension** is a
second app target that needs its own Apple **App ID**, an **App Group**, and a
**provisioning profile**. This doc is the exact, ordered checklist — the Apple
account steps (only you can do these) and the local wiring (already drafted here
as ready-to-apply diffs + staged files in `iOS/ControlWidgetExtension/`).

> **Nothing in this PR touches the buildable app.** The staged files are in a
> folder XcodeGen doesn't compile yet, and `project.yml` is unchanged, so `main`
> stays green and signable. You wire it on after the Apple-side steps below.

---

## Why an extension at all

A Control Center control (`ControlWidget`) **must** live in a Widget Extension —
it runs in a separate process from the app. For its toggle to show "Clocked
in/out" and to write a clock entry, the extension and the app must read/write the
**same** SwiftData store. They share it through an **App Group container**. So
three things are new: an App Group, the extension target, and entitlements on
both targets pointing at that group.

---

## Part A — what YOU do in the Apple Developer account (~15 min)

You need the paid Apple Developer Program (already have it). At
<https://developer.apple.com/account> → **Certificates, Identifiers & Profiles**:

1. **Create the App Group**
   - Identifiers → (filter) **App Groups** → ➕ →
     **Description:** `Timecard App Group`,
     **Identifier:** `group.com.thegrandpipeline.timecard` → Register.
   - (This is the ID the code already reserves — keep it exact.)

2. **Enable App Groups on the main app's App ID**
   - Identifiers → **App IDs** → `com.thegrandpipeline.timecard` → **App Groups**
     capability ☑ → **Edit/Configure** → tick `group.com.thegrandpipeline.timecard`
     → Save.

3. **Register the extension App ID**
   - Identifiers → **App IDs** → ➕ → **App** →
     **Description:** `Timecard Widgets`,
     **Bundle ID (explicit):** `com.thegrandpipeline.timecard.TimecardWidgets`
   - Enable the **App Groups** capability and tick the same group → Continue →
     Register.

That's all that strictly requires the website. Provisioning profiles are handled
by `match` in Part C (it creates/updates them for both bundle IDs).

> If you use the App Store Connect API key flow (you do — see `docs/CICD-SETUP.md`),
> `match` can register identifiers too, but doing the 3 steps above by hand is the
> reliable path and takes a few minutes.

---

## Part B — local wiring (apply these diffs; I can do this in a follow-up PR)

### B1. Move the entitlements into place
Two staged files in `iOS/ControlWidgetExtension/`:
- `Timecard.entitlements`  → move to `iOS/App/Timecard.entitlements`
- `TimecardWidgets.entitlements` → keep with the extension sources.

### B2. Move the extension sources
The staged Swift files (`ClockControl.swift`, `SetClockIntent.swift`,
`TimecardWidgetBundle.swift`) become the extension target's sources. They already
reference the shared `TimecardStore`/`ReminderScheduler`, so the extension target
must **also compile** the few files it needs, or (simpler) we make a tiny shared
membership. Easiest: add `Store/`, `Domain/`, and `Platform/Reminders.swift` +
`Platform/ClockIntents.swift` to the extension target too (they're pure/SwiftData,
no app-only deps). See the `project.yml` block below.

### B3. `project.yml` — add the extension target + entitlements
```yaml
targets:
  Timecard:
    # ... existing ...
    settings:
      base:
        # add:
        CODE_SIGN_ENTITLEMENTS: App/Timecard.entitlements
    dependencies:
      - target: TimecardWidgets          # app embeds the extension

  TimecardWidgets:
    type: app-extension
    platform: iOS
    # WidgetKit extensions need iOS 14+, but the Control needs 18; the @available
    # guard handles the runtime gate. Keep deployment target aligned with the app.
    sources:
      - path: ControlWidgetExtension
      - path: Store                       # shared SwiftData store
      - path: Domain                      # pure helpers used by the store
      - path: Platform/ClockIntents.swift
      - path: Platform/Reminders.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.thegrandpipeline.timecard.TimecardWidgets
        CODE_SIGN_ENTITLEMENTS: ControlWidgetExtension/TimecardWidgets.entitlements
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: Timecard
        INFOPLIST_KEY_NSExtensionPointIdentifier: com.apple.widgetkit-extension
        SKIP_INSTALL: YES
```
> If sharing `Store/`+`Domain/` into the extension causes duplicate-symbol or
> `@main` conflicts, the cleaner alternative is a small **shared framework
> target** (`TimecardKit`) that both the app and the extension depend on. That's
> a bigger refactor; start with shared file membership and only extract a
> framework if the compiler complains.

### B4. Flip the SwiftData store to the App Group container
In `iOS/Store/TimecardStore.swift`, change `makeContainer` so both processes open
the **same** group store:
```swift
static let appGroupID = "group.com.thegrandpipeline.timecard"

static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
    let config: ModelConfiguration
    if inMemory {
        config = ModelConfiguration(isStoredInMemoryOnly: true)
    } else {
        config = ModelConfiguration(groupContainer: .identifier(appGroupID))
    }
    return try ModelContainer(for: StoredEntry.self, StoredLeave.self,
                              StoredSetting.self, StoredEvent.self,
                              configurations: config)
}
```
`inMemory` stays group-free so unit tests keep working unchanged.

### B5. Generate + build
```
cd iOS && xcodegen generate        # regenerates the .xcodeproj with the new target
# build the Timecard scheme; add the control via Control Center → Customize.
```

---

## Part C — CI / signing (`match`) — one-time

The TestFlight pipeline signs every target. The new extension bundle id needs a
distribution profile:
```
cd iOS
bundle exec fastlane match appstore        # picks up BOTH bundle ids now
# or re-run the "iOS Bootstrap signing" GitHub Action once.
```
Confirm `fastlane/Matchfile` / `Appfile` cover
`com.thegrandpipeline.timecard.TimecardWidgets` (match enumerates targets from the
project, so a regenerated project usually "just works"; if not, add the bundle id
explicitly). Then a normal `v*` tag build embeds + signs the extension.

---

## ⚠️ Data migration (read before shipping to anyone)

Switching to the App Group container (**B4**) changes **where** the SQLite store
lives. SwiftData will open a **fresh, empty** store at the new group location —
existing on-device data stays at the OLD location and looks "lost."

**Because the app is pre-launch (TestFlight only), the clean move is to do B4
BEFORE any public release** — then there's no real user data to migrate. For
current TestFlight installs, either reinstall, or use the built-in **CSV backup**
(Settings → Export, update, Import) to carry data across. That's the safest
migration and it already exists.

If we ever need a seamless in-place migration (post-launch), the approach is a
one-time file copy of `default.store` (+ `-wal`/`-shm`) from Application Support
into the group container before first open — but prefer "do it pre-launch."

---

## Battery, privacy & other considerations

**Battery — negligible.** Controls and App Intents are **event-driven**: code runs
only when you tap the control or fire a Shortcut/Siri phrase. There is **no
background polling, no timers, no network**. The value provider
(`currentValue()`) runs only when the system refreshes the control (e.g. opening
Control Center) and just does one local SwiftData read. This is the *cheap* native
surface — the battery-sensitive one is a **Live Activity** (persistent, updates
while running), which we deliberately have NOT built yet.

**Privacy — stays on device.**
- The App Group shares data **only between this app and its own extension**,
  inside your app's sandbox. No other app can read it; nothing leaves the phone.
- No network access is added. (CloudKit sync — a *future*, separate decision —
  would be the first thing that changes this; not part of this.)
- **Siri/Shortcuts caveat:** spoken/confirmation strings like *"Clocked in at
  9:00"* are handled by the system and can show on the lock screen / in the
  Shortcuts app. They're mundane, but if you'd rather not surface times there we
  can make the dialogs generic ("Clocked in.") — easy tweak.
- **Spotlight/Shortcuts donation:** App Shortcuts are indexed so "Clock in" is
  discoverable. That's the feature working as intended; no personal data is
  indexed, only the action.

**Other things worth knowing.**
- **iOS 18+ only** for the Control tile (the `@available(iOS 18)` guard keeps the
  app itself at iOS 17). Pre-18 devices simply won't see the control; Siri/
  Shortcuts (part 1) work on iOS 16+.
- **Two targets to sign & maintain.** Every release now builds and signs the
  extension too. Once `match` knows the bundle id, it's automatic, but it's a
  second moving part in CI.
- **Cross-process freshness.** A clock from the control/Siri writes the shared
  store from another process; the app refreshes its views on next appear/
  foreground (it already does), so the change shows up when you next look — not
  necessarily live if the app is already on-screen. Fine for this feature.
- **App size:** an extension adds a small amount to the download. Trivial here.
- **App Group ID is load-bearing.** Never change
  `group.com.thegrandpipeline.timecard` after data lives in it — that *is* the
  pointer to the shared store.
- **Concurrent writes.** Two processes can in principle write at once; in practice
  the user can't tap the control and the in-app button simultaneously, and
  SwiftData/SQLite serialize writes. Low risk, but noted.

---

## Status / definition of done
- [ ] Part A — App Group + two App IDs registered (you)
- [ ] B1–B2 — entitlements + sources moved into targets
- [ ] B3 — `project.yml` extension target added; `xcodegen generate`
- [ ] B4 — container flipped to App Group (do pre-launch)
- [ ] B5 — builds; control appears in Control Center → Customize
- [ ] Part C — `match` covers the extension bundle id; TestFlight build embeds it
- [ ] Device pass — toggle clocks in/out and reflects state; data shows in-app
