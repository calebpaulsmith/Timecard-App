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
- **OT pay multiplier:** `OT_MULTIPLIER = 1.5` (FLSA standard). OT $ stats
  only render when both OT mode is on and `hourlyRate > 0`.
- **Pace:** expected hours by day N = `80 * (N+1) / 14`. Status is `ahead`
  if worked > expected + 2, `behind` if < expected − 2, else `on-pace`.
  The 2-hour deadband prevents flickering.

## UI views

The main carousel is **2 pages**: Week 1 / Week 2 of the viewed period
(`state.viewedPage` 0 = Week 1, 1 = Week 2). The old Home page was removed;
its hero + stats + clock controls were redistributed:

- **Clock In/Out** lives inline on **today's day card** (`buildTodayClockRow`
  appended by `buildDayCard` only when `d === todayStr`).
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
   ✓ after the day name. Today's card carries a right-edge **"Timestamp"
   side tab** (`buildDayCard` → `buildTimestampTab`) — the renamed,
   restyled Clock In/Out, green + pulsing while clocked in.
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
3. **Day Editor** — summary, entry list (edit/delete each), "+ Add Entry"
   modal with quarter-hour selects (NOT `<input type="time">`, which doesn't
   give us 15-min granularity on iOS), leave +/− counter.
4. **Settings** — anchor date (must be a Sunday), default OT mode toggle
   (per-period overrides win), hourly rate input, 24-hr time toggle,
   default schedule editor, validation-deadline picker, CSV import/export.

### Per-period OT mode

The OT mode is **per pay period**, not global. Lookup is
`otModeForPeriod(period)` → `overrides[periodStartDate] ?? otModeDefault`.

- Settings toggle writes `overtimeModeDefault`.
- There is **no visible per-period control**. The override is toggled by a
  **long-press on the period name** (`attachLongPress` → `onTogglePeriodMode`)
  — an intentional backdoor. It writes `overtimeModeOverrides[start]`, or
  **clears** the override when toggled back to the current default.
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
