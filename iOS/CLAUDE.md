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
scheduled)` ungated (weekends 0 scheduled → all OT); **maxiflex OT** = explicit +
beyond-scheduled, only once period >80h; holidays OPM + observed
(Sat→Fri/Sun→Mon), worked-holiday pays 2×; period naming `YYYY-PPNN`, paydate =
end+12d, **YTD bucketed by paydate year**; pace expected `80*(N+1)/14`, ±2h
deadband. Multipliers: OT 1.5×, holiday 2×.

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
  **Deferred:** auto-*seeding* work entries from the schedule into upcoming
  periods (the PWA's `applyDefaultSchedule`) — schedule edits set scheduled hours
  (which drive OT) but don't yet create entries.
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
  Deferred: the recent-OT / cumulative-pace second chart + range selector.
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
- **Phase 7 — Widgets, polish, ship** — WidgetKit, onboarding, App Store.

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

Plan file: **`../this-is-the-prompt-magical-duckling 6.21.md`** (the original
2026-06-21 native-rewrite plan, now committed at the repo root). Note it predates
the monorepo move + the "Timecard" rename — treat the phase *intent* as the guide
and this file's phase status above as the live truth.

## Gotchas

- **No `.xcodeproj` in git** — it is generated; edit `project.yml` instead.
- **OneDrive path** — source is fine in OneDrive; build artifacts are gitignored.
  If OneDrive ever locks files mid-build, pause syncing for the folder.
- **Don't let UI/game/feature logic mutate domain truth.** Hours/OT/pay flow one
  way: Domain → everything else.
- **App Group ID is load-bearing** once widgets exist — keep it stable.
