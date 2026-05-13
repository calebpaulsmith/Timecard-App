# Timecard App — Requirements

This file is the human-readable spec for what the app should do, gathered
from the user's requests across the build. Engineering notes (architecture,
gotchas) live in `CLAUDE.md`; the user-facing spec for the original
biweekly maxiflex math lives in `maxiflex-tracker-spec.md`.

## Identity

- App name is **Timecard App**. The previous "Maxiflex" branding has been
  retired from all user-visible surfaces (page title, manifest, app header,
  CSV header, export filename).
- The IndexedDB database is still named `MaxiflexTracker` internally — never
  rename it, because doing so would orphan all existing user data.
- Available as a Progressive Web App at the GitHub Pages URL; designed to be
  installed to a phone home screen.

## Pay-period model

- Federal **maxiflex biweekly** schedule: 80 hours over 14 days.
- The pay period is anchored to a Sunday. **Default anchor: Sunday,
  May 3, 2026.** User can change it in Settings (must be a Sunday).
- Pay-period names use the `YYYY-PPNN` convention; `YYYY` is the year the
  period starts in, `PP01` is the first anchor-aligned period whose start
  is on/after Jan 1 of that year.
- Paydate = period end + 12 days. YTD bucketing uses the paydate year (so
  a period ending Dec 27 with paydate Jan 8 counts toward the *next* year).

## Behavioral rules

- Times are stored at **15-minute granularity** (clock-in/out round to the
  nearest quarter hour).
- A **30-minute lunch is auto-deducted** for any entry whose clock-in to
  clock-out span is ≥ 4 hours. The lunch is editable per-entry and persists
  exactly as set; the auto rule only applies when the user hasn't set a
  value.
- 3/4 of an hour displays as **0.75**, not 0.8. Quarter-precision values
  always render exactly; arbitrary floats trim trailing zeros.
- Forgotten-clockout: an open entry older than 16 hours is marked
  `incomplete`, contributes 0 hours, and surfaces in the day editor for
  manual fix.
- **OT (8-hour mode):** `max(0, worked − 8)` per day, summed per period.
  Lunch is deducted first, so 8.5 clocked = 8.0 paid = 0 OT.
- **8-hour mode is on by default** for fresh installs (existing users keep
  whatever they had).
