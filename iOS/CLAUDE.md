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
target / scheme / module = **Timecard**, and the bundle id + App Group are now
`com.calebsmith.timecard` too — renamed from the old `…maxiflex` while no Apple
App ID / signing cert existed yet (so it was free); "maxiflex" survives only as
the federal *schedule* term in the Domain layer.

> **Build requires a Mac** (Xcode). This repo is Windows-authored but iOS can
> only compile/run on macOS. The `.xcodeproj` is generated from `project.yml`
> via XcodeGen — see `README.md`.

## Why native (not a wrapper)

The PWA hits real iOS ceilings: IndexedDB can be **evicted under storage
pressure** (data loss for a work-hours record), no reliable local notifications,
no home-screen widgets, no direct Apple Calendar writes, and the quarter-hour
`<select>` workaround. SwiftData gives durable backed-up storage; WidgetKit,
UserNotifications, and EventKit give the rest.

## Stack & target

- Swift + SwiftUI, **iOS 17+**.
- **SwiftData** for persistence (App Group container, reserved id
  `group.com.calebsmith.timecard`, enabled when widgets land).
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
- **Phase 1 — Domain port** 🚧 — `time.js` ported + tests; `calendar.js` next.
- **Phase 2 — Store + CSV bridge** — SwiftData models/repos mirroring `DB.*`;
  6-section CSV import/export (the migration bridge from PWA backups). Build early.
- **Phase 3 — Timecard UI** — period carousel, day editor, clock in/out, entry
  modal (native quarter-hour picker), settings, schedule editor.
- **Phase 4 — Metrics + timeline interaction** — Swift Charts; drag-to-resize.
- **Phase 5 — Calendar mode** — events, RRULE render, editor, drag, backlog, ics.
- **Phase 6 — Native superpowers** — EventKit, notifications, haptics, ShareLink.
- **Phase 7 — Widgets, polish, ship** — WidgetKit, onboarding, App Store.

Plan file: `C:\Users\caleb\.claude\plans\this-is-the-prompt-magical-duckling.md`.

## Gotchas

- **No `.xcodeproj` in git** — it is generated; edit `project.yml` instead.
- **OneDrive path** — source is fine in OneDrive; build artifacts are gitignored.
  If OneDrive ever locks files mid-build, pause syncing for the folder.
- **Don't let UI/game/feature logic mutate domain truth.** Hours/OT/pay flow one
  way: Domain → everything else.
- **App Group ID is load-bearing** once widgets exist — keep it stable.
