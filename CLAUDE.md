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
- `overtime8hMode` — boolean, default false.
- `hourlyRate` — number (USD/hr), default 0.

## Behavioral rules (from spec, baked into `time.js`)

- **Rounding:** clock in/out times round to the nearest 15 minutes.
- **Lunch deduction:** any entry spanning ≥ 4 hours has 0.5 hours auto-deducted.
- **Forgotten clock-out:** if an open entry has been open > 16 hours,
  `getOpenEntry()` marks it `incomplete: true` and returns null. Incomplete
  entries contribute 0 hours and surface in the day editor for manual fix.
- **OT (8-hour mode):** `worked - 8` per day, but only when `overtime8hMode`
  is on. Lunch deduction is applied first, so 8.5 clocked = 8.0 paid = 0 OT.
  OT is computed per-day and summed per-period.
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

1. **Home** — hero "hours left this period" number, status badge, stats
   grid (worked / days left / pace / today / OT this period / OT $ /
   YTD OT $ / projected clock-out time), big Clock In/Out button, +1 leave
   shortcut, link to period detail.
2. **Period** — header with period name (e.g. `2026-PP08`) and paydate,
   prev/next chevrons, 14 day cards. Each card is tappable → Day Editor.
   Past-period nav goes back arbitrarily; forward nav is capped at the
   current period.
3. **Day Editor** — summary, entry list (edit/delete each), "+ Add Entry"
   modal with quarter-hour selects (NOT `<input type="time">`, which doesn't
   give us 15-min granularity on iOS), leave +/− counter.
4. **Settings** — anchor date (must be a Sunday), 8-hour shift toggle,
   hourly rate input.

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

1. Anchor → set to a known Sunday → home shows correct period window.
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
