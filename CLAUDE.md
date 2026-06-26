# CLAUDE.md

Orienting notes for future Claude sessions working on this repo. The user-facing
spec lives in `maxiflex-tracker-spec.md`; this file captures decisions, gotchas,
and architectural conventions that aren't obvious from reading the code.

## What this is

A vanilla-JS Progressive Web App for tracking hours on a federal **maxiflex
biweekly schedule** (80 hrs / 14 days). Single user, fully local — IndexedDB
via Dexie, no server, no auth. Hosted on GitHub Pages at
`https://calebpaulsmith.github.io/Timecard-App/` and installable to the iOS or
Android home screen.

## ⚠️ This repo holds MULTIPLE apps — read before editing

This is a **monorepo**. Full map + rules: **`PLATFORM-STRATEGY.md`**. In short:

- **Timecard PWA** — repo **root** (this vanilla-JS PWA on GitHub Pages); also
  the prototyping medium + the personal playground (calendar / Discover / LLM /
  Google sync live here, gated behind `calendarMode`).
- **Timecard iOS** — **`iOS/`** (SwiftUI / SwiftData), the **sellable native
  product**. ONE codebase, TWO faces via the `PERSONAL` compile flag
  (`iOS/App/FeatureFlags.swift`): the **`Timecard`** scheme = **production**
  (timecard core + Pro, ships to the App Store) and **`Timecard Personal`**
  scheme = + the calendar / life-timecard / tax-from-LES exploration. (Xcode
  target/scheme/module = **Timecard**; the bundle id + App Group use
  `com.thegrandpipeline.timecard` — the App ID already registered on the Apple
  Developer account (with a matching "Timecard" App Store Connect record);
  "maxiflex" now only names the federal schedule.)

**Working rule (do this every change):** before editing, establish **which
app(s)/edition(s)** the change targets —
- **PWA only** (root files) · **iOS only** (`iOS/`) · **both** (a behavioral/spec
  change → update `LOGIC-FREEZE.md` first, then both) · or **production vs
  Personal** on iOS (core that ships, vs personal-only behind `PERSONAL`).
- **If it isn't explicit in the request, ASK the user before proceeding.**

Still in force: PWA **timecard mode stays network-free / byte-for-byte** (all
calendar/Google code is gated); the iOS **Domain layer is the protected core**
(see `iOS/CLAUDE.md`). New non-core features are flag-gated, default OFF in
production, and never change core timecard/pay math.

## Where this is headed (iOS product direction)

The active goal is a **focused, sellable, native iOS timecard** (widgets +
notifications). Strategy + a now-vs-deferred split live in
`ios-product-scope.md`; the market/positioning/monetization research brief is
`research/deep-research-prompt.md` and the **completed, sourced research report**
is `research/RESEARCH-ios-timecard.md`. The frozen behavioral spec the Swift
port targets is `LOGIC-FREEZE.md` (revision F1). Key calls captured there: the
**timecard core is the sellable product**; **calendar mode + Discover/Invites/LLM
are a separate personal track, excluded from the sellable MVP**; finish
*logic/spec* (not UI polish) in this PWA, then build out the native app (now in
`iOS/` in this monorepo: domain layer already ported from `time.js` + a
TestFlight CI pipeline).

### Decisions from the 2026-06 research (read `research/RESEARCH-ios-timecard.md`)

The market research **reframed the product** (see that report for sources/confidence):

- **Positioning: federal-maxiflex niche-first**, expand later to flexible/
  compressed schedules (9/80, 5/4-9, comp time, credit hours). No competitor
  serves it; official systems (webTA/GovTA/DOI QuickTime) are payroll-facing and
  the free DOL app models the wrong (40-hr) rules.
- **The moat is a federal rules engine, NOT generic tracking** — biweekly 80/14
  OT **+ the 24-hour credit-hour cap running balance + comp-time** tracking. That
  cap (lose anything over 24 carried hours) is the single best "an app fixes what
  a spreadsheet can't" feature.
- **Monetization: freemium + a one-time `$9.99` "Pro" unlock** (NOT subscription —
  category subscription-fatigue is the wedge). Raw StoreKit 2, App Store Small
  Business Program (15%), limited-free-tier instead of a timed trial.
- **Pro anchor = Projects/accounting codes + reports/CSV-PDF export** (proven
  willingness-to-pay). **Calendar sync (EventKit) is a Pro *bonus*, shipped last
  — NOT the headline** (calendar integration is commoditized/free elsewhere with
  little standalone WTP).
- **iCloud/CloudKit sync is a free-core, trust-critical requirement** (no-sync =
  data-loss 1-star reviews). It needs a deliberate, scoped exception to the
  "timecard = no network" rule; the private DB is the privacy-preserving way.
- **Native bets:** Live Activity/Dynamic Island, iOS 18 Control + App Intent,
  local notifications (incl. the domain-unique validation-deadline nudge),
  pay-period widget. Apple Watch later; **geofencing skipped** (incumbents' #1
  complaint).
- **Legal guardrails:** no government seals/names (18 U.S.C. §701/709/713/1017);
  market as **"unofficial,"** disclaim "not an official record — verify against
  your agency system"; **scope privacy claims** (the Google/calendar sync means
  "100% private" is FTC-actionable); keep dormant calendar/LLM code OUT of the
  reviewable App Store build; frame as an informational pay *estimator*, not
  "payroll/financial services" (App Store 5.1.1(ix)).
- **DECISION (2026-06-21): the WTP "gate 0" is removed — build now, regardless.**
  The research's one open unknown was federal-employee **willingness to pay** vs.
  free spreadsheets + the free DOL app (TAM also shrinking — 2025 RTO mandate +
  ~259K headcount cut), with the recommended next step being "validate in
  r/fednews / GovLoop *before* sinking native effort." **The owner has chosen to
  skip that validation gate and build the native iOS app unconditionally** — the
  app is wanted for its own sake (the owner is a user), so the build does not wait
  on measured demand. **Monetization is reframed as a *bonus*, not the driver:**
  still ship the one-time **$9.99** Pro unlock (it's cheap to include and a clean
  ask), but the product exists whether or not anyone pays. The market facts above
  remain true and are kept as honest context (set revenue expectations: portfolio
  piece + modest upside, not a livelihood); they just no longer **gate** the work.
  The r/fednews / GovLoop validation + waitlist is now **optional, parallel**
  distribution work — useful if pursued, never a prerequisite. Build constraint is
  still **distribution, not the product or the model.**

### Creative latitude (explicitly preserved — do not over-prune)

The user's broader vision is bigger than the sellable MVP and that is **fine and
welcome**: "Timecard" as a *timecard for life* — communicating one's hours to a
boss/family, and even **suggesting events** (the existing calendar / Discover /
Invites / LLM track is exactly this). The user also has adjacent ideas worth
capturing as they arise — e.g. a **tax-planning companion that reads federal
EPP/LES (Leave & Earnings Statement) data**. **Rule of thumb for future
sessions:** keep these exploratory/personal tracks **alive but separate** from
the sellable federal-timecard MVP (same pattern as the calendar/Discover track —
gated, optional, not gating the product). Don't let the sellable focus kill the
creativity, and don't let the creativity bloat/gate the sellable core. When a new
idea lands, note it here under this heading rather than wiring it into the MVP.

Captured exploratory ideas:
- *Tax planning from EPP/LES statements* — parse federal Leave & Earnings
  Statements to project withholding/refund/leave balances. Separate companion
  concept; not in the timecard MVP.
- *"Life timecard" / event suggestions* — the calendar + Discover/Invites + LLM
  layer already prototypes this in the PWA; remains a personal track.

## Stack & file layout

No build step. All files at project root, served as-is. Loaded by classic
`<script>` tags (NOT modules).

| File | Role |
| --- | --- |
| `index.html` | App shell. Four `<section>`s (home, period, day, settings) toggled via `body[data-view=...]`. Registers the service worker. |
| `styles.css` | iOS-flavored styles, dark mode via `prefers-color-scheme`, safe-area insets. |
| `time.js` | Pure helpers: rounding, pay-period math, OT split, formatters. Exposes `window.TimeUtil`. **No DOM, no DB.** |
| `db.js` | Dexie schema + data-access helpers. Exposes `window.DB`. |
| `google.js` | Google Calendar connector (calendar-mode only): GIS OAuth in the browser, Calendar REST v3 calls, pure local⇄Google field mappers. Exposes `window.GoogleCal`. DB reconciliation lives in `app.js`. |
| `app.js` | UI layer: rendering, event handlers, view router. Wrapped in an IIFE — see "Script-scope landmine" below. |
| `sw.js` | Service worker: cache-first for app shell, network-first fallback. |
| `manifest.json` | PWA manifest (`display: standalone`, theme color, icons). |
| `icons/icon-{192,512}.png` | App icons. |
| `.nojekyll` | Stops GitHub Pages from running Jekyll on the repo. |

## Data model (Dexie v1)

```
entries: { id (uuid), date (YYYY-MM-DD, indexed), startTime, endTime, lunchDeducted, incomplete, isOvertime, fromDefault, payKind? }
         // payKind (auto|autoCredit|overtime|credit|regular) classifies OT vs credit — LOGIC-FREEZE §4. Built in both apps (PWA resolves legacy isOvertime→payKind via DB.entryPayKind).
leave:   { date (YYYY-MM-DD, PK), hours }
settings:{ key (PK), value }
```

Settings keys currently in use:
- `autoHolidays` — boolean, default true. When on, federal holidays are
  auto-recorded (`ensureHolidaysSeeded`) with 8h leave and no scheduled work.
- `holidays` — `{ [YYYY-MM-DD]: { name, doubleTime } }`. Recorded holidays.
  `doubleTime` true → worked hours that day pay at 2× (`HOLIDAY_MULTIPLIER`).
  Stored in settings (no Dexie table), so it round-trips via the generic CSV
  SETTINGS section.
- `anchorDate` — a Sunday that was the first day of a known pay period.
- `overtimeModeDefault` — boolean, default true. The default OT mode applied
  to any pay period without an explicit override. (Legacy `overtime8hMode`
  is still read as a fallback for the first launch after the per-period
  refactor.)
- `overtimeModeOverrides` — `{ [periodStartDate]: boolean }`. Per-period OT
  mode overrides keyed by the period's anchor-aligned Sunday in `YYYY-MM-DD`.
  Set/cleared via the inline mode pill on each period screen. An override is
  removed when the user toggles back to the default value.
- `creditHoursEnabled` — boolean, default **false**. Master switch for the whole
  credit-hours feature. OFF (default): `effectivePayKind` collapses
  `autoCredit`→`auto` and `credit`→`overtime` so all extra hours pay OT and
  `periodTotals.credit` is 0; every credit surface (per-period Overtime|Credit
  control, credit stat, Metrics credit, entry classification select/tags) is
  hidden and the entry modal shows a plain OT checkbox. ON: the full feature.
  Stored `payKind`s are never rewritten, so the toggle is non-destructive. Built
  in BOTH apps (iOS: `store.creditHoursEnabled` + a `creditEnabled` param on
  `periodTotals`).
