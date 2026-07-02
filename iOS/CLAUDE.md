# CLAUDE.md — Timecard (native iOS)

Orienting notes for future Claude sessions. This is the **native iPhone**
rewrite of the Timecard PWA. The full build plan lives in the plan file
referenced below; this file is the durable architecture + conventions doc.

## What this is

A native SwiftUI iPhone app for tracking a federal **maxiflex biweekly schedule**
(80 hrs / 14 days). Single user, fully local (SwiftData). It is a **clean-room
rewrite, not a port and not a WebView wrapper** of the original vanilla-JS PWA —
but it deliberately **preserves the future of the app**: the hard-won domain
logic (two OT modes, pay-period naming, federal holidays, the recurrence engine)
is carried forward faithfully into a tested Swift core, and the still-WIP
calendar mode is architected-for from day one (shipped in a later phase).

The PWA now lives in the **same repo at the root** (this is a monorepo — `../`
from here; see `../PLATFORM-STRATEGY.md` for the full app map). It remains the
work-shareable timecard and stays byte-for-byte. Its `../time.js` /
`../calendar.js` are the **reference oracle** for porting; the frozen spec is
`../LOGIC-FREEZE.md`, and `../CLAUDE.md` carries the product direction +
multi-app working rules. **This `iOS/` tree is the "Timecard iOS" app** — Xcode
target / scheme / module = **Timecard**, and the bundle id + App Group use
`com.thegrandpipeline.timecard` — the App ID already registered on the Apple
Developer account (alongside the owner's other `com.thegrandpipeline.*` apps),
with a matching "Timecard" record in App Store Connect. (It was briefly set to
`com.calebsmith.timecard`, but that App ID was never registered with Apple; the
account uses the `com.thegrandpipeline.*` prefix.) "maxiflex" survives only as
the federal *schedule* term in the Domain layer.

> **Local build requires a Mac** (Xcode). This repo is Windows-authored but iOS
> can only compile/run on macOS. The `.xcodeproj` is generated from `project.yml`
> via XcodeGen — see `README.md`.
>
> **Shipping to an iPhone needs NO Mac**, though: GitHub's macOS runners build,
> sign, and upload to TestFlight. Steps: **`docs/RELEASE-SETUP.md`** (dev
> quickstart) and **`docs/CICD-SETUP.md`** (full click-by-click runbook). One
> hard requirement is the **paid Apple Developer Program ($99/yr)**. The flow:
> set the App Store Connect + match secrets → run **iOS Bootstrap signing** once
> → push a `v*` tag (or dispatch **iOS TestFlight**) to build + upload.
>
> **Versioning:** pushing a tag `vX.Y.Z` sets `MARKETING_VERSION=X.Y.Z` (the
> workflow passes `VERSION_TAG`, the Fastfile strips the `v` into `build_app`'s
> xcargs); a manual dispatch keeps `project.yml`'s default version and only bumps
> the build number (`github.run_number`). Export compliance is pre-answered
> (`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO` in `project.yml`) so uploads
> aren't gated behind "Missing Compliance." `upload_to_testflight` uses
> `skip_waiting_for_build_processing`, so a green run means *uploaded*, not yet
> *processed* — the build appears in TestFlight a few minutes later.

## Why native (not a wrapper)

The PWA hits real iOS ceilings: IndexedDB can be **evicted under storage
pressure** (data loss for a work-hours record), no reliable local notifications,
no home-screen widgets, no direct Apple Calendar writes, and the quarter-hour
`<select>` workaround. SwiftData gives durable backed-up storage; WidgetKit,
UserNotifications, and EventKit give the rest.

## Stack & target

- Swift + SwiftUI, **iOS 17+**.
- **SwiftData** for persistence (App Group container, reserved id
  `group.com.thegrandpipeline.timecard`, enabled when widgets land).
- Swift Charts (metrics), WidgetKit (later), UserNotifications, EventKit, haptics.
- XcodeGen for the project; Swift Package Manager for deps (keep ~zero). No
  WebView, no CocoaPods.

## Architecture — strict downward-only layering

Dependency arrows point **down only**. The point is to isolate correctness from
UI so the app can evolve without endangering the time math.

1. **`Domain/`** — pure Swift value types + pure functions. Port of `time.js` /
   `calendar.js`. **No SwiftData, no SwiftUI.** Fully unit-tested. This is the
   "preserved future" — guard it. Never import SwiftUI/SwiftData here.
2. **`Store/`** — SwiftData `@Model` types + repositories mirroring the PWA's
   `DB.*`. Maps stored models ↔ domain value types. CSV/.ics live here.
3. **`Features/`** — SwiftUI views + Observation view models, feature-foldered
   (Period, Day, Metrics, Settings, Schedule; Calendar later). Views are dumb.
4. **`Platform/`** — thin adapters: WidgetKit bridge, notifications, EventKit,
   haptics, share/file.
5. **`App/`** — `@main`, app state, enum-driven routing.

## Folder layout

Sources live **directly under `iOS/`** (the standalone repo was flattened into
the monorepo). When adding a new top-level source folder (Store/Features/
Platform), also add it to `project.yml` → `targets.Timecard.sources`.

```
iOS/                       # the Timecard iOS app; XcodeGen project root
  project.yml              # XcodeGen spec (source of truth for the .xcodeproj)
  App/                     # TimecardApp, RootView, AppRoute, FeatureFlags
  Domain/                  # Constants, LocalDate, Formatting, EntryMath,
                           #   PayPeriod, Overtime, Pace, Holidays, Ics (+ later: Recurrence, EventsIcs, Lanes)
  Store/                   # SwiftData models + repositories (Phase 2)
  Features/                # SwiftUI features (Phase 3+)
  Platform/                # widgets, notifications, EventKit, haptics (later)
  Resources/Assets.xcassets
  TimecardTests/           # unit tests — Domain first
  fastlane/  docs/  Gemfile  # CI/CD config (workflows: repo-root .github/workflows/ios-*.yml)
```

## Domain port conventions (read before touching `Domain/`)

- **The PWA is the oracle.** Port behavior exactly; pin it with a test. When in
  doubt, re-read `../time.js` (and `../calendar.js`), checked against `../LOGIC-FREEZE.md`.
- **Dates are calendar-day math, never millisecond division.** The JS used a
  `Math.round((a-b)/MS_PER_DAY)` workaround to dodge DST drift; Swift uses
  `Calendar.dateComponents([.day], …)` which is inherently DST-safe. All
  period/day arithmetic goes through helpers in `LocalDate.swift`
  (`daysBetween`, `addDays`, `parseLocalDate`, `floorDiv`/`ceilDiv`). **Do not**
  divide time intervals to count days.
- **`floorDiv`/`ceilDiv`** exist because Swift integer `/` truncates toward zero
  while JS `Math.floor`/`Math.ceil` round toward ±∞ — required for correct
  negative-offset period math.
- **`DomainCalendar.shared`** is a settable gregorian `Calendar` (defaults to
  `.current`). Tests pin its `timeZone` for deterministic DST cases. Domain
  functions also accept an explicit `calendar:` param (defaulted) so they stay
  pure/injectable.
- **`dow0`** returns JS-style day-of-week (0=Sun..6=Sat), since the holiday rules
  were written against `Date.getDay()`.
- Entry duration uses **absolute elapsed time** (`timeIntervalSince`), matching
  the JS `(end-start)/MS_PER_HOUR`, so an entry spanning a DST change shifts by
  an hour exactly as the PWA does (intended).

## Domain invariants to preserve (each has / needs a test)

Rounding to 15 min; lunch −0.5h at span ≥4h (explicit `lunchMinutes` overrides);
forgotten clock-out >16h → incomplete/0h; **8h-mode OT** = `max(0, worked −
scheduled)` ungated (weekends 0 scheduled → all OT); holidays OPM + observed
(Sat→Fri/Sun→Mon), worked-holiday pays 2×; period naming `YYYY-PPNN`, paydate =
end+12d, **YTD bucketed by paydate year**; pace expected `80*(N+1)/14`, ±2h
deadband. Multipliers: OT 1.5×, holiday 2×.

> **Maxiflex OT + credit hours is CANONICAL in `../LOGIC-FREEZE.md` §4
> (revision F2)** — the safe, change-able home for the math. In short: leave
> counts toward the 80 gate, leave fills the daily schedule, and each entry's
> `payKind` routes its beyond-schedule/over-80 hours to OT or banked credit.
> `Domain/PeriodTotals.swift` implements it; pin every change to §4's scenario
> table (S1–S6) with tests. **Do not edit the OT rule without updating §4 first.**

Verified parity examples (in `TimecardTests`): anchor `2026-04-19` →
`2026-PP08`; period ending `2025-12-27` → `2025-PP25`, paydate `2026-01-08`
(year 2026).

## Roadmap (full checklists in the plan file)

- **Phase 0 — Scaffold** ✅ — project, XcodeGen, app shell.
- **Phase 1 — Domain port** ✅ (timecard) — `time.js` ported + tests, green on
  iOS CI. (`calendar.js` is intentionally excluded from the sellable MVP.)
- **Phase 2 — Store + CSV bridge** ✅ — `Store/`: SwiftData models
  (`StoredEntry` / `StoredLeave` / `StoredSetting`, CloudKit-shaped — defaulted
  props, no `.unique`), a `@MainActor` `TimecardStore` repository mirroring
  `DB.*` (entries/leave/typed-settings/default-schedule), and a **pure** CSV
  codec (`CsvBackup` + `BackupData`) that round-trips the four timecard sections
  (SETTINGS, DEFAULT_SCHEDULE, ENTRIES, LEAVE) of a PWA backup — calendar
  sections are skipped, not errors. Settings persist as PWA-compatible JSON
  (`SettingsCodec`). Wipe-and-restore import preserves local-only keys.
  **CSV backup/restore UI ✅** — a **Backup** section in Settings: Export via
  `.fileExporter` (`CsvBackupDocument` wrapping `store.exportCsv()`) and Import
  via `.fileImporter` → `SettingsViewModel.importCsv(from:)` → `store.importCsv`
  (then `reloadFromStore()` + reminder reschedule). The codec was already tested
  (`CsvBackupTests`/`TimecardStoreTests`); this only surfaces it.
- **Phase 3 — Timecard UI** ✅ — `PeriodView` (14-day period list with header
  stat strip + prev/next), **Day editor** (`Features/Day`: summary, clock in/out
  with the 16h-forgotten rule, entry list, add/edit/delete via the quarter-hour
  `EntryEditView`, leave stepper), and **Settings** (`Features/Settings`: anchor
  [Sunday-validated], default OT mode, hourly rate, 24h time, 14-slot default-
  schedule editor). Pure helpers in `Domain/EntryEditing.swift` (autoLunch,
  clock↔minutes, open/forgotten scan) + a reusable `QuarterHourPicker` (discrete
  menus, not a 1-minute wheel). **Lunch is editable** in `EntryEditView`: a Lunch
  stepper (0–180, 15-min steps) defaults to the auto value (≥4h → 30) and tracks
  the picked span live for a new entry until the user overrides it (an existing
  entry's stored lunch is respected); `saveEntry` persists the chosen value
  verbatim. Mirrors the PWA (auto-computes but editable). Green-before-merge on
  iOS CI (#46/#48).
  **Schedule apply ✅** — `TimecardStore.applyDefaultSchedule` seeds work entries +
  recurring leave into ~a year of upcoming periods (PWA overwrite semantics:
  enabled slot → one `fromDefault` entry replacing existing ones on that date;
  holiday → drop fromDefault + ensure 8h leave; `leaveHours>0` → seed leave). The
  schedule editor has a **"Save & apply to upcoming periods"** button + an
  **Include current period** toggle, overwrite confirmation, and a no-anchor
  guard. (Edits autosave the *definition*; Apply does the *seeding*.)
- **Phase 4 — Metrics + timeline interaction** — Swift Charts; drag-to-resize.
  *In progress:* Metrics tab v1 (`Features/Metrics`) — hero + stats grid + a
  daily-hours stacked bar chart for the current period, plus YTD hours / OT $
  (paydate-year bucketed via `Domain/Metrics.swift`).
  **Timeline dragger ✅** (the PWA's signature interaction, prioritized): the
  scale math is ported pure + tested in `Domain/TimelineScale.swift` (non-linear
  9:00–2:30 core-compression `minToPct`/`pctToMin`, snap/clamp/`resolveHandleDrag`,
  `otSegments`/`leaveSegment`, shared `fitScale`/`expandedScale`). The view is
  `Features/Day/DayTimelineView.swift` — an inline draggable strip on every day of
  the **pay-period view** (`PeriodView`) AND in the **Day editor** (`DayView`),
  all 14 days sharing one expand-only-during-drag scale (owned by the view
  models). Faithful to the PWA: grab-offset (handle doesn't jump), lunch
  **preserved** on drag, in-progress entries get an end handle (drag = clock-out),
  tap opens the editor. Native upgrades: haptic snap ticks + release thump
  (`.sensoryFeedback`), whole-bar move, spring handle, Reduce-Motion-aware OT
  shimmer. ⚠️ Gestures are NOT exercised by CI — needs a device/simulator pass.
  **Slider UI/UX polish (mirrors PWA v27):** thinner bars/handles
  (`barHeight` 18→12, `handleSize` 14→11), **leave bar moved in line with the
  work band** (`leaveMidY = barMidY`, full height — was a thin strip below), and
  **edge auto-expand** — a background `Task` loop (`updateAuto`/`autoStep`/
  `stopAuto`) advances the drag one snap-tick every ~90 ms while a handle is held
  within `edgeZone` (36 pt) of a strip edge, so the scale grows without the user
  having to jiggle the finger (SwiftUI `DragGesture.onChanged` only fires on
  movement). Faithful to the PWA's requestAnimationFrame edge loop.
  **Metrics second chart ✅** — mode-dependent like the PWA: 8h mode shows the
  recent-OT bar chart with a persisted `8 PP | YTD | 6 mo | 1 yr` range selector
  (`metricsRange`); Maxiflex shows the cumulative-pace line (actual vs ideal
  dashed vs the 80h target rule). Pure data in `Domain/Metrics.swift`
  (`MetricsRange`, `OtBar`, `PacePoint`, `periodStartsWithData`, `selectRange`,
  `paceIdealSeries`/`paceActualSeries`; tested in `MetricsTests`), Swift Charts
  in `MetricsView`. **Deferred:** tap-a-bar-to-jump-to-that-period — needs a
  shared cross-tab selection (the `TabView` has no selection binding and
  `PeriodView` owns its viewed period), a routing change beyond data parity.
  **Draggable default-schedule strip (mirrors PWA `buildScheduleStrip`):** the
  schedule editor (`Features/Settings/ScheduleEditorView`) replaced the
  per-row `QuarterHourPicker`s with `ScheduleStripView` — a slot-driven
  draggable strip (two handles, time pills, haptic snap ticks, edge auto-expand)
  that also **draws the slot's recurring leave as a teal segment** (right of the
  work bar on an enabled day, anchored left for a pure-leave off day) so it's
  obvious which day the leave belongs to. Reuses the pure `TimelineScale` math;
  `ScheduleViewModel` now owns a shared `timelineScale` (`refitScale`/
  `expandScale`) across all 14 rows. The leave `Stepper` + a read-only exact-time
  caption remain. ⚠️ Gestures NOT exercised by CI — needs a device pass.
- **Phase 5 — Calendar mode** ✅ (core) — events ported from `calendar.js`:
  `Domain/CalEvent.swift` (value type + `EventColor` palette),
  `Domain/Recurrence.swift` (the RRULE engine: parse/format/expand/expandSeries +
  `stackEvents` lane packing), `Domain/EventsIcs.swift` (RFC-5545 build/parse).
  `Store/StoredEvent` + `TimecardStore+Events` (CRUD, `resolveEvents(forDays:)`
  expanding series on read, backlog, exdates). `Features/Calendar/` —
  `CalendarView` (pay-period-aligned event list, add/edit, recurring this-vs-all
  delete) + `EventEditView`. A **Calendar tab** is in `RootView`. *Deferred:*
  timeline lane rendering / drag, "this & following" recurrence split, backlog
  date-scheduling UI polish, CSV EVENTS section.
- **Phase 6 — EventKit two-way sync** ✅ — `Platform/EventKitSync.swift`: requests
  full calendar access (iOS 17 `requestFullAccessToEvents`), lists writable
  calendars (**Google** calendars surface here once added in iOS Settings — no
  OAuth/server needed; the device account does the Google talking), and runs a
  two-way sync reconciled by `externalId` = `EKEvent.eventIdentifier` with an
  `externalUpdated` anti-churn stamp (mirrors the PWA's `googleSyncNow`). Push
  local→device (insert new → store id; patch when locally changed), pull
  device→local (skip unchanged; tombstone remote-deleted plain rows), RRULE ↔
  `EKRecurrenceRule` mapping. Controls live in **Settings › Calendar sync**
  (connect, pick calendar, sync now) and the Calendar tab toolbar. Info.plist
  usage strings added in `project.yml`. *Deferred (as in the PWA):* pushing local
  deletions, recurrence-override push; recurring pull anchors to the first
  in-window occurrence. **Notifications/haptics/ShareLink remain for later.**
  **Work-schedule sync (v35, off by default):** a separate one-way push of the
  default work schedule onto a chosen calendar (may differ from the events
  target), bounded to a rolling forward window of `scheduleSyncPeriodsAhead`
  whole pay periods (default 2). Pure materializer `Domain/ScheduleSync.swift`
  (`buildScheduleSyncItems` — plain non-recurring items, not RRULE; holidays
  override to an all-day "Holiday"); `EventKitSync.syncSchedule` reconciles via a
  local-only `scheduleSyncMap` (insert/patch-by-sig/delete-out-of-window) and is
  folded into `sync()`. Settings keys `scheduleSyncEnabled`/`…CalendarId`/`…
  PeriodsAhead` (local-only) drive a **Settings › Work schedule sync** section.
  User-added events still sync for all time; only the schedule is windowed.
  Tests: `ScheduleSyncTests`.
  **Schedule sync now reflects ACTUAL hours (fix, 2026-07):** `buildScheduleSyncItems`
  no longer materializes the raw default schedule. `EventKitSync.gatherActualSchedule`
  reads real entries + leave over the window; a day with any recorded entries or
  leave is **touched** → its actual worked blocks (one `w:<date>`/`w:<date>#n` item
  per entry) and actual leave sync, so a leave-only / day-off day shows leave, not
  the default shift. **Untouched** days still fall back to the default-schedule slot
  (an unapplied schedule keeps syncing). Leave display (both apps' intent): leave
  **≥ 8h with no work → all-day** "Leave (Nh)"; otherwise a **timed** block at its
  actual placement (explicit `startMin`, else after the last work block, else the
  scheduled start) — so a 1h leave is no longer an all-day event. Holidays still
  override to an all-day "Holiday". A `scheduleSyncLeave` setting (default **on**)
  can drop leave from the sync entirely, and `scheduleSyncLeaveCalendarId` routes
  leave items to a **separate calendar** — the only way to color leave differently
  from work, since EventKit can't set a per-event color (an event takes its
  calendar's color; work vs leave on one calendar are the same color). `ScheduleItem`
  gained `isLeave` (routes the target) and the reconciliation sig now includes the
  target calendar id (moving a calendar patch-moves the event). **PWA parity TODO:**
  the PWA's `buildScheduleSyncEvents` still materializes the default schedule — mirror
  this actual-hours fix there. Needs a device pass (EventKit not CI-testable).
- **Phase 7 — Widgets, polish, ship** — WidgetKit, onboarding, App Store.
  **Local notifications ✅ (first native bet):** pure `Domain/ReminderSchedule.swift`
  (`buildReminders` → `[ReminderSpec]` for the validation-deadline nudge, a
  period-ending "you're N h short of 80" heads-up the day before, and a
  forgotten-clock-out reminder 9h after clock-in) + tests
  (`ReminderScheduleTests`). Thin `Platform/Reminders.swift` (`ReminderScheduler`):
  `requestAuthorization`/`reschedule`/`refresh(store:)` over
  `UNUserNotificationCenter` (stable per-kind ids → no dupes; no entitlement
  needed). A **Reminders** toggle in Settings (`store.remindersEnabled`, default
  off) requests auth + schedules; rescheduled on launch/foreground (`RootView`
  scenePhase) and after clock in/out (`DayViewModel`).
  **Clock App Intents ✅ (second native bet — Control + App Intent):**
  store-level clock logic is now the single source of truth —
  `TimecardStore.clockIn`/`clockOut`/`toggleClock`/`openEntryToday`/
  `isClockedInToday` (`ClockOutcome` enum); `DayViewModel` delegates to it (tests
  in `TimecardStoreTests`). `Platform/ClockIntents.swift` exposes `ClockInIntent`,
  `ClockOutIntent`, `ToggleClockIntent` + a `TimecardShortcuts` AppShortcutsProvider
  → "Clock in/out with Timecard" via Siri & Shortcuts. Intents run in the app
  process against `TimecardStore.sharedContainer` (a new process-wide container
  the app scene also uses), so a Siri clock shows up in-app; each refreshes
  reminders. **Deferred:** the Control Center *tile* itself — a `ControlWidget`
  needs a widget-extension target + the App Group entitlement + its own match
  provisioning profile (a new App ID to register), so it's a separate PR with a
  Mac/device pass. These intents are exactly what that tile will invoke.
  WidgetKit/Live Activity still TODO.

> **Edition note (owner decision):** calendar mode + EventKit sync ship in the
> **production** build here (NOT gated behind `PERSONAL`), per an explicit owner
> choice. At **runtime** they're gated behind a sticky **Calendar mode** toggle in
> Settings (`@AppStorage("calendarMode")`, default **off**) — mirroring the PWA's
> `calendarMode` setting: timecard mode is the calm, work-shareable default, and
> flipping the toggle reveals the Calendar tab + the Settings calendar-sync
> section. `RootView` / `SettingsView` read the same key. This departs from the earlier "calendar is Personal-only / keep dormant
> code out of the reviewable App Store build" guidance in `../CLAUDE.md` — revisit
> the App-Store-compliance / FTC-privacy-claim notes in `research/` before
> submitting, since a shipped calendar/Google sync changes the privacy story.

## PWA → iOS parity (READ FIRST in a new session)

The native app is **not yet at full PWA feature parity**. This is the live punch
list (audited 2026-06 against the PWA). The **dragger is the protected centerpiece**
— most users live in the pay-period view dragging entries; keep it faithful + fast.

**At parity (done):** clock in/out (15-min round, auto-lunch, 16h-forgotten),
manual entries, **editable lunch** (auto default, override sticks), per-day leave,
OT math both modes, holidays/pace/period-naming/YTD math, Metrics v1, the
**timeline dragger** (pay-period view + Day editor, grab-offset, in-progress
drag-out, haptics, whole-bar move), **default-schedule Save & apply**, CSV
*codec*, EventKit calendar sync, **Week 1 / Week 2 swipe carousel**, **per-period OT
control**, **holiday controls + auto-seeding**, **validation-deadline cue**,
**leave-counts-toward-80 + leave-fills-schedule**, **per-entry OT/credit
classification (`payKind`)**.

**Functional batch (done 2026-06):**
- **Week 1 / Week 2 swipe carousel** — `PeriodView`'s body is a
  `TabView(.page)` paging between two full-week pages (each carries the
  period-level header so the whole screen slides as a unit, like the PWA's
  scroll-snap carousel). Bound to `PeriodViewModel.weekPage`; each page renders
  `weekRows(_ page:)`. The old segmented `Week 1 / Week 2` control was dropped —
  swipe is primary, with tappable page dots + a "Week N" label as the secondary
  jump affordance and position indicator, plus a `.sensoryFeedback(.selection)`
  tick on flip. Launch lands on whichever week contains today (mirrors the PWA's
  boot `viewedPage` pick). The shared timeline scale is still fit over all 14
  days so bars stay comparable across weeks. **Gesture note:** the page swipe and
  the signature timeline drag coexist because the strip's handle gestures use a
  1pt `minimumDistance` (below the scroll slop), so a drag starting on a handle
  wins — the same touch-target disambiguation the PWA relies on. ⚠️ Needs a
  device pass (CI can't drive touches).
- **Day-actions expand panel (tap-to-expand, both modes)** — tapping a day card
  (its header chevron OR the timeline strip) now **expands it in place** instead
  of silently opening the full editor (the old strip `onTap` → `openDate` was a
  confusing invisible hit area). `DayActionsPanel`
  (`Features/Period/DayActionsPanel.swift`) surfaces explicit, labeled actions:
  quick **leave +/−** (`PeriodViewModel.adjustLeave(on:deltaMinutes:)` →
  `store.setLeave(minutes:)`, 0…24h — the per-day-leave parity item. `LeaveStepper`
  is a glass pill `−  N  +` whose **center number is a button** (`LeaveNumberGlass`,
  affordance "D" — a subtle raised glass capsule): tap it to switch THAT day
  between **whole hours** (integer, ±1 h) and **quarter hours** (two-decimal like
  `1.25`, ±0.25 h); switching back to whole **rounds that day** to the nearest
  hour. Precision is per-day, ephemeral `@State fine` (starts fine when the value
  isn't on the hour). This **replaced** the old global `leaveGranularMinutes`
  "15-minute steps" toggle (removed from the Day editor) and the `1:15` clock
  labels — leave now reads as **decimal hours everywhere** (`leaveLabel` →
  integer when whole, else 2 decimals). The store's `leaveGranularMinutes` key
  still exists for CSV round-trip but no longer drives the UI), an **Open
  day editor** badge, and in calendar mode **Add event** + the read-only event
  mini-timeline (`DayEventStrip`, whose own "Add event" button was removed — it's
  now a panel badge). `PeriodView.toggleExpand` drives `expandedDate` (one open at
  a time); the day header chevron shows in both modes. The strip's drag handles
  still edit entries directly (separate gestures) — tap = expand, drag = edit.
  Styled with **Apple Liquid Glass** (iOS 26 `.buttonStyle(.glass)` /
  `GlassEffectContainer` / `.glassEffect`) gated behind `#available(iOS 26.0, *)`
  with a `.ultraThinMaterial` / `.bordered` fallback (deployment target is iOS
  17). Shared glass building blocks live in **`Features/LiquidGlass.swift`**
  (`GlassGroup`, `GlassRowBackground`, `GlassChipButton`/`.glassChip(tint:)`,
  and a reusable `LeaveStepper`). The **whole Period page** got the glass pass:
  the day-card + header `List` rows use `GlassRowBackground` over a hidden
  `.scrollContentBackground`, and the prev/next nav chevrons are glass chips.
  **Per-day leave** is a teal `LeaveStepper` — a **compact** inline +/− on the
  collapsed row (the previous leave *badge*), and the full-size glass form in the
  expand panel (the old coffee/`cup.and.saucer` icon was dropped). ⚠️ Needs a
  device pass — the page-wide glass restyle (hidden List background + per-row
  glass) + gestures (collapsed +/− vs row-tap-to-expand vs handle-drag) can't be
  verified by CI. **Day-row total** shows `countedHours` = worked + leave (leave
  counts toward the 80), not worked alone. The day timeline's full-width baseline
  rule was removed (ticks/labels carry the axis). The expand panel's leave label
  + stepper are one centered control.
- **Per-period OT control** — a `Maxiflex / 8-hour OT` segmented control in the
  header writes `overtimeModeOverrides` (`Store/TimecardStore+Overrides.swift`:
  `overtimeModeOverrides`/`otMode(forPeriodStart:)`/`setOvertimeMode(...)`, which
  *clears* an override when it equals the default). `resolveOtMode` is the pure
  resolver (`Domain/OvertimeMode.swift`). Switching off OT that would erase hours
  routes through an OT-erasure confirmation alert (`requestOtMode` →
  `pendingModeChange` → `confirmPendingModeChange`). `PeriodViewModel`,
  `DayViewModel`, and `MetricsViewModel` (incl. the YTD loop) all resolve the
  per-period mode now, not the global default.
- **Holiday controls + auto-seeding** — Day editor gains a Holiday section (mark
  holiday / remove / "worked → 2×"); store methods `markHoliday`/`removeHoliday`
  (tombstone)/`setHolidayWorked`/`ensureHolidaysSeeded` (auto-records federal
  holidays in a ±-year window on launch from `PeriodViewModel.init`). `holidays()`
  now correctly skips `{removed:true}` tombstones; `holidaySet()` feeds Apply.
  Period day cards show a pink holiday tag.
- **Validation-deadline cue** — Settings picker (`validationDay` setting, day-of-
  period index 0..13) → the deadline day card gets a warning-colored left border
  + a ✓ seal.

## Overtime + credit hours — runbook (READ before touching OT)

**The math lives in `../LOGIC-FREEZE.md` §4 (revision F2).** That is the
authoritative, change-able home; the engines must match it. **Never change the OT
rule without editing §4 first**, then both engines + tests.

**Built (iOS, PR #66 — Phase 1):**
- `Domain/EntryRecord.swift` — `enum PayKind { auto, autoCredit, overtime,
  credit, regular }`; entry stores `payKind` (legacy `isOvertime` is a computed
  bridge, migrated on read).
- `Domain/PeriodTotals.swift` — the engine (§4.3): per-day `splitMaxiflexDay`
  allocates each day's beyond-cushion hours latest-first per `payKind` (forced
  OT/credit sit on top of the schedule, no double-count), then a period pass
  **caps auto premium at the hours over 80** (`max(0, worked+leave−80)`),
  latest-first. Returns `credit`/`creditByDate`. Leave-in-80 +
  leave-fills-schedule already in.
- `Store` — `StoredEntry.payKind` (+ legacy `isOvertime` kept in sync, migrated);
  CSV gains a `PayKind` column (older exports fall back to the Overtime flag);
  `TimecardStore+Overrides.creditDefault(forPeriodStart:)`/`setCreditDefault(...)`
  is the per-period flex-default store hook.
- UI — entry editor (`Features/Day/DayView.swift`) has a pay-classification
  Picker + per-option tooltip; rows tag OT (orange)/Credit (purple); new entries
  default to `DayViewModel.newEntryDefaultKind` (the period's credit-default).
- Tests — `TimecardTests/PeriodTotalsTests.swift` covers auto→OT, autoCredit→
  credit (no $), regular→none, overtime→force, over-80 gate, S1–S6 leave cases.

**TODO — finish this feature, in order:**
1. ~~**Period flex-default toggle UI**~~ DONE — `PeriodView`'s header shows an
   **Overtime / Credit** segmented control **only in Maxiflex mode**, bound to
   `PeriodViewModel.creditDefault` / `setCreditDefault(_:)` →
   `store.creditDefault(forPeriodStart:)`. A caption under it explains it routes
   only NEW entries' beyond-schedule hours (existing entries untouched).
2. ~~**Surface credit hours**~~ DONE — a purple **credit** stat in the period
   header stat strip (`totals.credit > 0`), a **Credit hours** row in Metrics
   (current period + YTD, paydate-bucketed via `MetricsViewModel.credit`/
   `ytdCredit`), and a purple **Credit** segment in the daily-hours chart
   (`DayBar.credit`, split out of regular; pinned by a `MetricsTests` case).
3. ~~**PWA mirror**~~ DONE (v29) — `app.js` `periodTotals` runs the same
   `splitMaxiflexDay` + over-80 cap (returns `credit`/`creditByDate`);
   `T.payKindForEntry` bridges legacy `isOvertime`; entry-modal **Pay
   classification** select; per-period **Overtime | Credit** control
   (`creditDefaultOverrides`); credit in the stat strip + Metrics + entry tag;
   CSV `PayKind` column; SW cache → `timecard-v54`.
4. **Phase 2 — credit-hour banking** (§4.6): ~~balance + 24h cap + spend~~ DONE
   (both apps). Pure `Domain/CreditBank.swift` (`creditBankFold`/`creditBankSlot`,
   cap `TimeConstants.creditCarryoverCap`) folds each period's `earned` − `used`
   credit into a running balance, capping the carryover at 24h (PWA mirror:
   `T.creditBankFold`/`creditBankSlot`). `MetricsViewModel.reloadCreditBank` reads
   off the current period's slot and the **Credit-hour bank** Metrics section
   shows balance + spent + an over-cap forfeiture warning. **Spend:** a "Use
   credit hours" stepper in the Day editor (`store.creditUsed` map, the inward
   mirror of leave) draws the balance down. Gated behind `creditHoursEnabled`.
   Tests: `CreditBankTests`.

**Master switch (default OFF):** `store.creditHoursEnabled` (Settings ›
Overtime) gates the WHOLE feature. When off, `periodTotals(creditEnabled:false)`
collapses `autoCredit`→`auto` and `credit`→`overtime` (extra hours all pay OT,
`credit` always 0) and every credit surface hides — the per-period
Overtime|Credit control (`PeriodViewModel.showsCreditControl`), credit stats,
Metrics credit, and the entry editor's classification Picker (reverts to a plain
`Toggle("Overtime")` via `overtimeBinding`; no Credit row tags). Stored
`payKind`s are untouched, so it's non-destructive. Mirrors the PWA's
`creditHoursEnabled` / `effectivePayKind`.

**Invariants to keep:** leave never pays a premium; toggling the period default
**never** reclassifies existing entries (classification is stored per entry);
8-hour mode ignores `payKind` entirely; `periodTotals` stays the only OT/credit
authority.

**Selectable color themes ✅ (PWA parity for v37's theme menu).** A
`Features/Theme/Theme.swift` defines `AppTheme` (classic / pacific / sunset /
clarity / sage / midnight) + a `Palette` value type holding the semantic **data**
colors (work / personal / ritza / amelia / leave / ot / otDeep / holiday /
credit / accent / success / warning / danger) and derived bar gradients
(`workGradient`/`otGradient`/`inProgressGradient` via per-trait `lightened`/
`darkened`). **Classic** maps to the app's existing system colors (`.blue`/
`.orange`/`.teal`/…), so the default is unchanged; the other five supply explicit
light+dark hexes resolved per-trait by `Color(light:dark:)` (a dynamic `UIColor`),
so OS dark mode still works per theme — mirrors the PWA palettes. The palette is
injected at `RootView` via `@AppStorage("appTheme")` → `.environment(\.palette,)`
+ `.tint()`; every color site reads `@Environment(\.palette)` (no more scattered
`.blue`/`.orange`), and `eventColor` became `palette.eventColor(_:)`. Settings ›
**Appearance** is a `.navigationLink` `Picker` of swatch rows (`ThemeRow`).
**Themed backgrounds (so themes actually look different).** Data-color-only
theming read as "nearly identical" because every theme sat on the same
system-black/white background with same-hue-family roles. Each `Palette` now also
carries `background`/`backgroundElevated` + a `backgroundView` (a diagonal
gradient + faint accent/leave radial glows for depth). `RootView` applies it once
— `.scrollContentBackground(.hidden)` (propagates to every List/Form) +
`.background { theme.palette.backgroundView.ignoresSafeArea() }` — so the whole
app carries the theme's hue and the glass cards refract a colorful backdrop;
`GlassRowBackground` adds a 7%-accent glass tint (themed only). **Classic** sets
`themed: false` → `backgroundView` returns the plain system grouped background
(native, unchanged). Persisted via `@AppStorage`; CSV round-trip of the `theme`
key is a possible later add.

**Theme catalog v2 — bolder + categories + Moments.** `AppTheme` grew a
`Category` (Everyday · Classic · Muted · Moments) and an `emoji`. The muted
originals (Pacific/Sunset/Clarity/Sage/Midnight) moved under **Muted**; new
**Everyday** bolds — **Daylight** (true light), **Aurora** (neon), **Mono**
(max-contrast), **Sunrise** (warm light); new **Moments** event themes —
**Independence Day** 🎆, **Halloween** 🎃, **Pride** 🏳️‍🌈, **World Cup** ⚽️ (each a
full palette, manually selectable for now). The Settings "Theme" row pushes a
`ThemePickerView` (a `List` sectioned by `Category` with a check on the active
one) instead of the flat inline Picker. **Appearance override:** a new
`@AppStorage("appearance")` (system/light/dark) drives `RootView`'s
`.preferredColorScheme` so a theme can be forced light/dark regardless of the OS
(the "real light mode" ask). **Deferred (wanted):** an **auto-picker** that
temporarily surfaces a Moment during its window — date-based (Jul 4 / Halloween /
Pride) is cheap; the **sports** version (World Cup match-day → the two nations'
flag colors) needs a live fixtures feed and is a follow-up — architect
`currentMoment(date)` / effective-theme as the hook.

**Liquid-Glass styling of the themed colors.** The palette colors don't render as
flat fills — they go through `LiquidGlass.swift` so they read as translucent,
tinted glass with real sheen: `tintedGlass(_:in:strength:)` (iOS 26
`glassEffect(.regular.tint(…).interactive())`; fallback = `.ultraThinMaterial` +
tinted gradient + hairline stroke) backs the period/day **stat chips** and the
**OT / Credit / holiday tags**, and `glassGloss()` lays a specular top-down
highlight over the **timeline work/OT/leave bars** for the wet-glass look. Both
modifiers live in `LiquidGlass.swift` next to the existing glass building blocks.

**Build gotcha fixed:** the first theme PR merged with a broken build —
`Section("Appearance") { … } footer: { … }` is not a valid `Section` initializer
(no titled-section-with-footer overload), which produced a misleading
`Cannot convert 'String' to '() -> Content'`. The hint moved inline as a
`.caption` `Text` inside the titled section (the pattern the Overtime section
already uses). Lesson: a titled `Section` takes content only — use a header/footer
*closure* form or an inline caption, never `Section("…") { } footer: { }`.

**Not yet built — PWA features still missing (the parity gaps):**
- **Calendar event drag / quick-add on the timeline** — the PWA's drag-to-move
  + edge quick-add for events. (The **tiered event overlay + expand-in-place** is
  now built — see "Multi-calendar timeline" below; drag/quick-add of events on the
  work strip is still deferred.)

> **Multi-calendar timeline + tasks — BUILT (this PR).** Generalized the fixed
> four-token color model (work/personal/ritza/amelia) into a **per-device-calendar
> registry** so events render on the Period timeline like the PWA's `buildCalLanes`,
> in **three tiers** relative to the work bar: `.above` (partner / other calendars,
> overlapping above), `.on` ("my time" — work/personal on the bar), `.below`
> (**tasks**, overlapping below). Pieces:
> - **Domain (pure, tested):** `CalEvent.calendarId` (the owning `EKCalendar`),
>   `CalendarConfig`/`CalendarTier` (color override + device color + tier +
>   `showOnTimeline` + `synced` + `isTaskDefault`; `defaultTier(forTitle:)`),
>   `layoutDayEvents` (3-tier lane packing reusing `stackEvents`). Tests:
>   `CalendarLayoutTests`, `CalendarRegistryTests`.
> - **Store:** `StoredEvent.calendarId`; `TimecardStore+Calendars` registry
>   (`calendarConfigs` local-only setting) with `tier(forEvent:)` / `colorHex(forEvent:)`
>   / `hiddenFromTimeline(_:)` / `syncedCalendarIds()` / `taskCalendarId()`, falling
>   back to the legacy single `eventKitCalendarId` when no registry exists.
> - **Platform:** `EventKitSync` now syncs **multiple** calendars — pull queries all
>   synced calendars and stamps each event's `calendarId`; push routes each event to
>   its own (writable) calendar; `CalendarInfo` gained `colorHex`/`isWritable` +
>   `allCalendars()`. De-syncing a calendar no longer deletes its rows.
> - **Features:** `DayTimelineEventsOverlay` (non-interactive tiered pips over the
>   day strip — collapsed indicator), `DayEventStrip` reorganized into tiers w/ names
>   (expanded), an **Add task** chip in `DayActionsPanel`, a **Calendar** picker in
>   `EventEditView`, and **Settings › Calendars** (`CalendarsView`/`CalendarsViewModel`)
>   to set per-calendar color / tier / timeline-visibility / task-default.
> - **Assumptions (owner can redirect):** calendars = real EventKit calendars;
>   tasks = events on a `.tasks`-tier calendar (not EKReminders); colors default to
>   the device calendar color, overridable. **Needs a device pass** — the overlay
>   geometry/feel + sync against real multi-calendar accounts (CI can't drive
>   EventKit/rendering).

> **Timeline band model + whole-day-off — BUILT (this PR).** Two fixes to the
> period timeline (the screenshot issues): **(1) leave-only days now draw a bar.**
> Previously a day with no work entries replaced the whole strip with a text
> button, so a deleted-work / leave-only day (and any event on it) showed no bar
> and events fell into the "ON THE LINE" chip list. Now the strip renders whenever
> there are entries **or** leave **or** (calendar mode) events; `leaveSegment`
> gained a `fallbackStartMin` so a leave-only day anchors at the day's **scheduled
> start** and **fills the day** (`PeriodViewModel.DayRow.scheduledStartMin` /
> `leaveFallbackStartMin`, mirrored in `DayViewModel`). A **"Day off"** chip in the
> `DayActionsPanel` (`PeriodViewModel.takeDayOff`) clears the day's work entries and
> sets leave = that day's scheduled hours (8h fallback). **(2) Layered bands.** The
> coarse 3-tier `CalendarTier` (`above`/`on`/`below`) became a layered vertical
> stack — **`mine`** (top half of the bar, translucent over work), **`close`**
> (straddles the bar's top quarter and rises above — a near person), **`others`**
> (fully above), **`tasks`** (below); **leave** moved to the bar's **bottom half**
> on worked days (full height on a pure day off) so work/leave/personal read at
> once. Legacy stored tiers decode via `CalendarTier(stored:)` (`on→mine`,
> `above→others`, `below→tasks`); the Settings › Calendars "Position" picker shows
> the new band labels so the user assigns each calendar a band. **Names are
> provisional** (owner asked me to pick them) — relabel in `CalendarTier.label`.
> Geometry lives in `DayTimelineEventsOverlay.geometry(_:lane:)` + the leave-half
> logic in `DayTimelineView`. **Needs a device pass** — band geometry/feel is not
> CI-testable. "Close extends full width above the bar" was read as a taller
> straddling block at the event's time span (not literally card-width); revisit on
> device if the owner meant full-width.

> **Expanded events → interactive lanes — BUILT (follow-up PR).** The band pips
> (`DayTimelineEventsOverlay`) are now the **collapsed** at-a-glance indicator only.
> On expand, the old bottom `DayEventStrip` tier-list was **removed** and replaced
> by **`DayEventLanesView`**: one **equal-height lane per event** (stacked, touching,
> tall enough for text), each showing the **title**, **tap → open editor**, and
> **hold-then-drag → move the event's time** (15-min snapped, mirrors the leave-bar
> drag; local non-recurring timed events only — all-day / recurring / read-only are
> tap-only). Persisted via `PeriodViewModel.moveEvent`. **The lines expand in place,
> not into one block below:** `PeriodView` renders it as two groups — the above-bar
> bands (all-day, others, close, mine) grow **above** the work strip, tasks grow
> **below** it (ranked via `tierFor` so lanes keep the collapsed band order). The
> work bar + leave stay put in the middle. Positions use the shared `TimelineScale`
> so lanes line up with the work strip. **Needs a device pass** (gestures/rendering
> not CI-testable).

> **Leave drag splits the workday — BUILT (LOGIC-FREEZE §3, revision F3).**
> Dropping the dragged leave block **inside a work entry** now reshapes the day
> around it: strictly-inside → the entry **splits into two entries** (work
> 8:00–4:30 + 2h leave at 9–11 → 8–9 and 11–4:30 = 6h paid, each piece with its
> own drag handles); edge overlap → **trim**; fully covered → **delete**. The
> single lunch deduction rides the piece containing the original lunch-band
> midpoint (longer piece if swallowed); open/incomplete entries are untouched.
> **Heal on move:** re-dragging the block merges the two pieces that exactly
> abut the old span first, so the hole *follows* the leave (edge trims are not
> healed — un-trimming would invent hours). Pure plan in
> `Domain/LeaveSplit.swift` (`leavePlacementPlan`/`healAroundLeave`/
> `applyLeavePlacementPlan`, tests `LeaveSplitTests`); applied by
> `TimecardStore.placeLeave` (both view models' `placeLeave` route through it);
> `DayTimelineView` renders the SAME plan live mid-drag (`previewEntries`) so
> the bar visibly splits under the block before release. **Needs a device pass**
> (drag feel not CI-testable). PWA mirror rides the pending web leave drag.
- **CSV import/export buttons** — the codec round-trips, but there's **no Settings
  UI** (file importer/exporter / ShareLink) to trigger it.
- ~~**Recent-OT chart + range selector** (8PP/YTD/6mo/1yr) and the Maxiflex
  cumulative-pace line — the Metrics 2nd chart. Deferred.~~ DONE (see Metrics
  second chart above). Only **tap-a-bar-to-jump** is still deferred (cross-tab
  routing).
- ~~**Per-day leave +/− on the period cards**~~ DONE — see the day-actions
  expand panel below.
- ~~**Schedule `.ics` export** (`buildScheduleIcs`) — Domain has the builder; no
  Settings button.~~ DONE — Settings **Schedule** section has an "Export schedule
  (.ics)" button → `SettingsViewModel.exportScheduleIcsText()` (anchors
  `buildScheduleIcs` to the current pay period) → `.fileExporter`
  (`IcsScheduleDocument`, dynamic `.ics` UTType). Builder already tested
  (`FormattingTests`).

**Suggested order (owner-confirmable):** ~~Week 1/Week 2 selector → per-period OT
+ holiday UI + validation cue (functional batch)~~ DONE → calendar visual peek →
CSV buttons / metrics 2nd chart → per-day leave +/− on cards → schedule `.ics`.

**Needs an on-device pass (CI can't drive touches):** the dragger feel (incl. the
drag-stick fix), and the schedule **Apply** flow.

Plan file: **`../this-is-the-prompt-magical-duckling 6.21.md`** (the original
2026-06-21 native-rewrite plan, now committed at the repo root). Note it predates
the monorepo move + the "Timecard" rename — treat the phase *intent* as the guide
and this file's phase status above as the live truth.

## Gotchas

- **No `.xcodeproj` in git** — it is generated; edit `project.yml` instead.
- **CI simulator name is not pinned** — `ios-ci.yml` picks an available iPhone
  simulator by UDID (or creates one from the latest runtime + device type) rather
  than hard-coding `iPhone 16`, which a runner/Xcode bump (e.g. Xcode 26.3) can
  drop. If a test job dies with "Unable to find a device matching the destination,"
  that's the cause — fix the selection step, not the tests.
- **CI only validates Domain + Store** (pure logic + the SwiftData repo) — it
  builds the app target so SwiftUI compile errors fail the run, but it **cannot
  exercise gestures/rendering**. Anything UI/feel (the dragger, schedule Apply,
  pickers) must be checked on a device/simulator. Writing Store/Domain blind is
  risky too — e.g. `ScheduleSlot.startMin/endMin` are `Int?`; unwrap them.
- **OneDrive path** — source is fine in OneDrive; build artifacts are gitignored.
  If OneDrive ever locks files mid-build, pause syncing for the folder.
- **Don't let UI/game/feature logic mutate domain truth.** Hours/OT/pay flow one
  way: Domain → everything else.
- **App Group ID is load-bearing** once widgets exist — keep it stable.
