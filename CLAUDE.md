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

## Stack & file layout

No build step. All files at project root, served as-is. Loaded by classic
`<script>` tags (NOT modules).

| File | Role |
| --- | --- |
| `index.html` | App shell. Four `<section>`s (home, period, day, settings) toggled via `body[data-view=...]`. Registers the service worker. |
| `styles.css` | iOS-flavored styles, dark mode via `prefers-color-scheme`, safe-area insets. |
| `time.js` | Pure helpers: rounding, pay-period math, OT split, formatters. Exposes `window.TimeUtil`. **No DOM, no DB.** |
| `db.js` | Dexie schema + data-access helpers. Exposes `window.DB`. |
| `app.js` | UI layer: rendering, event handlers, view router. Wrapped in an IIFE — see "Script-scope landmine" below. |
| `sw.js` | Service worker: cache-first for app shell, network-first fallback. |
| `manifest.json` | PWA manifest (`display: standalone`, theme color, icons). |
| `icons/icon-{192,512}.png` | App icons. |
| `.nojekyll` | Stops GitHub Pages from running Jekyll on the repo. |

## Data model (Dexie v1)

```
entries: { id (uuid), date (YYYY-MM-DD, indexed), startTime, endTime, lunchDeducted, incomplete }
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
- `hourlyRate` — number (USD/hr), default 0.
- `metricsRange` — `'8pp' | 'ytd' | '6mo' | '1yr'`, default `'8pp'`. Selected
  range for the Recent OT chart on the metrics view.

## Behavioral rules (from spec, baked into `time.js`)

- **Rounding:** clock in/out times round to the nearest 15 minutes.
- **Lunch deduction:** any entry spanning ≥ 4 hours has 0.5 hours auto-deducted.
- **Forgotten clock-out:** if an open entry has been open > 16 hours,
  `getOpenEntry()` marks it `incomplete: true` and returns null. Incomplete
  entries contribute 0 hours and surface in the day editor for manual fix.
- **OT (8-hour mode):** `worked - 8` per day, but only when the period's
  resolved OT mode is on (per-period override beats the settings default).
  Lunch deduction is applied first, so 8.5 clocked = 8.0 paid = 0 OT. OT is
  computed per-day and summed per-period. **Weekend exception:** ALL hours
  worked on a Saturday or Sunday are overtime (`overtimeSplit`'s third
  `isWeekend` arg) — not just hours past 8.
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
- **OT color:** overtime renders **golden yellow** (`--ot` / `--ot-text`),
  with a glow + shimmer on timeline OT bars and a gold "OT" tag in the day
  editor — deliberately flashier than the calm blue regular bars.
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

`buildDayTimeline(dateStr, entries, dayLeave)` draws a leave-colored `.tl-leave`
strip extending right from the end of the last work entry, length = leave
hours. Visual only — no drag handles. Recomputed on every render.

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
swatches, all-day, quarter-hour start/end, Repeat preset + Until, backlog
toggle, location, notes). Edit/delete of a recurring occurrence routes through
`#recurChoiceModal` (this/all): *this* = exdate + override row, *all* = edit/
delete the series. The **backlog** renders on the Metrics view
(`renderBacklogInto`). Per-period/day OT and all timecard math ignore events
entirely.

**`.ics` / CSV:** `Calendar.buildEventsIcs`/`parseEventsIcs` (RFC-5545, RRULE
travels verbatim, floating-local times) behind the Settings **Calendar events
(.ics)** row (calendar mode only). The CSV backup gained `EVENTS` +
`EVENT_HISTORY` sections (round-trips events too).

**Deferred (later phases):** Google sync (Phase 4, token-broker + Tier-3
`calendar.app.created`); BYDAY multi-day picker, COUNT UI, "this and following".

## Planned refinements (calendar UI + OT) — NOT yet implemented

Captured from user feedback for a later pass (do **after** the remaining phases
are implemented). These are intent/spec notes — none of this is built yet.