- `creditDefaultOverrides` — `{ [periodStartDate]: true }`. Per-period flex flag:
  when set, NEW maxiflex entries default to banking their beyond-schedule hours
  as **credit hours** instead of OT (sets the entry `payKind` stamped at
  creation; never reclassifies existing entries). **The OT/credit math is
  specified canonically in `LOGIC-FREEZE.md` §4 — change it there first.**
  Read/written via `DB.getCreditDefaultForPeriodStart` / `setCreditDefaultOverride`
  and the per-period "Overtime | Credit" toggle. (Built in both apps.)
- `creditUsed` — `{ [YYYY-MM-DD]: hours }`. Credit hours **spent** as time off
  (Phase 2 spend), the inward mirror of leave but drawn from the banked balance.
  Set via the day editor's "Use credit hours" stepper; the credit-bank fold
  subtracts it per period (`balance = carryIn + earned − used`, clamped 0..cap).
  Round-trips via the generic CSV SETTINGS section. Built in BOTH apps
  (iOS: `store.creditUsed`).
- `hourlyRate` — number (USD/hr), default 0.
- `metricsRange` — `'8pp' | 'ytd' | '6mo' | '1yr'`, default `'8pp'`. Selected
  range for the Recent OT chart on the metrics view.

## Behavioral rules (from spec, baked into `time.js`)

> **⚠️ Overtime + credit-hours math is CANONICAL in `LOGIC-FREEZE.md` §4
> (revision F2).** That is the safe, referenced home — to change the OT/credit
> rule, edit §4 first, bump the freeze revision, then update BOTH engines (PWA
> `app.js`/`time.js` `periodTotals`, iOS `Domain/PeriodTotals.swift`) + their
> tests. The summaries below are a convenience copy; §4 wins on any conflict.
> **Current state:** leave-counts-toward-80 + leave-fills-schedule + per-entry
> `payKind` (OT vs credit) + the per-period "Overtime | Credit" default + credit
> surfacing are now built in **both apps** (iOS PR #66/#69; PWA mirror in
> `app.js`/`db.js`). A master **`creditHoursEnabled`** switch (default OFF) hides
> the whole feature in both apps. Credit-hour **banking + the 24h carryover cap**
> is **Phase 2** (built iOS; PWA mirror in progress).

- **Rounding:** clock in/out times round to the nearest 15 minutes.
- **Lunch deduction:** any entry spanning ≥ 4 hours has 0.5 hours auto-deducted.
- **Forgotten clock-out:** if an open entry has been open > 16 hours,
  `getOpenEntry()` marks it `incomplete: true` and returns null. Incomplete
  entries contribute 0 hours and surface in the day editor for manual fix.
- **OT (8-hour mode):** `max(0, worked − scheduledHoursForIndex(day))` per day,
  **ungated** (no >80 gate, no fixed-8 floor), when the period's resolved OT
  mode is on (per-period override beats the settings default). The day's
  *scheduled* hours come from the default schedule, so a normal 8h-scheduled day
  still yields `worked − 8`; a 10h-scheduled day yields `worked − 10`. Lunch
  deduction is applied first (8.5 clocked = 8.0 paid). **Weekends / off days are
  unscheduled (0 scheduled hours), so ALL their worked hours are OT** — the old
  weekend-all-OT behavior now falls out of the scheduled-hours rule rather than
  a special case. `overtimeSplit` (the old fixed-8 helper) is no longer called
  by `periodTotals`/`dayTotals`/`todayTotalsLive`. OT is recomputed live, so
  this **retroactively** changes historical OT for customized schedules
  (accepted). `scheduledHoursForDate(dateStr)` resolves a date's scheduled hours
  via its day-of-period index.
- **OT (Maxiflex mode):** two sources, summed per day:
  1. **Explicit** — an entry flagged `isOvertime` (the "Overtime (OT)" toggle
     in the add/edit modal). Those hours are always OT.
  2. **Auto** — work *beyond that day's scheduled hours* (from the default
     schedule; `scheduledHoursForIndex`), counted only once the period's total
     worked hours exceed 80 (`maxiflexDayOvertime`). Unscheduled days (weekends,
     off days) have 0 scheduled hours, so all their work is "outside schedule."
  `periodTotals` is the single OT authority: it returns `otByDate` (per-day OT),
  `ot` (total hrs), and `otDollars` (blended 1.5×/2× pay). `dayTotals` /
  `todayTotalsLive` source their OT from it in Maxiflex mode. Both modes can now
  carry OT, so UI no longer gates OT display on the mode flag — it checks
  `ot > 0`.