- **Days left** in the dashboard counts Mon–Fri remaining in the current
  period only (weekends don't count toward the 80-hour target).

## Default schedule

- A "default schedule" lays out a full **14-day pay period** with each
  day's start/end times (and which days are off). It's the user's typical
  workweek replicated across both weeks of the period.
- Schedule slot shape: `{ enabled, startMin, endMin }`. Slot times persist
  even when the day is toggled off, so re-enabling restores the user's
  previously entered hours instead of falling back to 9–5.
- **Fresh-install default:** Mon–Fri enabled at 9:00 AM – 5:30 PM (an
  eight-hour day with a 30-min lunch). Weekends off.
- Saving the schedule lets the user optionally **apply** it to upcoming
  periods, which overwrites the work entries on enabled days for 26 periods
  (~1 year). Leave hours are never touched.
- A toggle controls whether the current period is included in the
  overwrite (defaults to "include").
- Each row in the schedule editor has a **"copy this day to all
  weekdays"** action that propagates the row's enabled state and times to
  every weekday slot in both weeks (Mon–Fri × 2 = 10 days).

## Pay-period view (primary screen)

- The app **lands on the Pay Period view**, not a home dashboard. A home
  icon in the top-left navigates to the dashboard for stats; a gear icon
  in the top-right opens Settings.
- Only **Mon–Fri** are shown by default. Saturday and Sunday hide behind
  small `+ Add Sunday` / `+ Add Saturday` reveal buttons. The reveal
  preference is persisted.
- Each pay period is shown **one week at a time** with **Week 1 / Week 2
  tabs** and **horizontal swipe** navigation. Swiping past either end
  wraps into the adjacent pay period (never into the future beyond
  today's period).
- The swipe area covers the **entire period view**, including the empty
  space below the day list, so the user can swipe anywhere.
- Prev / next chevrons at the top step by whole pay period (and reset to
  week 1).
- Layout is **compact enough that all five weekday cards fit on one
  phone screen** without scrolling (weekends hidden). Scroll appears only
  when weekends are revealed.
- **OT renders inline with the daily hours total** ("8 hr +0.5") instead
  of on a new row, so toggling OT doesn't expand the card height.

### Day card

- Header row: weekday name + date · total hours (inline OT) · Leave
  stepper.
- **Leave stepper** is explicitly labelled "Leave N" with `−` and `+`
  buttons. The `−` is disabled when leave is 0. (Replaces the earlier
  ambiguous `+` button that only added leave.)
- Below the header: an inline horizontal **timeline strip** showing each
  entry as a colored bar from start to end. Lunch shows as a hatched
  gap of actual lunch-minute width inside the bar.
- Each bar has draggable handles at start and end. **Persistent time
  pill labels** show the start and end times at all times (not just
  during drag). Labels are clamped to stay on screen at the strip edges.
- Tapping anywhere on a day card (other than a handle / button) opens
  the full day editor view.
- The **timecard validation day** (if set in Settings) is marked with a
  warning-colored left border and a small ✓ next to the weekday name.
- When the user opens the day editor for the validation day, a banner
  reading **"Timecard validation due"** appears at the top.

## Timeline slider behavior

- Hard time bounds: **4:30 AM – midnight**.
- Default visible scale: **6 AM – 6 PM**. Auto-fits per-render to include
  any entry's extremes.
- **Shared scale** across all strips on a page — when one strip's handle
  pushes past an edge, every strip on the page expands together. During a
  drag the scale only **expands** (never contracts under the user's
  finger); on release it settles to the tightest fit.
- **Non-linear core compression:** the 9 AM – 2:30 PM core zone occupies
  only ~30% of the strip width. Edge hours (where the user actually adjusts
  start and end times) get ~70%. Result on a default scale: ~9 px per
  15-min tick at the edges, ~4–5 px through the routine midday.
- Drag end-handle is capped one snap-tick before midnight (23:45) so the
  slider can't roll an entry over into the next day. Existing next-day
  endTimes (set via the modal) render at the far-right edge of the strip.
- **15-minute snap.** Pointer-position math (not pixel-delta) so the
  handle tracks the finger across scale changes.
- **No text-selection or long-press loupe** while dragging. `user-select`
  and `-webkit-touch-callout` are disabled on the timeline and all its
  children.
- Releasing a handle **does not scroll the page**.

## Day editor view

- Lists entries for the day with edit/delete per entry.
- "+ Add Entry" opens a modal with quarter-hour `<select>`s for start
  and end times, plus a **Lunch (minutes)** dropdown (0, 15, 30, 45, 60,
  75, 90, 120) and an "ends next day" checkbox.
- Leave +/− buttons.
- A **"Copy to other weekdays in this period"** action propagates the
  day's entries (with times and lunch) AND leave hours to every other
  weekday in the current period, overwriting whatever was there.
- The validation-banner appears here when the day is the validation day.

## Validation deadline

- Settings → "Timecard validation deadline" lets the user pick any of
  the 14 pay-period days (labelled by weekday and week number) or *None*.
- The pick is by day-of-period index, so it **persists across all
  periods** (e.g., always "the second Thursday").
- Subtle visual cue: warning-colored left border on the day card plus a
  small ✓ next to the weekday name. Non-intrusive.
- Day editor view shows the "Timecard validation due" banner.

## Settings

- **Pay-period anchor** (must be a Sunday).
- **8-hour shift mode** toggle (default on).
- **Straight-time hourly rate** (used for OT pay; OT pays at 1.5×).
- **24-hour time** toggle. When on, all displays AND the entry modal's
  time selectors use 24-hour format.
- **Default schedule** (opens its own view).
- **Timecard validation deadline** picker.
- **Backup & restore** — Export CSV / Import CSV.
- **Danger zone** — red "Clear all data" button with a two-step
  confirmation, wraps the wipe in a Dexie transaction so a mid-way
  failure rolls back.

## Toggles

- Big OFF (gray) and ON (vivid green) states with embedded `OFF` / `ON`
  text labels inside the track so the state is unmistakable. Applied
  both to Settings toggles and to the small per-day Schedule toggles.

## CSV format (savegame)

- Single `.csv` file with named sections marked by `# Section: NAME` rows
  so a manager can open it in Excel and read the timecard, AND the same
  file imports back to restore everything.
- Sections, in order: `SETTINGS`, `DEFAULT_SCHEDULE`, `ENTRIES`, `LEAVE`.
- Settings serialize via `JSON.stringify` so strings, booleans, and
  numbers round-trip exactly.
- `DEFAULT_SCHEDULE` is 14 rows keyed by `PeriodDay` (0..13) with the
  weekday name for readability, an `Enabled` yes/no, and `StartTime` /
  `EndTime` in `HH:MM`.
- `ENTRIES` includes a `LunchMin` column and an `EndDate` column for
  entries spanning midnight.
- Import is header-aware: it accepts the current format AND a legacy
  7-row weekday-keyed `DEFAULT_SCHEDULE` (back-compat).
- Import is wrapped in a Dexie `rw` transaction so a parse/write failure
  rolls back. After import, in-memory state and UI are reloaded.
- Export filename pattern: `timecard-export-YYYY-MM-DD.csv`.

## Persistence

- The app calls `navigator.storage.persist()` on startup to ask the
  browser not to evict storage. (Granted silently on installed PWAs.)
- Clearing browser history / website data on iOS, or removing the home
  screen icon, still wipes data — the user is reminded to export the CSV
  periodically as a true backup.