### Interaction & sizing
- **The day "peek" (tap-to-expand) is too big / clunky / borderline pointless.**
  Keep the expand, but make it **small and quick**: just enough extra height to
  reveal the event labels — no large panel-like jump. Today
  `.day-card.cal.expanded .timeline-wrap { min-height: 156px }`; shrink that a
  lot so it reads as a snappy label reveal, not a drawer.
- **Drag grab-bars are too large.** Shrink `.cal-ev-handle` (currently 16px wide
  and event-height + 6 tall) to a subtler grip.

### Leave bar
- Render leave as a **thin bar just BELOW the work bar** — the exact mirror of
  the person lanes (which hug the bar from *above*). Thinner than today and a
  **more distinctive color**. Replaces the current "leave extends the work bar to
  the right" treatment (`.tl-leave`). In the calendar overlay it's a "below" lane
  analogous to the `--person-*` vars but a `--leave-*` band sitting under
  `--me-bottom`.

### Overtime — redefinition (decided with the user)
- **8-hour mode:** OT = **hours worked beyond that day's scheduled hours** —
  `max(0, worked − scheduledHoursForIndex(day))`, **ungated** (no >80 gate, no
  hard 8h floor). A normal 8h-scheduled day still yields `worked − 8`; weekends /
  off days have 0 scheduled hours, so **all** their worked hours stay OT (today's
  weekend-all-OT behavior is preserved). This replaces `overtimeSplit`'s fixed-8
  rule inside `periodTotals`. ("Over 8" in the user's wording is just descriptive
  — a normal scheduled day is ~8h.)
- **Maxiflex mode:** **keep the current math** (explicit `isOvertime` + work
  outside the schedule once the period passes 80h) **and** also paint it with the
  intense OT color. So both modes show the OT color when OT > 0.
- **Holiday** unchanged: all worked-holiday hours are OT, paying 2× when
  double-time. The app only models the OT **premium** dollars (`otDollars`),
  never gross pay; leave carries no dollar figure.
- OT is recomputed live (nothing is stored), so this **retroactively** changes
  historical OT hours / OT $ / YTD — **accepted**.
- **Rendering:** the OT portion of a day should paint as a distinct **intense,
  natural-toned** segment **inline within the work bar** (same line as regular
  work) — i.e. split the work bar into regular + OT segments by the day's OT
  amount. Applies in both modes when OT > 0.

### Color semantics (palette by MEANING, not hex) + future theme menu
Goal: **mega-easy at a glance** — a small, high-contrast, colorblind-distinct
set. Define every token by **what it represents**; the actual hex is only the
default theme and must stay swappable, because the user wants a future
**menu of color schemas** to pick from. Keep all visuals keyed to these semantic
tokens so a theme is just a hex remap (no layout/logic changes):

- **My time — work** (`--cal-work`): the calm baseline of the main bar; neutral,
  low-energy "this is my routine work."
- **My time — personal** (`--cal-personal`): also rides the main bar but a
  **distinct color** from work (already distinct today — keep it) — still "me,"
  but a warmer/friendlier tone so work vs personal reads instantly.
- **Overtime** (`--ot` / `--ot-deep` / `--ot-text`): same line as work, but
  **more intense and a natural color** (ember / amber / rust — heat = extra
  effort); the most saturated token in the set. Reads as "beyond plan."
- **Person — Ritza** (`--cal-ritza`) / **Person — Amelia** (`--cal-amelia`):
  each person their own distinct, colorblind-separable hue; thin lanes hugging
  the bar from above. **Color = who; label = what** (never the person's name).
- **Leave / time-away** (new `--cal-leave`): a restful, cool tone (away, not
  working) — distinct from work AND from the person colors; the thin bar just
  below the main bar.
- **Holiday** (`--holiday`): a festive/special-day accent (pink today), distinct
  from leave.

Theme menu (future, wanted): a Settings picker that swaps the underlying hex set
(e.g. "Natural", "High-contrast", "Muted") while every component keeps
referencing only the semantic tokens above.

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
  BYDAY multi-day picker, COUNT UI, and "this and following". SW cache →
  `timecard-v40`.
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