- **OT color:** overtime renders **golden/ember** (`--ot` / `--ot-deep` /
  `--ot-text`), with a glow + shimmer — deliberately flashier than the calm blue
  regular bars. On the day timeline the day's **computed** OT amount is painted
  as an inline segment over the rightmost worked-minutes of the work bar
  (`otSegments` → `.tl-ot-seg`, a `pointer-events:none` overlay), **in both OT
  modes and in timecard mode too** (OT is timecard-native; the "keep timecard
  byte-for-byte" rule only guards calendar/Google code). This supersedes the old
  per-entry `isOvertime ? '.ot'` bar coloring — the base entry bar is always
  regular-colored now; the `isOvertime` flag still feeds the Maxiflex OT *math*,
  not the bar color.
- **Federal holidays:** `T.federalHolidays(year)` computes the 11 holidays for
  any year (OPM rules; fixed-date ones shift Sat→Fri / Sun→Mon and get
  "(observed)"). When `autoHolidays` is on, `ensureHolidaysSeeded` records the
  holidays in a [thisYear−1 .. thisYear+2] window: 8h leave on untouched days,
  schedule-seeded (`fromDefault`) work removed. `applyDefaultSchedule` takes a
  `holidaySet` and overrides those days (no work entry, 8h leave). In the day
  editor (`renderHolidaySection`) you can add/remove a holiday and toggle
  "holiday worked → double time." Worked-holiday hours are OT in either mode
  (`periodTotals`' holiday branch), paying 2× when `doubleTime`. Day cards show
  a holiday tag (`--holiday` pink).
- **Pay period:** `payPeriodFor(today, anchor)` returns a 14-day window
  aligned to the anchor.
- **Pay period naming (`YYYY-PPNN`):** YYYY is the year the period **starts**
  in. PPNN counts up from the first anchor-aligned period whose start is ≥
  Jan 1 of that year. Example with anchor 2026-04-19: that period is
  `2026-PP08`; the period ending 12/27/2025 is `2025-PP25`.
- **Paydate:** period end + `PAYDATE_OFFSET_DAYS` (default 12). User example:
  period ending 12/27/2025 → paydate 1/8/2026.
- **YTD bucketing:** uses the **paydate year**, not the start year. So
  `2025-PP25` counts toward 2026 YTD because its check fell on 1/8/2026.
- **OT pay multiplier:** `OT_MULTIPLIER = 1.5` (FLSA standard);
  `HOLIDAY_MULTIPLIER = 2` for worked-holiday double-time. `periodTotals`
  produces `otDollars` blending both. OT $ stats render when `hourlyRate > 0`
  and the period has OT.
- **Pace:** expected hours by day N = `80 * (N+1) / 14`. Status is `ahead`
  if worked > expected + 2, `behind` if < expected − 2, else `on-pace`.
  The 2-hour deadband prevents flickering.

## UI views

The main carousel is **2 pages**: Week 1 / Week 2 of the viewed period
(`state.viewedPage` 0 = Week 1, 1 = Week 2). The old Home page was removed;
its hero + stats + clock controls were redistributed:

- **Clock In/Out** lives inside the **Day Editor** (`#clockSection`), shown
  only when the open day is today (a timestamp stamps the current time).
- **Hero + stats + charts** moved to a dedicated **Metrics view**
  (`data-view-name="metrics"`), reached via a bar-chart icon button at the
  top-left of each week page (paired with the settings gear on the right).
- The "+1 Leave Hour Today" shortcut was removed; the day card already has
  per-day leave +/− buttons.

Views:

1. **Period (main)** — 3-line header: row 1 is metrics-icon · `‹ period-name ›`
   · settings-gear; row 2 a quiet date-range + paydate subline; row 3 a
   stat strip (`hrs / 80`, OT hrs, OT pay). No big "Week N" title — the
   page dots indicate the week. 14 day cards; tap a card → Day Editor.
   The validation-deadline day gets a thin warning-colored left border + a
   ✓ after the day name. Clock In/Out is NOT on the card — it lives in the
   Day Editor (today only).
2. **Metrics** — hero number (OT this period in 8h mode, hours-left in
   Maxiflex), stats grid (includes `YYYY hrs` = YTD hours worked, and
   `YYYY OT $` when 8h + rate; all YTD bucketed by paydate year), daily-
   hours bar chart (regular + OT + leave stacked, 8h reference line in 8h
   mode, today highlighted), then a second chart that's mode-dependent:
   - **8h mode** → Recent-OT bar chart with a `8 PP | YTD | 6 mo | 1 yr`
     range selector (persisted to `metricsRange`). Tap a bar to jump to
     that period in the Week view.
   - **Maxiflex** → cumulative pace line vs. ideal dashed line and 80h
     target line.
3. **Day Editor** — summary, a Clock In/Out button (`#clockSection`, today
   only), entry list (edit/delete each), "+ Add Entry" modal with
   quarter-hour selects (NOT `<input type="time">`, which doesn't give us
   15-min granularity on iOS), leave +/− counter.
4. **Settings** — anchor date (must be a Sunday), default OT mode toggle
   (per-period overrides win), hourly rate input, 24-hr time toggle,
   default schedule editor, validation-deadline picker, CSV import/export,
   and **calendar (.ics) export** of the default schedule (see below).

### Calendar (.ics) export

`T.buildScheduleIcs(schedule, periodStart, opts)` (in `time.js`, pure — no DOM/DB)
turns the 14-slot default schedule into an RFC-5545 iCalendar string for import
into Apple/Google/Outlook calendars. The Settings `#exportIcsBtn` button calls
`onExportCalendar` (`app.js`), which fetches the schedule + anchor, anchors to the
**current** pay period (`T.payPeriodFor(today, anchor).start`), and downloads
`maxiflex-schedule-<date>.ics`.

- One `VEVENT` per configured slot: an **enabled work slot** → timed event
  (`Work`) at the slot's clock in/out times; **`leaveHours > 0`** → an all-day
  `Leave (Nh)` event.
- Each event recurs **biweekly** (`RRULE:FREQ=WEEKLY;INTERVAL=2`). Day-of-period
  `i` and `i+7` are the same weekday in opposite weeks, so their two biweekly
  series **interleave** to cover every week when week 1 ≠ week 2.
- Times are **floating local** (no `Z`/TZID) — matches how the schedule is
  entered; clients render them in the viewer's zone.
- **Stable UIDs** (`tc-sched-work-{i}` / `tc-sched-leave-{i}@timecard-app`) +
  a **monotonic `SEQUENCE`** (minutes-since-epoch, bumps every export) so a
  re-import of an edited schedule is treated as an **UPDATE**, not a duplicate,
  by compliant clients (notably Google Calendar). Apple Calendar's *manual*
  `.ics` import still duplicates regardless — recommended flow is **import to
  Google, view in Apple via account sync**. Helpers `icsEscape` / `foldIcsLine`
  handle RFC-5545 text escaping and 75-octet line folding.
- Export is a one-time snapshot (no live sync); re-export after editing the
  schedule. Holidays are **not** included (handled separately in-app).
- A connected calendar MCP tool (when available in a session) can alternatively
  drive the user's real calendar directly (create/update/delete events) for true
  overwrite semantics with no file round-trip.

### Default schedule slots

Each of the 14 day-of-period slots is `null` (never configured) or
`{ enabled, startMin, endMin, leaveHours }`:
- `enabled` gates whether a WORK entry is seeded by `applyDefaultSchedule`.
- `leaveHours` (≥ 0, whole hours) is recurring leave seeded **independently**
  of the work toggle — so a slot can be a pure-leave off day
  (`enabled:false` + `leaveHours>0`) or a workday that also carries leave.
- On apply, a slot's `leaveHours` overwrites that day's leave **only when > 0**,
  so manually-entered leave on routine workdays (slot leaveHours 0) survives.
- The schedule-editor row has a `Leave Nh` stepper (`.schedule-leave`); the
  per-row "copy to weekdays" button copies hours AND leave.
- CSV `DEFAULT_SCHEDULE` section gained a `Leave` column; old exports without
  it import as `leaveHours: 0`.

### Per-period OT mode

The OT mode is **per pay period**, not global. Lookup is
`otModeForPeriod(period)` → `overrides[periodStartDate] ?? otModeDefault`.

- Settings toggle writes `overtimeModeDefault`.
- Each period screen has a **visible segmented control** (`.seg-control.period-mode`,
  `#periodModeW1` / `#periodModeW2`) with `Maxiflex` / `8-hour OT` segments.
  Tapping the inactive segment flips the viewed period's mode via
  `onTogglePeriodMode` (delegated click handler in `wireGlobalEvents`). The old
  **long-press on the period name** backdoor is still wired for back-compat but
  is no longer the primary affordance. Both write `overtimeModeOverrides[start]`,
  or **clear** the override when toggled back to the current default.
- Switching a period from 8h → Maxiflex when its current OT > 0 prompts via
  `#modeConfirmModal` before applying (so the user knows the OT will
  disappear from this period's stats, YTD, and charts).
- All math (`periodTotals`, `dayTotals`, `todayTotalsLive`, `ytdOvertime`,
  `ytdHoursWorked`, the chart builders) takes the period's resolved mode —
  historical periods are NOT retroactively rewritten when you change the
  default.

### "Days left" rule (`countWorkdaysRemaining`)

From today through period end, a day counts as a remaining workday when:
- **Weekday (Mon-Fri):** counts UNLESS it's a pure-leave day — 0 hours
  worked AND some leave entered.
- **Weekend (Sat/Sun):** counts ONLY IF it's revealed for the period AND
  already has hours worked on it.

### Leave on the day timeline

`buildDayTimeline(dateStr, entries, dayLeave, dayOt)` draws a **`.tl-leave` bar
IN LINE with the work bar** (same band/height, top 20px / 10px tall — see
History v27; it used to sit just below), in the restful-teal `--cal-leave`
color; length = leave hours, starting at the end of the last work entry, so it
reads as a teal continuation to the right of the worked hours. Visual only — no
drag handles. Recomputed on every render. `dayOt` (the day's total OT hours)
drives the inline OT segment overlay (see "OT color").

## Home Calendar (calendar mode)

An additive layer that turns the timecard into a home calendar **without
changing timecard behavior**. It's a sticky, opt-in `calendarMode` setting
(default off) that sets `body[data-mode="calendar"]` via `applyCalendarMode()`.
Spec: `home-calendar-plan.md`. **Hard rule: timecard mode (calendar off) must
stay byte-for-byte as it is — it's the work-shareable view and has zero Google /
network code.** All calendar code is gated on `state.calendarMode` / `.day-card.cal`.

**Data model (Dexie v2, additive over v1):**
- `events` — `id, date, needsScheduling, googleId` indexed; rows also carry
  `title, allDay, startMin, endMin, color (palette token), notes, location,
  rrule, exdates[], seriesId, source, createdAt, updatedAt`. A recurring
  **series** is ONE row with `rrule` + `exdates`; an **override** is a plain
  row (no rrule) carrying `seriesId`; a **backlog** item has `needsScheduling`
  + `date:null`. `DB.normalizeEvent` fills defaults.
- `eventHistory` — `title (normalized PK), lastUsed` + `displayTitle,
  defaultColor, count`. The type-ahead memory.
- `deletedEvents` (Dexie **v4**) — deleted-event **tombstones**, PK `googleId`
  (+ `calendarId`, `deletedAt`). Written by `DB.deleteEventAndSync` so a deleted
  synced event gets removed from Google instead of resurrecting on the next pull.
  Local-only (not in CSV). **⚠️ See Gotcha #6 — every event-delete path must
  respect this.**

**`calendar.js` (`window.Calendar`, pure — no DOM/DB):** color palette
(`COLORS`/`COLOR_ORDER`/`colorVar`/`laneForColor`), lane packing
(`stackEvents`), the RRULE engine (`parseRRule`/`formatRRule`/`expandRRule`/
`expandSeries`), and events `.ics` (`buildEventsIcs`/`parseEventsIcs`).

**Render pipeline (app.js):** `resolveEventsForPeriod` / `resolveEventsForDay`
return events by date = plain/override rows (date in window) **plus** series
expanded on read (`Calendar.expandSeries`, minus `exdates`). Series rows are
never rendered directly. `buildCalLanes` builds a `.cal-lanes` **absolute
overlay** INSIDE the `.timeline-wrap` (the work bar pins to the wrap bottom via
flex `justify-content:flex-end`, so expanding only adds room above). "Me" events
(work + personal) ride the **work bar's band and overlap it** — "my time" — so
their lane index is ignored vertically; person lanes (Ritza/Amelia) hug the bar
from just above, touching/partially overlapping, by their own lane index. All
vertical offsets are measured from the bottom via CSS vars
(`--me-bottom`/`--me-h`/`--person-bottom`/`--person-h`/`--person-step`), which
stay in sync with `.tl-bar` (top 17px, height 16px in a 46px timeline). All-day
events on a top band. Tap a day → expand in place
(`state.expandedDay`, one at a time); on the expanded day, **non-recurring**
events get drag handles + move (`attachEventDrag`) and empty space is a
quick-add surface (`attachQuickAddDrag`). Recurring occurrences are virtual
(id = series id) so they are NOT drag-mutable — they open the editor.

**Event editor:** `#eventModal` (title + type-ahead `#eventSuggest`, color
swatches, all-day, quarter-hour start/end, backlog toggle, location, notes, and
the **Repeat** controls: preset + a weekly **BYDAY** day-picker (`#eventByday`,
S–S round toggles, shown for weekly/biweekly) + an **Ends** selector
(Never / On date `UNTIL` / After N times `COUNT`). `repeatPresetToRRule` /
`rruleToRepeat` / `readRepeatControls` / `syncRepeatUi` translate the controls
to/from the stored RRULE; the engine already supported BYDAY/COUNT/UNTIL.
Edit/delete of a recurring occurrence routes through `#recurChoiceModal`
(**this / this & following / all**): *this* = exdate + override row;
*following* = split the series (`truncateRRuleBefore` sets the original's
`UNTIL` to the day before, a new series starts at this date carrying the edited
fields + recurrence; future exdates move to the new series); *all* = edit/delete
the series. The **backlog** renders on the Metrics view
(`renderBacklogInto`). Per-period/day OT and all timecard math ignore events
entirely.

**`.ics` / CSV:** `Calendar.buildEventsIcs`/`parseEventsIcs` (RFC-5545, RRULE
travels verbatim, floating-local times) behind the Settings **Calendar events
(.ics)** row (calendar mode only). The CSV backup gained `EVENTS` +
`EVENT_HISTORY` sections (round-trips events too).

**Google sync — IMPLEMENTED (v26):** browser-only GIS OAuth + Calendar REST v3
in `google.js`; two-way sync with the primary calendar + read-only Ritza mirror
and invites. Replaces the old "Phase 4 token-broker" plan (no server needed for
a token/implicit flow). See History v26 and "Google Calendar sync" below. (The
BYDAY multi-day picker, COUNT UI, and "this & following" recurrence-UI gaps are
implemented — see History v22.)

### Google Calendar sync (`google.js`, calendar mode only)

`window.GoogleCal` is pure (OAuth + REST + mappers); the DB reconciliation lives
in `app.js` (`googleSyncNow`/`pushLocalToGoogle`/`pullGoogleCalendar`/
`pullRitzaCalendar`/`maybeSyncGoogle`). Gated behind `calendarMode` like all
calendar code — timecard mode stays network-free, byte-for-byte.

- **Auth:** Google Identity Services token client (implicit flow) — no server,
  no client secret. The user pastes an OAuth **Web** client ID in Settings
  (`googleClientId`); the site origin must be an authorized JS origin. The
  short-lived access token (`googleToken`) is cached, silently refreshed
  (`prompt:''`) on expiry, and is in `LOCAL_ONLY_SETTINGS` (never in CSV
  export, preserved across CSV import).
- **Scope:** `auth/calendar` (read shared calendars + read/write own).
- **Two-way (own events ↔ primary):** push local-origin events up (insert new →
  save `googleId`; patch when `updatedAt > googleLastSync`), then pull primary
  down. Reconciled by the indexed `events.googleId`; cancelled remote events
  delete the local copy; `gUpdated` (remote `updated` stamp) skips unchanged
  rows so re-pulls don't churn `updatedAt` and re-trigger pushes. Recurring
  masters travel as one row (RRULE; `singleEvents:false`). Floating-local times
  go up with the viewer's IANA `timeZone`.
- **Ritza (shared calendar):** `googleRitzaCalendarId` picked from the user's
  calendar list. Mirrored **read-only** into her person lane (`source:'ritza'`,
  `color:'ritza'`, non-draggable, dashed `.cal-ev.ro`, tap → info toast; absent
  rows reconciled away each pull) **and** emitted as Invites (accept → a
  `source:'local'` personal event that then syncs to your primary).
- **Local deletions push up (v36) — ⚠️ STANDING INVARIANT, see Gotcha #6:**
  deleting a calendar event that has a
  `googleId` records a **tombstone** (Dexie v4 `deletedEvents`, PK `googleId`);
  `googleSyncNow` runs `pushDeletionsToGoogle` **before** the pull, so the remote
  copy is deleted and the pull no longer resurrects it. `upsertEvent` clears a
  matching tombstone (delete→undo, remote re-add); the pull skips any still-
  tombstoned id as a safety net. (Single-occurrence/exdate propagation still
  rides the deferred recurrence-override push.)
- **Deferred:** recurrence-override push; invites for recurring Ritza
  occurrences (only the master start emits an invite).

## Calendar UI + OT refinements — IMPLEMENTED (v21)

The batch of user-feedback refinements below is now built (see History v21).
Intent notes kept for context; the behavioral rules above are the source of
truth for the shipped behavior.

- **Interaction & sizing** — the expanded-day "peek" is now small/snappy
  (`.day-card.cal.expanded .timeline-wrap { min-height: 92px }`, was 156px); the
  drag grips (`.cal-ev-handle`) shrank to 9px wide with a +2/−1 height pad.
- **Leave bar** — now a thin `--cal-leave` (teal) bar just **below** the work
  bar (mirror of the person lanes above), replacing the old right-extension.
  Same teal token drives the metrics-chart `.bar-leave`.
- **Overtime** — 8-hour mode redefined to `max(0, worked − scheduled)` ungated
  (see "OT (8-hour mode)" above); Maxiflex math unchanged. The day's computed OT
  paints as an inline `.tl-ot-seg` overlay over the rightmost worked-minutes of
  the work bar, in **both** modes and **in timecard mode too**. Superseded the
  per-entry `isOvertime ? '.ot'` bar coloring.
- **Color semantics** — palette tokens are keyed by MEANING in `styles.css`
  `:root` (My-time work/personal, Overtime ember, Person Ritza/Amelia, Leave
  teal `--cal-leave`, Holiday). Mirrored by name in `calendar.js` COLORS for
  event colors.

### Still deferred — theme menu (future, wanted)
A Settings picker that swaps the underlying hex set (e.g. "Natural",
"High-contrast", "Muted") while every component keeps referencing only the
semantic tokens above. **Not built** — the tokens are theme-ready (a theme is
just a hex remap, no layout/logic changes) but there's no picker UI yet.

## Discover / Invites + LLM connectors — PARTLY BUILT (LLM layer remains)

> **Status (read first):** the engine, proxy, data layer, Invites lane, and
> add-source form are **BUILT** (History v23–v25; verified against live Chicago
> data). **The one big piece left is the BYO-LLM layer** (§"NEXT SESSION starts
> here" below). Small TODOs: home-address geocode, a Settings input for
> `proxyBase`/home/LLM key, collision warning, and browser end-to-end
> verification (the IndexedDB + form DOM paths shipped but aren't device-tested).

### NEXT SESSION starts here
1. **BYO-LLM layer** (the only major piece) — `llm.js` (pure, `window.LLM`):
   - **Settings**: `llmBackend` ('off'|'claude'|'ollama'), `llmEndpoint`/model,
     `apiKey` (local only, EXCLUDED from CSV export). Claude API may need the
     proxy (CORS); local Ollama does not.
   - **NL → filters**: the add-source form's "Curate" box (a sentence) → the
     structured `filters` object (reuse `Connectors` schema). One JSON-returning
     prompt; validate the shape before saving.
   - **Curation pass** on fetched invites: classify public-vs-private (drop
     "Ramona's Birthday Party"), de-dupe spammy repeats, rank by taste
     (accept/dismiss history). Runs in `ingest`/after; **degrades to plain
     date+geo order when `llmBackend==='off'`** (everything still works).
2. **Finish the form/MVP plumbing**: home-address geocode via Nominatim (proxied),
   a Settings section for `proxyBase` + home + LLM, and a collision warning vs the
   work bar on Accept.
3. Then the deferred extras: cadence suggester, balance target, scraping tier
   (CPD ActiveNet age params via real XHR capture, CPL BiblioCommons `.ics`).

Use the Claude API correctly — load the `claude-api` skill for current model
IDs/params before writing `llm.js`. Keep ALL of this calendar-gated; timecard
mode stays byte-for-byte.


> **Framing first:** the "calendar mode" layer is really a **second app** sharing
> the timecard's shell. Timecard = the shareable *work* record (calm, neutral,
> byte-for-byte protected, zero network). Calendar = a *personal time-management*
> app whose job is to **see work time and non-work time in one frame so the
> non-work side stops slipping away.** This feature is the calendar app's, NOT the
> timecard's — keep it fully gated behind `calendarMode` like the rest.

**JTBD (the user's own words, distilled):** *"When I have open non-work time, I
want local things I'd actually enjoy to show up as easy-to-accept invites, so I
commit to them instead of letting the time evaporate."* The mental model is
**Outlook invites** — at work, good things get pushed at you and you triage a pile
of unaccepted invites; outside work nothing does, so the default is nothing.
Recreate that *passive discovery + low-friction commitment*, but curated to
things the user likes and local to their area (Chicago / Ravenswood Manor).

### The model (reuses existing pieces)
The events data model already has the bones: a `source` field (defaults
`'local'`) and the **backlog** (`needsScheduling` items with no date). This adds
ONE more state — a *pending invite* — on top of that:

```
Sources (connectors) ──fetch──▶  INVITES (pending; surfaced, not yours yet)
                                       │ accept → real event on a day (reuse backlog→schedule flow)
                                       │ dismiss → gone + a taste signal for the LLM
                                       ▼
                                  your calendar
```

- **Invites lane** = the curated "unaccepted invites" pile. Surfaced **PUSH**:
  a visible count/badge ("3 new invites this week"), not buried — passive
  discovery is the whole point.
- **Accept** drops the invite onto a day (reuse the backlog date-picker flow).
  **Dismiss** is a *signal*, not just a delete (feeds the recommender).
- **The user curates the sources** = their own "event ads" — they're both the ad
  network and the audience.

### Defend-my-time (decided: YES)
Accepting an invite is not just "put it on the calendar" — the calendar app
should **defend the user's time**:
- **Collision awareness** against the work bar / existing events (warn on
  overlap with scheduled work or another commitment).
- **A non-work balance target** — mirror the timecard's 80h *work* bar with a
  *life* target (e.g., "N hours of non-work things this week"), so non-work time
  is managed *like work*. This is the bridge to reason #2 (manage myself like I
  manage work). Exact metric TBD (hours? # of outings? per-category?).

### LLM layer (the core ask — "make it smart, keep me occupied")
**Bring-your-own-model**: works with **Claude (API key)** OR a **local Ollama**
endpoint (local-first, private option — fits the no-server ethos). Pluggable
backend, user-configured in Settings. The LLM's jobs:
1. **Recommend things to do** — rank/curate incoming invites by *learned taste*
   (accept/dismiss history, time-of-day/seasonal patterns, the balance target).
2. **Suggest new connectors/sources** — "you like X, here's a feed for Y near
   you" — actively grows the source list instead of the user hunting for feeds.
3. **Smart, natural-language filtering** — not dumb checkbox filters. The user
   wants: *"within N miles of home or any address,"* *"free,"* *"weekends,"* or
   *no filter* — expressed in plain language and turned into a structured query.
   Geo-radius is a first-class filter (home address or arbitrary address).
4. **Proactive "keep me occupied" nudges** — surface a good option *at* the user
   when there's open time, tuned to taste + the balance target.

### Real data sources (Chicago) — VERIFIED against CurbIntel's data-source
review (the CurbIntel repo is private; its inventory was verified live against
`data.cityofchicago.org` on 2026-06-10). Dataset IDs below are confirmed and
all Socrata (free SODA API, JSON, browser-fetchable — **no proxy, no key**;
an app token only raises rate limits). Cite as `data.cityofchicago.org/d/<id>`.

**Shippable today (carry dates + locations):**
- **Park District Event Permits `pk66-w54g`** — festivals, races, concerts,
  permitted park events. The single biggest events source. Join park name →
  park geometry (`5yyk-qt9y` points / `ej32-qgdr` polygons) for location.
- **Block Party / DOT Special Events `9zhy-9n5f`** — current-and-future view of
  the CDOT permit system, already carries `latitude`/`longitude` +
  `applicationstartdate`/`applicationenddate`. Neighborhood street events.
- **Festivals** — festival-worktype permits from CDOT `jdis-5sry` (live).
- **Farmers Markets `atzs-u7pv`** (per-year ID; seasonal/recurring).

**Geo filter (the user's "within N miles of home / my neighborhoods"):**
- Neighborhood polygons `y6yq-dbs2` + Community Areas `igwz-8jzy` → membership
  filter to **Lincoln Square / Albany Park / Ravenswood / Ravenswood Manor**
  (the user thinks in neighborhoods, so polygon-membership beats a raw radius).
- Home address → lat/lng via **OSM Nominatim** (already used in CurbIntel; 1
  req/s, needs a descriptive User-Agent).
- Library *locations* `x8fc-8rcq` (address/phone/hours) for "branches near me".

**Scraping long-tail (NOT on the portal — defer):**
- **Park District programs/registration** (rec classes at Ravenswood Manor) →
  ActiveNet, no clean public API. Scrape.
- **CPL library *events*** (story times/classes) → BiblioCommons
  (chipublib.org/events), only library *locations* are on the portal. Spike for
  a per-event `.ics` (would reuse `parseEventsIcs`).
- **Movie times** → no free API. But **"Movies in the Parks"** (free outdoor
  movies in the user's own parks) is a high-want target; portal copy is stale
  (latest `7piw-z6r6` = 2019), live source is the CPD site.

**Honest framing:** v1's flavor is "festivals / markets / block parties / park
events near me" (permits) — NOT the rec-classes + showtimes the user first
imagined. Set that expectation. Parades/festivals beyond CDOT/Park District
permits (Eventbrite, Do312, Nextdoor, Facebook) sit behind restrictive APIs.

### Architecture & the honest crux
The UI is the easy part; **data sourcing is the hard 80%.**
- **No clean APIs for much of it.** Movie showtimes (no free API), parks-district
  programs (ActiveNet), CPL events (BiblioCommons) → fragile scraping. Don't
  promise "connectors to everything." **Build boring first** (Socrata permits).
- **CORS wall, already solved in CurbIntel.** This is a static PWA (no server).
  Socrata is fetched **directly from the browser** (CurbIntel does this per
  viewport). Non-CORS hosts (NWS, USGS) go through CurbIntel's **Cloudflare
  Worker proxy** (`/api/nws/...`, `/api/usgs`) — reuse that exact pattern here
  for any `.ics`/API feed that lacks CORS headers. Keep the app static; the
  proxy is a dumb relay.
- **Reuse the `.ics` engine.** `Calendar.parseEventsIcs` already exists — an ICS
  **feed subscription** (fetch a URL on a schedule, diff new events into invites)
  is the realistic generic connector and reuses shipped code.
- **LLM keys never ship in the repo.** Claude API key / Ollama URL are
  user-entered Settings, stored locally (and excluded from CSV export). Local
  Ollama needs no proxy; Claude API may (CORS) — verify.

### Connector framework — BUILT (generic adapter + unified filters)
The pure engine, the unified `filters` schema, and the proxy tunnel are in place
(verified against LIVE Chicago data). A source = **fetch config + field-`map` +
`filters`** — the one plug-and-play shape the engine, the add-source form, and
the (optional) LLM all target. `prepare(src, ctx)` → request; `ingest(src, raw,
ctx)` → `mapRecord` (dot-path field map → invite shape) → `applyFilters` (the
unified engine: date floor, horizon, geo radius/places, days/time, age overlap,
cost, category include/excludeKeywords, keyword, de-dupe, maxResults). Types:
- **`json`** — the universal adapter: fetch any URL, dig records at `recordPath`,
  map fields; all filtering is post-fetch (can't push down an unknown API). This
  is the "plug in anything with a clean JSON API" path. Proxied by default.
- **`socrata`** — `json` where we DO know SoQL, so `socrataWhere(src, ctx)`
  **compiles** the unified filters into a `$where` (date floor + horizon, geo
  bounding box, category/place `LIKE`s, keyword) using the field-`map`; exact
  radius + excludeKeywords still run in `applyFilters`. CORS-OK → not proxied.
  - **`activenet`** — POSTs the CPD list endpoint. **Age/center server params are
    unreliable** (verified: they're ignored), so we **post-filter** by the
    record's `age_min_year`/`age_max_year` (window overlap) and by center label.
    Needs the proxy. *TODO: capture the real browser XHR to get working
    server-side `center_ids`/age/pagination params; post-filter is the
    guaranteed fallback.*
  - **`ics`** — reuses `Calendar.parseEventsIcs` (its own fixed map); proxied.
  - **Generic + customizable** is the whole point: a source is just `{ type,
    endpoint, map, filters }`. The user's Chicago setup ships as
    **`DEFAULT_SOURCES`** (seed/editable; also the worked templates for the
    add-source form). Other users start empty and add their own. Seeding is
    **version-stamped** (`DB.seedSources(defaults, v)`): a schema bump re-seeds
    the default sources once, preserving each `enabled` toggle, never touching
    user-added sources.
- **`DEFAULT_SOURCES`** (the user's seed): `cpd-park-events` (pk66, public-event
  types only, scoped to his parks), `cdot-festivals` (jdis-5sry, within 2 mi),
  `cdot-block-party` (9zhy, **within 1000 ft of home** — only if it's on his
  block), `cpd-kids-3-4` (ActiveNet, ages 3–4 at Horner/River/Gompers/Welles/
  Winnemac — center IDs `4/8/13/521/578`). `HOME_FALLBACK` ≈ Ravenswood Manor
  until the real address is geocoded in Settings.
- **`proxy/worker.js`** + `wrangler.toml` — the CORS **tunnel**: a Cloudflare
  Worker that relays `GET <proxyBase>/proxy?url=<encoded>` to an allowlist
  (`data.cityofchicago.org`, `anc.apm.activecommunities.com`,
  `nominatim.openstreetmap.org`, Cook County) and stamps CORS. Same pattern as
  CurbIntel's Worker. Deployed separately; its URL becomes a `proxyBase` setting.
- **Verified live (node harness):** park-events → 45 real future invites near
  home; block-party geo → correctly filtered to those within 1000 ft;
  ActiveNet → reachable JSON with age fields, normalize runs.

### Filter model = the add-source form = the LLM's output (one schema)
The form, the manual filters, and the LLM all target ONE `filters` object on each
source. The form is the manual way to fill it; the LLM is the natural-language
way to fill it (NL → structured filters) **plus** a curation/ranking pass. Define
the schema once and you've defined both the form and the LLM contract.

**Two filter stages:** (1) **query-time** — pushed to the API to shrink the
fetch (geo bounding box, date floor, dataset `$where`, keyword); (2)
**post-fetch** — client-side in `postFilter` (exact radius, age overlap,
category/keyword include-exclude, cost) **and the LLM pass** (public-vs-private
classification, taste ranking, de-noise). Most knobs live in stage 2.

**The `filters` schema (every dimension, with data backing + stage):**
```
filters: {
  geo: {                       // WHERE  — verified: 9zhy/jdis have lat/lng;
    mode: 'radius'|'neighborhoods'|'places'|'anywhere',
    anchor: 'home'|{address,lat,lng},      //   pk66 has none → 'places' by park
    radiusFt: 1000,            // query: bbox → post: exact haversine  name; y6yq-dbs2 polygons
    neighborhoods: [...],      // post: polygon membership (Ravenswood Manor…)
    places: ['Horner Park',…], // query: name LIKE / center_ids (sources w/o coords)
  },
  when: {                      // WHEN
    horizonDays: 60,           // query: date < today+N   (all sources have a start date)
    daysOfWeek: ['Sat','Sun'], // post: [] = any          (activenet days_of_week; socrata derive)
    timeOfDay: 'any'|'morning'|'afternoon'|'evening',     // post
  },
  age:  { min: 3, max: 4 }|null,   // WHO  — activenet age_min_year/age_max_year overlap (post)
  cost: { freeOnly: true, maxPrice: null },  // COST — activenet fee; permits are free (post)
  category: {                  // WHAT
    include: ['festival','concert','market'],   // query/post: pk66 event_type, 9zhy worktype
    excludeKeywords: ['birthday','camp','photography'],  // post: kills permit noise
  },
  keyword: '',                 // query: activenet activity_keyword (server-side) / socrata LIKE
  taste: {                     // CURATE (the LLM's job; degrades to off)
    naturalLanguage: 'free outdoor stuff I can take a 4-yr-old to on weekends',
    publicOnly: true,          // LLM/heuristic: drop private permits & internal holds
    llmRank: true,             // LLM: relevance score from accept/dismiss history
  },
  maxResults: 40,              // VOLUME (post)
}
```

**The form mirrors the schema** (progressive disclosure — a section only shows
when the source type supports it): Source (type+endpoint, hidden for seeds) ·
**Where** (radius / neighborhoods / places) · **When** (horizon, days, time) ·
**Who** (age — programs only) · **Cost** · **What** (categories, include/exclude
keywords) · **Curate** (the natural-language box + "public only" + "smart rank"
toggles) · advanced (max results, refresh cadence).

**The LLM's exact role:** it is an *alternate front door* to the same schema. It
(1) compiles the natural-language box → the structured `geo/when/age/cost/
category` fields (so a novice types one sentence instead of touching 8 controls),
(2) runs a per-invite **curation pass** — classify public-vs-private (drop
"Ramona's Birthday Party"), de-dupe spammy repeats (the Cubs-camp rows), and
**rank by learned taste** (accept/dismiss history), (3) suggests new sources.
**No model configured → the structured filters still work**; you just lose the
NL box, the public/private smarts, and ranking (falls back to date+geo order).

### Deferred idea — recurring life-maintenance reminders (cadence suggester)
A second *internal* invite source (no external feed): track regularly-recurring
personal needs — haircut, dentist, doctor, oil change — and surface a pending
invite when one is due ("It's been 7 weeks since your last haircut — schedule?").
Keep it **logically simple + easy to track**:
- A small `cadences` list: `{ id, label, category, intervalDays, lastDone, snoozeUntil }`.
  `intervalDays` is user-set OR **learned** = median gap between past occurrences
  of that title (read straight from `events`/`eventHistory` — no new tracking
  burden; scheduling the thing IS the log).
- Due when `today - lastDone >= intervalDays` (minus a lead-time). Emits an
  invite into the SAME Invites lane (reuse accept/dismiss); **accept** schedules
  it and bumps `lastDone`; **dismiss** = snooze.
- It's the inward mirror of the external connectors: same lane, same shape, the
  "source" is the user's own cadence model. Cheap to build on the invites
  pipeline already shipped.

### Likely data-model additions (Dexie v3, additive)
- `sources` — a subscription: `{ id, type, label, enabled, color, category,
  endpoint (domain/dataset | host/org | url), map, filters (above), lastFetched }`.
- Events gain an **invite state**: reuse/extend `source` (≠ 'local') + a
  `pending`/`invite` flag (distinct from `needsScheduling` backlog) so invites
  render in their own lane until accepted.
- `taste`/`recommenderState` — accept/dismiss history + LLM-learned preferences.
- Settings: `llmBackend` ('claude'|'ollama'|'off'), `llmEndpoint`, `apiKey`
  (local only), `homeAddress`/`homeLatLng`, `balanceTarget`.


### MVP scope (proposed — confirm before building)
- **v1 in:** a **Socrata events connector** hardcoded to the 3–4 verified
  datasets above (`pk66-w54g`, `9zhy-9n5f`, `jdis-5sry`, `atzs-u7pv`) fetched
  **direct from the browser** (no proxy) + a generic ICS-URL subscription (via
  the reused Worker proxy when a feed lacks CORS); the Invites lane with
  accept/dismiss; PUSH count badge; **neighborhood-membership** geo filter
  (Lincoln Square / Albany Park / Ravenswood / Ravenswood Manor via `y6yq-dbs2`);
  collision warning vs. work/events.
- **v1 LLM (thin):** natural-language filter → structured Socrata `$where`/geo
  query, and taste ranking of invites — behind a BYO Claude/Ollama key,
  **degrades gracefully to plain filters when no model is configured.**
- **Deferred:** connector auto-suggestion, proactive nudges, the full balance
  target/metric, scraping connectors (CPD ActiveNet programs, CPL BiblioCommons
  events, Movies-in-the-Parks live), movie times.
- **Riskiest assumptions now (post-CurbIntel — #1 largely answered):**
  (1) ~~Do the sources expose an API?~~ **Answered: yes, Socrata, verified IDs,
  browser-fetchable.** Remaining: are *permit* events (festivals/markets/block
  parties) actually things the user wants to do, or too bureaucratic/sparse for
  his neighborhood? (spike: pull `pk66-w54g` + `9zhy-9n5f` filtered to his
  neighborhoods, eyeball a month of real rows). (2) Is the LLM worth it for
  *ranking*, or better spent on the *natural-language filter* + *connector
  discovery*? (3) Does CPL BiblioCommons expose a per-event `.ics` (would reuse
  `parseEventsIcs` and add the one source he named that the portal lacks)?

### Remaining build order (engine, proxy, data layer, Invites lane, form = DONE)
1. ~~Dexie v3 `sources`+`invites`~~ DONE. 2. ~~Fetch loop~~ DONE.
3. ~~Invites lane + PUSH badge~~ DONE (accept/dismiss; collision warning TODO).
4. ~~Add-source UI~~ DONE — `#sourcesModal` (list/toggle/edit/delete) +
   `#sourceFormModal` (the generic form: Basics · Source(endpoint by type) ·
   Map fields · Where · When · Who&cost · What), progressive-disclosure by
   type/geo-mode; `readSourceForm`→`DB.upsertSource`. *Still TODO:* home-address
   geocode via Nominatim, a Settings home/proxyBase input, collision warning.
5. **LLM layer** (BYO Claude/Ollama) — the only big piece left: NL filter →
   the `filters` object, and taste curation/de-noise. Degrades to plain filters
   when no model is set.

## Gotchas — read before editing

### 1. Script-scope `const` collision

Classic `<script>` tags share a single "script scope" for top-level
declarations. Both `db.js` and `app.js` had `const T = window.TimeUtil;`,
which silently aborted all of `app.js` with `Identifier 'T' has already been
declared` — symptom was "buttons don't work" because no event handlers
attached. Fix: **`app.js` is wrapped in an IIFE.** If you add another script
at the bottom of `index.html`, either give it unique top-level names or wrap
it in an IIFE too.

### 2. Service worker cache invalidation

The SW caches the app shell. Two layers can serve stale code:
1. The browser's HTTP cache, which the SW's old `cache.add()` would
   inherit. **Fix already applied:** install handler now uses
   `new Request(url, { cache: 'reload' })`.
2. The SW cache itself. Bump `CACHE_VERSION` in `sw.js` when you change
   any shell file. The activate handler deletes old caches.

After a deploy, an installed PWA may still serve the old shell for one
session because the new SW is "waiting." `self.skipWaiting()` + `clients.claim()`
are already in there to make takeover immediate, but iOS Safari can still
require a force-reload or a Settings → Safari → Advanced → Website Data
clear in stubborn cases.

### 3. DST in date math

`parseLocalDate("YYYY-MM-DD")` returns a local-midnight Date. Subtracting
two such Dates can yield a non-integer number of days when a DST transition
falls in the range (one extra hour either way). Anywhere we divide by
`MS_PER_DAY` and then `Math.ceil` or compare to integer multiples, **round
to whole days first** with `Math.round((a - b) / MS_PER_DAY)`. See
`payPeriodName` in `time.js` for the pattern.

### 4. Anchor must be a Sunday

`setAnchor` throws if the date isn't a Sunday. The Settings UI surfaces this
inline — don't bypass the validation.

### 5. Quarter-hour pickers

The Add/Edit Entry modal uses three `<select>`s per time (hour 1-12 +
:00/:15/:30/:45 + AM/PM). This is intentional — `<input type="time">`
on iOS shows a 60-minute scroll wheel, which lets users save sub-quarter
times that then round on display. Don't switch back without solving that.

### 6. ⚠️ Deleting a synced event MUST tombstone — never plain-delete (read this for ALL event work)

> **STANDING INVARIANT — applies to every current and future event feature.**
> Google sync is **pull-after-push**: `pullGoogleCalendar` re-creates any remote
> event that has no matching local row. So if you delete a local event that has a
> `googleId` **without recording a tombstone, the next sync resurrects it.** This
> is a real bug we already shipped a fix for (v36) — do not reintroduce it.

**The rule, every time you add or touch an event-deletion path:**

- **User-initiated deletes go through `DB.deleteEventAndSync(id)`, NOT
  `DB.deleteEvent(id)`.** `deleteEventAndSync` writes a tombstone (Dexie v4
  `deletedEvents`, PK `googleId`) when the row has a `googleId` and isn't a
  read-only mirror (`source !== 'ritza'`); the next `googleSyncNow` runs
  `pushDeletionsToGoogle` **before** the pull to DELETE the remote copy, and the
  pull skips any still-tombstoned id so it can't come back.
- **Plain `DB.deleteEvent(id)` is ONLY for the sync layer's own reconciliation
  deletes** — rows that are *already gone remotely* (a remote `cancelled` event,
  a vanished Ritza mirror row). Those must NOT tombstone (the remote is already
  deleted; tombstoning would just chase a 404).
- **Anything that re-creates an event clears its tombstone automatically** —
  `DB.upsertEvent` deletes the matching tombstone whenever it writes a row with a
  `googleId`. This is what makes delete→undo and legitimate remote re-adds safe.
  Keep this invariant: *an event row and a tombstone for the same `googleId` must
  never coexist.* If you add a new write path that bypasses `upsertEvent`, clear
  the tombstone yourself.
- **New delete entry points** (new menus, bulk delete, swipe-to-delete, "clear
  all," recurrence edits that drop occurrences, etc.) must route user deletes
  through `deleteEventAndSync`. Whole-event and whole-series deletes propagate
  today; **single-occurrence (exdate) deletes still ride the deferred
  recurrence-override push** — if you build that, push the EXDATE up too.
- **iOS parity:** the iOS app has the same pull-after-push exposure. When you
  port or add event deletion there, build the equivalent tombstone path (and note
  it in `LOGIC-FREEZE.md` if it becomes a behavioral rule shared by both apps).

The tombstone table is **local-only bookkeeping** (like `scheduleSyncMap`) — not
exported to CSV. Helpers live in `db.js`: `deleteEventAndSync`,
`addEventTombstone`, `eventTombstones`, `removeEventTombstone`.

## Deployment

GitHub Pages, repo `calebpaulsmith/Timecard-App`, branch `main`, root
directory. Pushing to `main` deploys.

```
git add <files>
git commit -m "..."
git push origin main
```

Then bump `CACHE_VERSION` in `sw.js` if shell files changed.

`.nojekyll` is required — without it, GitHub Pages skips files starting
with `_` and runs Jekyll, which we don't want.

## Local development

```
python -m http.server 8765
```

Then open http://localhost:8765. SW requires HTTPS or localhost — `file://`
won't fully work. `.claude/launch.json` already has this configured.

## Verification checklist (when changing core logic)

1. Anchor → set to a known Sunday → the carousel shows correct period window.
2. Clock in → wait → clock out → entry rounds to 15 min, lunch deducts at ≥4h.
3. Add manual entry via Day Editor → totals update.
4. Add/remove leave → counts toward 80.
5. Forgotten clock-out → set an open entry's `startTime` > 16h ago in
   devtools → reload → flagged incomplete, contributes 0.
6. Anchor change → entries rebucket correctly.
7. PWA install: Chrome devtools → Application → Manifest / SW shows
   "installable," no errors.
8. Offline: kill network → app shell still loads, IndexedDB persists.
9. Dark mode: OS toggle flips colors.
10. 8-hour mode: 9-hr clocked = 8.5 paid → 0.5 OT shown per day, summed
    per period, OT $ correct.
11. Pay period naming: April 19, 2026 → `2026-PP08`. Period ending
    12/27/2025 → `2025-PP25` with paydate 1/8/2026.
12. YTD OT $: a period whose paydate falls in year N counts toward N's
    YTD even if all the work happened in year N−1.
13. **Per-period OT toggle:** flip a past period from 8h → Maxiflex via the
    long-press on its period name → confirmation modal appears if that
    period had OT > 0 → on confirm, that period's OT (and its YTD $ share)
    drops to 0; default `overtimeModeDefault` is unchanged; other periods
    keep their previous values. Switching back restores OT to the original
    value (entries are never touched).
14. **Metrics view:** access via top-left bar-chart icon on Week 1/2.
    Stats grid + daily-hours bar chart (regular/OT/leave stacks visible).
    In 8h mode, the second chart is Recent OT — toggle 8 PP / YTD / 6 mo /
    1 yr; tap a bar to jump to that period. Each bar uses ITS OWN period's
    resolved mode (so a Maxiflex period reads zero OT here, regardless of
    the current default).

## History — major changes

- **v1** Initial PWA from `maxiflex-tracker-spec.md`. Four views, Dexie,
  SW, manifest, icons, README.
- **v2** Added 8-hour shift mode toggle. Per-day OT split, per-period OT
  total on Home, "+ OT" badge on day cards.
- **v3** GitHub Pages deployment. `.nojekyll`, repo set public.
- **v4** Fixed dead-buttons bug — `app.js` wrapped in IIFE to escape
  script-scope `const` collision with `db.js`.
- **v5** SW install handler switched to `cache: 'reload'` to bypass
  stale HTTP cache when populating shell.
- **v6** Pay-period naming `YYYY-PPNN`, past-period nav (prev/next
  chevrons), hourly rate setting, OT $ per period, YTD OT $ on Home.
  YTD is bucketed by paydate year, not work-date year. DST fix in
  `payPeriodName`.
- **v7** Removed Home page; replaced with dedicated Metrics view (hero,
  stats grid, daily-hours bar chart, mode-dependent second chart). Carousel
  is now 2 pages (Week 1 / Week 2). Clock In/Out + leave moved onto today's
  day card. OT mode is now **per pay period** with a Settings default plus
  a `overtimeModeOverrides` map; the inline mode pill on each period screen
  toggles between 8-hour and Maxiflex, with an OT-erasure confirmation when
  switching off 8h on a period that already accumulated OT.
- **v8** 3-line period header redesign (no "Week N" title). Clock In/Out
  renamed "Timestamp" and restyled as a thick vertical side tab on today's
  card (green + pulse while clocked in). The OT-mode pill was removed — the
  per-period toggle is now a backdoor long-press on the period name.
  `Days left` rule reworked (`countWorkdaysRemaining`). Added YTD
  hours-worked stat (paydate-bucketed). Leave now renders as a colored
  segment extending the work bar on the day timeline.
- **v9** Reverted the validation cue to the original thin left border + ✓
  (the "Due" side tab was too thick). Default timeline scale widened to
  5:45 AM–6:15 PM so edge hour labels aren't clipped. All Saturday/Sunday
  hours are now overtime in 8h mode (`overtimeSplit` `isWeekend` arg).
- **v10** Removed the "Timestamp" side tab (it didn't read as a button).
  Clock In/Out now lives in the Day Editor as a plain button
  (`#clockSection`), shown only when the open day is today.
- **v11** Added a **visible per-period OT/Maxiflex segmented control**
  (`.seg-control.period-mode`) under the period stats on each week page,
  replacing the hidden long-press as the primary way to switch a period's
  mode. The long-press backdoor remains wired. (Phase A of a larger
  scheduling/OT/holiday feature set.)
- **v12** Default-schedule slots gained a `leaveHours` field: a per-row
  `Leave Nh` stepper in the schedule editor seeds recurring leave into
  upcoming periods on apply (overwriting a day's leave only when > 0).
  CSV `DEFAULT_SCHEDULE` gained a `Leave` column; `applyDefaultSchedule`
  now returns `{ written, leaveDays }`. (Phase B.)
- **v13** Maxiflex overtime. Entries gained an `isOvertime` flag (modal
  toggle + CSV `Overtime` column). `periodTotals` became the single OT
  authority (`otByDate` / `ot` / `otDollars`); Maxiflex OT = explicit OT +
  work beyond the day's scheduled hours once the period passes 80h
  (`maxiflexDayOvertime`, `scheduledHoursForIndex`). OT restyled golden-yellow
  with glow/shimmer; UI gates OT display on `ot > 0` rather than the mode
  flag. `HOLIDAY_MULTIPLIER` + a `holidayInfoFor` hook were stubbed in for
  Phase D. (Phase C.)
- **v14** Federal holidays. `T.federalHolidays(year)` (OPM rules + observed
  shifting); `autoHolidays` setting (default on) + `holidays` map
  (`{date:{name,doubleTime}}`). `ensureHolidaysSeeded` auto-records holidays
  (8h leave, removes schedule-seeded work); `applyDefaultSchedule` takes a
  `holidaySet` and overrides those days. Day-editor holiday controls
  (`renderHolidaySection`): add/remove + "holiday worked → 2× double time."
  Worked-holiday hours are OT (2× when double-time) via `periodTotals`. Day
  cards show a `--holiday` pink tag. (Phase D.)
- **v15** Calendar (.ics) export of the default schedule.
  `T.buildScheduleIcs(schedule, periodStart, opts)` emits an RFC-5545
  iCalendar string (helpers `icsEscape` / `foldIcsLine`); a Settings
  `#exportIcsBtn` → `onExportCalendar` downloads
  `maxiflex-schedule-<date>.ics`. One biweekly `VEVENT` per slot (enabled →
  timed `Work`, `leaveHours>0` → all-day `Leave (Nh)`); slots `i`/`i+7`
  interleave for full weekly coverage. Floating-local times, stable UIDs +
  monotonic `SEQUENCE` so re-imports UPDATE rather than duplicate on compliant
  clients (Google). See "Calendar (.ics) export" above. Bumped SW cache to
  `timecard-v36`.
- **v16** Home Calendar Phase 0 (data foundations). Dexie **v2** adds
  `events` + `eventHistory` tables (additive upgrade — v1 data intact); a
  sticky `calendarMode` setting (default off) flips `body[data-mode="calendar"]`
  via `applyCalendarMode()`; `calendar.js` IIFE skeleton (`window.Calendar`)
  loads after `db.js`; colorblind-conscious palette CSS vars
  (`--cal-work/personal/ritza/amelia`). SW cache → `timecard-v37`.
- **v17** Home Calendar Phase 1a (calendar UI core, single events). In
  **calendar mode only**: Sat/Sun always shown; the timeline uses a **linear**
  7:30 AM–10:00 PM scale (timecard keeps its non-linear core-compression —
  both `minToPct`/`pctToMin` branch on `state.calendarMode`, `defaultScale()`
  picks the window). Each day card grows a `.cal-lanes` strip above the Me line:
  timed events stack into lanes (work/personal = "Me line" at lanes 0..M−1,
  Ritza/Amelia = thin "person" lanes above at M.., via `Calendar.stackEvents`),
  all-day events ride a top band. Colors come from the palette tokens
  (`Calendar.colorVar` / `laneForColor`). **Tap a day → expands in place**
  (`state.expandedDay`, one at a time) revealing event labels + a `+ Event` /
  `Edit day ›` action bar. Event CRUD: a new `#eventModal` (title, color
  swatches, all-day, quarter-hour start/end, location, notes) + an Events
  section in the day editor (`renderEventSection`). DB helpers
  `eventsForDate/ForPeriod`, `upsertEvent` (`normalizeEvent`), `deleteEvent`.
  **Deferred to Phase 1b:** event drag-to-resize + quick-add edge-drag (events
  are currently created/edited via the modal). Timecard mode is byte-for-byte
  unchanged. SW cache → `timecard-v38`.
- **v18** Home Calendar Phase 1b (event drag). On the **expanded** day, each
  timed event gets edge grips (`.cal-ev-handle` start/end) + body move-drag via
  `attachEventDrag` (mirrors the timecard handle-drag: live `reflowList`, 15-min
  snap, clamp to 0..24:00, persist on release; a no-move tap opens the editor).
  **Quick-add edge-drag**: dragging empty lane space (`.cal-add-surface` →
  `attachQuickAddDrag`) sketches a time span and opens the editor pre-filled.
  `openEventModal` now treats an id-less object as a **new** prefilled event
  (Add mode, no Delete), so quick-add and edits share one modal. A `.cal-tip`
  tooltip shows the time while dragging. SW cache → `timecard-v39`.
- **v19** Home Calendar Phase 2 (recurrence, memory, backlog). `calendar.js`
  gains a dependency-free **RRULE** engine (`parseRRule`/`formatRRule`/
  `expandRRule`/`expandSeries`) — FREQ DAILY/WEEKLY/MONTHLY/YEARLY + INTERVAL,
  BYDAY (weekly), COUNT, UNTIL; occurrences expand **on read** over the visible
  window (no pre-materializing). A recurring **series** is one row with `rrule`
  + `exdates`; the render layer (`resolveEventsForPeriod`/`resolveEventsForDay`)
  renders plain/override rows directly and expands series separately.
  **Editing/deleting a recurring occurrence** prompts this/all (`#recurChoiceModal`):
  "this" writes an exdate + a concrete override row; "all" edits/deletes the
  series. Recurring occurrences are virtual (id = series id) so they're **not**
  drag-mutable — they open the editor on tap. The event modal gains a **Repeat**
  preset (Daily/Weekly/Every-2-weeks/Monthly/Yearly + optional Until), a
  **type-ahead** title list from `eventHistory` (`recordEventHistory` on save;
  `searchEventHistory` prefix/newest-first; each row deletable), and an **"add
  to backlog"** toggle (`needsScheduling`, date-less). The **backlog** surfaces
  on the Metrics view (`renderBacklogInto`) with a per-row date picker to
  schedule, plus edit/delete. DB: `getEvent`, `recurringSeries`, `backlogEvents`,
  `recordEventHistory`/`searchEventHistory`/`deleteEventHistory`. **Deferred:**
  BYDAY multi-day picker, COUNT UI, and "this and following" (all built in v22).
  SW cache → `timecard-v40`.
- **v20** Home Calendar Phase 3 (events `.ics` + CSV, no login).
  `Calendar.buildEventsIcs(events)` / `Calendar.parseEventsIcs(text)` export &
  import single + recurring events as RFC-5545 (recurrence rides as the stored
  RRULE string — no expansion; floating-local times; `CATEGORIES` carries the
  color token's label; backlog items skipped). Reuses `T.icsEscape` /
  `T.foldIcsLine` (now exported from `time.js`). Settings gains a calendar-only
  **Calendar events (.ics)** row (`#eventsIcsRow`) with export/import
  (`onExportEventsIcs` / `onImportEventsIcs`). CSV backup gains **`EVENTS`** +
  **`EVENT_HISTORY`** sections (`exportToCsv` + `importApplySections`); the
  import transaction now clears/restores `events` + `eventHistory` too (old CSVs
  without those sections just leave them empty). SW cache → `timecard-v41`.
- **v21** Calendar UI + OT refinements (user feedback batch). **OT redefined**
  in 8-hour mode: `max(0, worked − scheduledHoursForIndex(day))`, ungated —
  replaces `overtimeSplit`'s fixed-8 rule in `periodTotals` / `dayTotals` /
  `todayTotalsLive` (new `scheduledHoursForDate` helper). Default Mon–Fri 8h
  schedule reproduces the old `worked − 8`; customized schedules retroactively
  recompute. **Inline OT segment**: `otSegments(sorted, dayOt)` paints the day's
  computed OT over the rightmost worked-minutes as a `.tl-ot-seg` overlay
  (`pointer-events:none`), in both OT modes and in timecard mode; the per-entry
  `isOvertime ? '.ot'` bar coloring is gone (`buildDayTimeline` /
  `buildDayEditorRow` / `buildDayCard` thread a `dayOt` arg). **Leave bar**
  moved BELOW the work bar — a thin `--cal-leave` (teal) strip; metrics-chart
  `.bar-leave` uses the same token. **Sizing**: expanded peek `min-height`
  156→92px; `.cal-ev-handle` 16→9px wide with a slimmer height pad. **Color
  tokens** re-documented by meaning in `:root` (+ new `--cal-leave`); a theme
  menu remains deferred. SW cache → `timecard-v43`.
- **v22** Recurrence UI gaps (engine already supported them; this is UI only).
  Event modal Repeat controls gained a weekly **BYDAY** day-picker
  (`#eventByday`, round S–S toggles, shown for weekly/biweekly) and an **Ends**
  selector (Never / On date `UNTIL` / After N times `COUNT`, replacing the lone
  "Repeat until" date). New `readRepeatControls` / `syncRepeatUi` /
  `setBydaySelection`; `repeatPresetToRRule` takes an opts object;
  `rruleToRepeat` returns `{preset, byday, endMode, until, count}`. The
  recurring this/all chooser gained **"This & following"**: `truncateRRuleBefore`
  caps the original series with `UNTIL`=day-before and (edit) starts a new series
  at the occurrence carrying the edits + recurrence, partitioning exdates
  past/future; delete-following just truncates. SW cache → `timecard-v44`.
- **v23** Discover/Invites connector foundation (calendar app; engine only, no UI
  yet). New **`connectors.js`** (`window.Connectors`, pure): config-driven source
  registry — `socrata` (SoQL + `{today}` + geo bounding-box/`haversineFeet`
  radius), `activenet` (CPD programs; age/center **post-filter** since server
  params are ignored), `ics` (reuses `parseEventsIcs`); `prepare`/`ingest`
  (+`postFilter`: date floor, geo radius, de-dupe). `DEFAULT_SOURCES` seeds the
  user's Chicago setup (park events curated to his parks, festivals ≤2 mi,
  block-party ≤1000 ft, ActiveNet ages 3–4 at center IDs 4/8/13/521/578).
  **`proxy/worker.js`** + `wrangler.toml` = the CORS tunnel (allowlist relay,
  CurbIntel pattern). Verified against LIVE Chicago data via a node harness (45
  real park invites; block parties filtered to ≤1000 ft). Loaded in index.html;
  SW cache → `timecard-v45`. Remaining: Dexie v3 `sources` + Invites lane UI +
  add-source form + LLM layer (see "Remaining build order").
- **v24** Discover/Invites — data layer + Invites lane. **Dexie v3** (additive):
  `sources` (seeded from `DEFAULT_SOURCES`, version-stamped) + `invites` (keyed
  by stable `externalId`, status pending|dismissed|accepted). Fetch loop
  `refreshInvites()` (Socrata direct, proxied via `proxyBase`, throttled 10 min);
  **Invites lane** on Metrics with PUSH count badge + per-invite Accept (→ event
  on its day) / Dismiss (+undo). All calendar-gated. SW cache → `timecard-v46`.
- **v25** Discover/Invites — generic adapter + add-source form. `connectors.js`
  refactored so a source = **fetch config + field-`map` + unified `filters`**;
  added the generic `json` adapter; `applyFilters` (date/horizon/geo/days/time/
  age/cost/category include+excludeKeywords/keyword/maxResults) + `socrataWhere`
  compiles filters → SoQL. `excludeKeywords` auto-strips private-permit noise
  (verified live: 37 clean park invites, 0 noise). **Add-source UI**:
  `#sourcesModal` (list/toggle/edit/delete) + `#sourceFormModal` (the schema as a
  progressive-disclosure form). Version-stamped re-seed (`DB.seedSources(.,2)`).
  SW cache → `timecard-v48`. Only the BYO-LLM layer remains.
- **v26** Google Calendar sync (calendar-mode only; the deferred "Phase 4"). New
  **`google.js`** (`window.GoogleCal`, pure): browser-only OAuth via Google
  Identity Services (token/implicit flow — no server, no client secret; the
  short-lived access token is cached + silently refreshed and **excluded from CSV
  export/import**), Calendar REST v3 calls (`listCalendars`/`listEvents`/
  `insert`/`patch`/`delete`), and pure `toGoogleResource`/`fromGoogleEvent`
  mappers (floating-local times carried with the viewer's IANA `timeZone`; RRULE
  rides verbatim; `singleEvents:false` keeps recurring masters as one row).
  **Two-way sync** of the user's events with their **primary** calendar
  (`googleSyncNow` → `pushLocalToGoogle` then `pullGoogleCalendar`, reconciled by
  the indexed `events.googleId`; cancelled remote events tombstone the local copy;
  a stored `gUpdated` stamp skips unchanged rows to avoid churn/loops). **Ritza's
  shared calendar** (a `googleRitzaCalendarId` Settings picker over the user's
  calendar list) is mirrored **read-only** into her person lane (rows `source:
  'ritza'`, non-draggable, dashed `.cal-ev.ro` style, tap → info toast) **and**
  surfaced in the Invites lane (accept → your own `source:'local'` event that then
  syncs up to your primary). Settings gains a calendar-only `#googleRow` (client
  ID input, Connect/Reconnect/Sync now/Disconnect, status line, Ritza picker).
  Background sync is throttled 10 min via `maybeSyncGoogle` (called from
  `renderAll` in calendar mode). DB: `eventByGoogleId`, `eventsBySource`,
  `LOCAL_ONLY_SETTINGS` (preserved across CSV import). Loaded after
  `connectors.js`; SW cache → `timecard-v49`. **Setup:** the user supplies a
  Google OAuth **Web** client ID with the site origin
  (`https://calebpaulsmith.github.io`) added as an authorized JS origin, and
  Ritza shares her calendar with the user's Google account.
  **Deferred:** ~~pushing local *deletions* up~~ (done v36); recurrence-override
  push; invites for recurring Ritza occurrences (only the master's first date
  emits one).
- **v27** Day-timeline slider UI/UX polish (user feedback). **Thinner sliders:**
  `.tl-bar`/`.tl-lunch` 16→10px tall (top 17→20), `.tl-handle` 13→10px, plus the
  matching `.schedule-strip` overrides — slimmer bars + knobs, same 36px `.tl-hit`
  touch target. **Edge auto-expand:** holding a handle within `EDGE_ZONE_PX` (30)
  of the strip edge now grows the scale on its own (one `SNAP_MIN` tick every
  `EDGE_STEP_MS`≈90ms) via a `requestAnimationFrame` loop in `attachHandleDrag`
  — no more jiggling back-and-forth to fire fresh pointermove events. The
  per-move body was factored into `constrain`/`applyMin`, shared by the
  pointer-driven move and the auto loop (`edgeDir`/`autoTick`/`maybeStartAuto`/
  `stopAuto`). **Leave in line with work:** `.tl-leave` moved from a thin bar
  *below* the work bar (top 35, 6px) up onto the work band (top 20, 10px) so it
  reads as a teal continuation to the right of the worked hours. SW cache →
  `timecard-v52`.
- **v28** Overtime rework (owner decision, federal-rule grounded — see
  `LOGIC-FREEZE.md` §4, freeze revision **F2**). Maxiflex OT now counts **leave
  toward the 80-hour gate** and **leave fills the daily schedule** before work
  spills to "beyond" (built in BOTH apps). Adds **credit hours**: a per-entry
  `payKind` (`auto`/`autoCredit`/`overtime`/`credit`/`regular`) routes
  beyond-schedule, over-80 hours to OT *or* a banked credit total (1:1, no
  premium), with a per-period `creditDefaultOverrides` flag stamping the default
  on NEW entries only (never reclassifies existing). Built in iOS first
  (PR #66/#69). Phase 2 (not built) = credit-hour running balance + the 24-hour
  carryover-cap warning.
- **v29** PWA mirror of the credit-hours feature (parity with iOS). `app.js`
  `periodTotals` ported to the `payKind` engine (`splitMaxiflexDay` forced/auto
  split + the over-80 cap, now returning `credit`/`creditByDate`); `db.js` gains
  `entryPayKind` (legacy `isOvertime`→`payKind` migration on read), the
  `creditDefaultOverrides` settings helpers, and a CSV `PayKind` column (older
  exports fall back to the Overtime flag). UI: the entry modal's Overtime
  checkbox became a 5-option **Pay classification** select; entry rows tag
  OT (gold) / Credit (purple); the period header shows a purple credit stat; a
  per-period **"Overtime | Credit"** segmented control (Maxiflex only) writes
  the credit default; Metrics gains a "Credit this period" card. Day-level
  credit timeline segment deferred (as on iOS). SW cache → `timecard-v54`.
- **v30** Default-schedule editor fixes (user feedback). **Leave now renders on
  the strip:** `buildScheduleStrip` draws a teal `.tl-leave` segment on the
  day's own strip (same band as the work bar) — to the right of the worked
  hours on an enabled day, or anchored at the left edge for a pure-leave off
  day — so it's visually obvious **which day** the recurring leave belongs to
  and how much it is (previously leave only showed as the "Leave Nh" stepper
  text, with no on-strip cue). The leave bar follows the end handle live during
  drag, and `reflowList`'s scale-fit now includes `.tl-leave` so leave is never
  clipped off the right edge (helps the day view too). **Haptics on the
  schedule slider:** `addScheduleHandle` now buzzes on grab (`vibrate(8)`), on
  each 15-min snap notch (`vibrate(4)`, fired once per new notch via
  `lastBuzzMin`), and on release (`vibrate(8)`). New CSS override
  `.schedule-strip .tl-leave` (top 22/height 10, `pointer-events:none` so it
  never blocks the handles). SW cache → `timecard-v55`.
- **v31** Master **Credit hours** toggle (owner decision: default OFF so the
  credit feature is hidden unless opted in). New `creditHoursEnabled` setting
  (both apps). OFF → `effectivePayKind` maps `autoCredit`→`auto`,
  `credit`→`overtime` (extra hours all pay OT, `credit` always 0), and every
  credit surface is hidden (per-period Overtime|Credit control, credit stat,
  Metrics credit, entry classification → reverts to a plain OT checkbox/toggle;
  no Credit entry tags). Stored `payKind`s are preserved (non-destructive — flip
  it back and credit returns). iOS adds a `creditEnabled` param to
  `periodTotals` + a Settings toggle; PWA adds a Settings toggle + the
  `effectivePayKind`/`readEntryPayKind` helpers. Tests pin the collapse
  (`PeriodTotalsTests.testCreditDisabledCollapsesToOvertime`).
- **v32** Credit-hour **banking** (Phase 2). Pure credit-bank fold (iOS
  `Domain/CreditBank.swift` `creditBankFold`/`creditBankSlot`, cap 24h; PWA
  `T.creditBankFold`) accrues per-period earned credit into a running balance,
  forfeiting anything over the 24-hour carryover cap; surfaced in the Metrics
  **Credit-hour bank** section (balance + over-cap warning). A **"Use credit
  hours"** spend control at the bottom of the entry adder draws the balance down
  like leave (records a credit-debit, gated behind `creditHoursEnabled`). Built
  in both apps. Tests: `CreditBankTests`.
- **v33** iOS **local notifications** (Phase 7, first native bet — iOS only; the
  PWA can't schedule reliable local notifications). Pure
  `Domain/ReminderSchedule.swift` `buildReminders` computes a validation-deadline
  nudge, a period-ending "you're N h short of 80" heads-up (day before, only when
  short), and a forgotten-clock-out reminder (9h after clock-in); thin
  `Platform/Reminders.swift` schedules them via `UNUserNotificationCenter` (stable
  per-kind ids). A **Reminders** Settings toggle (`remindersEnabled`, default off)
  requests auth + schedules; refreshed on launch/foreground + clock in/out. Tests:
  `ReminderScheduleTests`. No PWA counterpart.
- **v34** Calendar events become **day-centric** (iOS first, in 3 phases; PWA
  mirror for the schedule piece). **Phase 1 (iOS):** tapping a day card on the
  pay-period view **expands its events in place** below the work timeline — a
  lane-packed mini-timeline of timed events + all-day chips, tap-to-edit,
  quick-add (`Features/Period/DayEventStrip.swift`; `PeriodViewModel` resolves
  events per day; the `EventEditView` sheet generalized over a new `EventEditing`
  protocol so it drives either the Calendar tab or the period view). **Phase 2
  (iOS):** the Calendar tab is now a clean **agenda overview** — only days with
  events, no inline add buttons, plus an empty state. **Phase 3 (both apps):**
  the default-schedule editor gains a **Recurring events** section for biweekly
  series (`FREQ=WEEKLY;INTERVAL=2`) anchored to a day-of-period — iOS
  `ScheduleEventEditView` (day-of-period picker) + `ScheduleViewModel` helpers;
  PWA `renderScheduleRecurring()` (list + day-of-period select → reuses the event
  modal pre-set to biweekly). All calendar-mode-gated; timecard mode untouched.
  SW cache → `timecard-v58`.
- **v35** Optional **work-schedule → calendar sync on a limited forward window**
  (both apps; off by default). Distinct from event sync: user-added events still
  sync **for all time**, but the *work schedule* is pushed only for a bounded,
  rolling window of **N pay periods** (user-set, default **2** = this period +
  next) and can target a **separate calendar** from the one events sync to. The
  schedule is materialized from the **default schedule** (work shifts + recurring
  leave; recorded holidays override the day to an all-day "Holiday" with no work)
  by a new **pure** helper — PWA `T.buildScheduleSyncEvents`, iOS
  `Domain/ScheduleSync.swift` `buildScheduleSyncItems` — emitting plain,
  **non-recurring** dated items (unlike the infinite-RRULE `buildScheduleIcs`),
  keyed `w:`/`l:`/`h:`+date. Each sync reconciles desired-vs-pushed against a
  **local-only** bookkeeping map (`scheduleSyncMap` = `{ calendarId, items:{ key:
  {id,sig} } }`): insert new, patch changed (by signature), and **delete** items
  that rolled out of the window or left the schedule — so the calendar never
  carries the schedule beyond the window, and changing the target calendar
  migrates cleanly. New settings (both apps): `scheduleSyncEnabled` (bool, off),
  `scheduleSyncCalendarId` (target; '' = primary/events target),
  `scheduleSyncPeriodsAhead` (default 2). PWA: `syncScheduleToGoogle` /
  `cleanupScheduleSync` in `googleSyncNow` (REST, Google) + a Settings
  schedule-sync block in `#googleRow` (toggle, calendar picker, periods input).
  iOS: `EventKitSync.syncSchedule` folded into `sync()` (EventKit) + a
  **Settings › Work schedule sync** section (toggle, calendar picker, pay-periods
  stepper). Calendar-mode-gated; timecard mode stays network-free. Tests:
  `TimecardTests/ScheduleSyncTests.swift` (window span, work/leave/holiday items).
  SW cache → `timecard-v59`.
- **v36** Fix: **deleted calendar events resurrected on the next Google sync**
  (PWA; the v26-deferred "push local deletions up"). Before, deleting an event
  only removed the local row, so `pullGoogleCalendar` re-created it from the
  still-present Google copy. Now a user delete of an event with a `googleId`
  records a **tombstone** — new **Dexie v4** `deletedEvents` table (PK `googleId`,
  local-only, not in CSV) via `DB.deleteEventAndSync`. `googleSyncNow` runs
  `pushDeletionsToGoogle` **before** the pull: it DELETEs each tombstoned remote
  event and clears the tombstone (also on 404/410 = already gone); a failed
  delete keeps the tombstone and the pull **skips** that id so it can't
  resurrect. `DB.upsertEvent` clears any matching tombstone, so delete→undo and
  legitimate remote re-adds restore cleanly. All user event-delete paths
  (`deleteEventFromModal`, `resolveRecurChoice` all/non-recurring, `deleteCalEvent`,
  the schedule-recurring + backlog deletes) route through `deleteEventAndSync`.
  Whole-event and whole-series deletes propagate; single-occurrence (exdate)
  propagation still rides the deferred recurrence-override push. SW cache →
  `timecard-v60`.
