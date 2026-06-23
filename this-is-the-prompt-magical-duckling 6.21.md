# Plan: Native iPhone rewrite of the Maxiflex Timecard

## Context

The Maxiflex Timecard is a vanilla-JS PWA (IndexedDB/Dexie, no server, no auth)
that tracks a federal maxiflex biweekly schedule. It works well as a PWA but
hits real iOS ceilings: **IndexedDB can be evicted under storage pressure**
(unacceptable for a work-hours record), **no reliable local notifications**, no
home-screen widgets, no direct Apple Calendar integration, and a faintly
"it's a website" feel (quarter-hour `<select>` workaround, no haptics).

We are transitioning to a **full native iPhone app** (Swift/SwiftUI). This is a
**clean-room rewrite, not a port and not a WebView wrapper** — but it must
**preserve the future of the app**: the hard-won domain logic (two OT modes,
pay-period naming, federal holidays, recurrence engine) is carried forward
faithfully into a clean, tested Swift core, and the still-WIP calendar mode is
architected for from day one even though it ships in a later phase.

The existing PWA stays exactly where it is (`...\Scripts\Timecard App\`, repo
`calebpaulsmith/Timecard-App`, GitHub Pages) and is untouched — it remains the
work-shareable timecard while the native app is built.

### Decisions (defaults chosen; revise if wrong)
- **Scope order:** Timecard parity first → a correct, shippable native timecard.
  Calendar mode (events/RRULE/drag/backlog) is Phase 5, architected-for from
  the start. (Confirm if you'd rather build everything before shipping.)
- **Min target:** **iOS 17+**, so we can use **SwiftData** (the headline
  durability win), modern Swift Charts, and native paging scroll.
- **Project home:** a **fresh folder + git repo**. Working app name **"Maxiflex"**
  (placeholder — rename freely).

### Cleanup of prior-turn artifact
Last turn, under a mistaken "make a game" premise (wrong chat), I created
`C:\Users\caleb\OneDrive\Desktop\Scripts\ChronoForge\CLAUDE.md`. That folder is
**wrong and should be deleted** at the start of execution. The new project will
NOT be a game.

---

## Target stack

| Concern | Choice | Replaces (PWA) |
| --- | --- | --- |
| Language/UI | Swift + SwiftUI (iOS 17+) | HTML/CSS/JS, `app.js` |
| Persistence | **SwiftData** (App Group container) | Dexie/IndexedDB (`db.js`) |
| Charts | Swift Charts | hand-built CSS/SVG charts |
| Widgets | WidgetKit extension | (none possible on iOS PWA) |
| Notifications | UserNotifications | (none reliable on iOS PWA) |
| Calendar | EventKit (Phase 5/6) | `.ics` export workaround |
| Haptics | CoreHaptics / UIFeedbackGenerator | (none) |
| File I/O | `.fileImporter`/`.fileExporter` + ShareLink | browser download |
| Deps | Swift Package Manager, near-zero deps | npm-free already |

No WebView. No build-step JS. No CocoaPods.

---

## Architecture — strict downward-only layering

The whole point is to isolate correctness from UI so the app can evolve without
endangering the time math. Dependency arrows point **down only**.

1. **`Domain/`** — pure Swift value types + pure functions. Port of `time.js`
   and `calendar.js`. **No SwiftData, no SwiftUI.** Fully unit-tested. This is
   the "preserved future" — guard it.
2. **`Store/`** — SwiftData `@Model` types + repositories mirroring `DB.*`.
   Maps stored models ↔ domain value types. CSV/.ics import-export live here.
3. **`Features/`** — SwiftUI views + Observation view models, feature-foldered
   (Period, Day, Metrics, Settings, Schedule; Calendar later). Views are dumb.
4. **`Platform/`** — thin adapters: WidgetKit bridge, notifications, EventKit,
   haptics, share/file. Keeps everything above testable.
5. **`App/`** — `@main`, app state, routing (`data-view` → enum-driven nav).

Rule: never import SwiftUI/SwiftData into `Domain/`.

### Folder layout
```
Maxiflex/
  Maxiflex.xcodeproj
  Maxiflex/
    App/            # @main, routing, app-level state
    Domain/         # ported pure logic (time.js, calendar.js)
    Store/          # SwiftData models + repositories + CSV/ics
    Features/       # Period, Day, Metrics, Settings, Schedule, (Calendar)
    Platform/       # widgets bridge, notifications, eventkit, haptics
    Resources/      # assets, sample data
  MaxiflexWidgets/  # WidgetKit extension (Phase 7)
  MaxiflexTests/    # unit tests — Domain + Store especially
  CLAUDE.md
```

---

## Old → new porting map

### Domain (`time.js` → `Domain/TimeMath.swift`, `Holidays.swift`, `Ics.swift`)
Port faithfully; the PWA is the **oracle**. Key targets and Swift notes:
- Formatting/rounding: `roundToQuarter`, `formatTime/Minutes/Hours/Money`,
  `formatDateShort` → trivial.
- Local-date core: `parseLocalDate`/`formatLocalDate`/`buildDateTime` → use
  `Calendar.current` + `DateComponents` (NOT ms division). **DST-critical.**
- Pay-period math: `payPeriodFor`, `payPeriodOffset`, `payPeriodName`,
  `paydateFor/Year`, `isSunday` → count whole calendar days, never `/MS_PER_DAY`.
  Reproduce `YYYY-PPNN` naming + paydate (+12d) + paydate-year YTD bucketing.
- OT: `overtimeSplit` (8h mode), `maxiflexDayOvertime` (maxiflex). Preserve the
  per-period-override resolution and the `worked − scheduledHours` rule.
- Holidays: `federalHolidays` (OPM rules + observed Sat→Fri/Sun→Mon).
- Pace: `pace`, `expectedByDay`, `paceStatus` (±2h deadband).
- ICS: `buildScheduleIcs` + `icsEscape`/`foldIcsLine` (RFC-5545, floating-local,
  stable UID + monotonic SEQUENCE).
- Constants: `OT_MULTIPLIER 1.5`, `HOLIDAY_MULTIPLIER 2`, `PAYDATE_OFFSET_DAYS 12`,
  `PAY_PERIOD_DAYS 14`, `PAY_PERIOD_TARGET 80`, lunch/forgotten thresholds.

### Domain (`calendar.js` → `Domain/Recurrence.swift`, `EventsIcs.swift`, `Lanes.swift`)
- Color palette + `laneForColor`/`colorVar` → a `CalColor` enum.
- `stackEvents` greedy lane packing → pure function over value types.
- RRULE engine `parseRRule`/`formatRRule`/`expandRRule`/`expandSeries`
  (FREQ DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, BYDAY, COUNT, UNTIL, exdates,
  5000-iter safety cap). Keep our own engine — do NOT delegate to EventKit
  recurrence (we need on-read expansion + this/following/all semantics).
- `buildEventsIcs`/`parseEventsIcs` (RFC-5545 round-trip, CATEGORIES↔color).

### Store (`db.js` → SwiftData `@Model` + repositories)
- Models: `Entry`, `Leave`, `SettingKV` (or typed settings), `CalEvent`,
  `EventHistory`. Mirror current fields exactly (e.g. `Entry`: id, date,
  startTime, endTime, lunchMinutes, lunchDeducted, incomplete, fromDefault,
  isOvertime).
- Repositories reproduce `DB.*`: settings/anchor (Sunday-validated), per-period
  OT default + overrides map, hourly rate, use24h, calendarMode, validationDay,
  default schedule (14 slots, legacy-7 expansion), `applyDefaultSchedule`
  (holiday override + leave seeding), holidays map, auto-holiday seeding, entry
  clock-in/out + lunch rule + forgotten-entry marking, leave add/set, event CRUD
  + recurringSeries/backlog, event-history type-ahead.
- **CSV round-trip** (6 sections: SETTINGS, DEFAULT_SCHEDULE, ENTRIES, LEAVE,
  EVENTS, EVENT_HISTORY) — re-implement RFC-4180 parse + transactional restore.
  This is the migration bridge AND the user-facing backup. **Build it early** so
  PWA data imports into the native app.
- App Group container so the widget extension shares the store. Decide the App
  Group ID in Phase 0 and don't change it.

### UI (`app.js`/`index.html`/`styles.css` → `Features/`)
- Period carousel (2 pages, paging scroll) + 14 day cards + day timeline.
- Day editor: clock in/out (today only), entry list + add/edit, leave +/−,
  holiday section.
- Entry modal: quarter-hour pickers (native wheel/`Picker` — solves the iOS
  `<input type=time>` problem natively), lunch minutes, OT toggle.
- Metrics: stat grid + daily-hours stacked bar chart + mode-dependent second
  chart (recent-OT with range selector / pace line). Swift Charts.
- Settings: anchor, default OT mode, rate, 24h, schedule editor, validation day,
  auto-holidays, CSV import/export, schedule `.ics` export.
- Semantic color tokens (work/personal/OT-ember/person/leave-teal/holiday) →
  asset catalog colors with dark-mode variants. (Theme-menu remains a future.)

---

## Domain invariants to preserve (verify each with a test)
Rounding to 15 min; lunch −0.5h at ≥4h span; forgotten clock-out >16h →
incomplete/0h; 8h-mode OT = `max(0, worked − scheduled)` ungated (weekends 0
scheduled → all OT); maxiflex OT = explicit + beyond-scheduled once period >80h;
holidays OPM+observed, worked-holiday 2×; period naming `YYYY-PPNN`, paydate
end+12, YTD by paydate year; pace expected `80*(N+1)/14` ±2h; RRULE this/
following/all edit semantics. **DST:** all period/day math counts whole calendar
days via `Calendar`, never ms division.

---

## Risky / hard parts (budget extra time)
1. **DST-correct pay-period math** — port `payPeriodFor`/`payPeriodName` with
   calendar-day counting; test around spring-forward/fall-back.
2. **Timeline drag-reflow** — live resize/move with 15-min snap; SwiftUI gesture
   + Canvas/custom layout. Highest-effort UI piece.
3. **Calendar multi-lane drag + quick-add** (Phase 5) — lane hit-testing.
4. **RRULE engine fidelity** — exact expansion + this/following/all split.
5. **CSV fidelity** — byte-compatible enough to import existing PWA backups.

---

## Phased roadmap (checklists)

**Phase 0 — Scaffold** ✅ (done — `..\Scripts\Maxiflex`, git repo, commit 9497d40)
- [x] Delete the stray `ChronoForge` folder.
- [x] Create `Maxiflex/` folder + git repo; XcodeGen `project.yml` (iOS 17) for
      app + test targets. App Group ID reserved (`group.com.calebsmith.maxiflex`),
      widget target deferred to Phase 7.
- [x] Folder skeleton (App/Domain/Store-later/Features-later/Platform-later/Tests).
- [x] App shell (`MaxiflexApp`/`RootView`/`AppRoute`), asset catalog, new
      `CLAUDE.md` + `README.md`. (SwiftData container attaches in Phase 2.)

**Phase 1 — Domain port (the foundation)** 🚧 `time.js` done; `calendar.js` next
- [x] Port `time.js` → `Domain/` (Constants, LocalDate, Formatting, EntryMath,
      PayPeriod, Overtime, Pace, Holidays, Ics) + parity unit tests
      (period windows, naming `2026-PP08`/`2025-PP25`, paydate `2026-01-08`, OT
      both modes, holidays, pace, lunch, DST span, ics/formatting).
      ⚠️ Tests are written but NOT yet run — requires a Mac (Xcode) to compile.
- [ ] Port `calendar.js` recurrence + events ics + lanes with tests.

**Phase 2 — Store + CSV bridge**
- [ ] SwiftData models + repositories mirroring `DB.*`.
- [ ] CSV import/export (6 sections) — import a real PWA CSV and diff results.

**Phase 3 — Timecard UI core**
- [ ] Period carousel + day cards + day timeline (read).
- [ ] Day editor: clock in/out, entries (add/edit modal w/ quarter-hour picker),
      leave +/−, holiday section.
- [ ] Settings + schedule editor + apply-schedule.

**Phase 4 — Metrics + timeline interaction**
- [ ] Swift Charts (daily-hours stack, recent-OT + range, pace line).
- [ ] Timeline drag-to-resize / move with snap + reflow.

**Phase 5 — Calendar mode (preserve the WIP future)**
- [ ] Event model render pipeline (expand-on-read), cal lanes overlay.
- [ ] Event editor (type-ahead, color, repeat BYDAY/COUNT/UNTIL, backlog).
- [ ] this/following/all recur edits; event drag + quick-add; events `.ics`.

**Phase 6 — Native superpowers**
- [ ] EventKit (write schedule/events to Apple Calendar, true update/delete).
- [ ] Local notifications (validation deadline, pace).
- [ ] Haptics on clock in/out & drags; ShareLink for exports.

**Phase 7 — Widgets, polish, ship**
- [ ] WidgetKit (period quota + pace glance).
- [ ] Onboarding, app icon, dark mode pass, accessibility.
- [ ] TestFlight → App Store.

---

## Verification strategy
- **Domain:** XCTest suites in `MaxiflexTests/` asserting exact parity with PWA
  outputs. Where practical, dump JS results (period totals, OT, naming, RRULE
  expansions for fixed inputs) and assert the Swift equals them. Include DST
  dates (e.g. a period spanning a March/November transition).
- **Migration:** export a CSV from the live PWA, import into the native app,
  confirm entries/leave/settings/events match.
- **UI:** run in Simulator + on a real device per phase; verify the PWA's
  "Verification checklist" items (anchor→carousel window, clock in/out rounding
  + lunch, OT both modes, holidays, pay-period naming examples like
  `2026-PP08` and `2025-PP25`→paydate 1/8/2026).
- **Storage durability:** confirm SwiftData persists across reinstalls/backups
  and the widget reads via the App Group.

## Open decisions (resolve during execution)
- Final app name (placeholder "Maxiflex"); dedicated GitHub repo name.
- Whether the PWA keeps living in parallel long-term or is retired post-launch.
- Whether to build everything before first ship vs. ship timecard-only first
  (plan assumes ship-timecard-first).
