# Maxiflex Time Tracker — PWA Spec

A personal iPhone-friendly Progressive Web App for tracking hours on a federal maxiflex schedule (80 hours per biweekly pay period).

## Goals

- Clock in / clock out with one tap.
- Manually add or edit time entries for any day in the current pay period.
- Add leave hours (any type that counts toward the 80) with a single button press per hour.
- Always show how many hours are left in the current pay period, plus a pacing number.
- Feel native on iPhone. No sign-up, no backend, no friction.

## Non-goals (v1)

- Differentiating leave types (annual / sick / comp / credit). User only enters leave that counts toward the 80.
- Multi-user support, accounts, or sync across devices.
- Exports, reports, or historical analytics beyond the current pay period.
- Notifications (see "Future add-ons").

---

## Core Rules

### Pay period

- Biweekly, 80 hours required per period.
- Each pay period is fully independent — nothing carries over, no deficits, no surplus.
- The app needs a configurable **anchor date**: a Sunday that is known to be the first day of a pay period. All subsequent pay periods are computed as 14-day windows from that anchor.
- "Today's pay period" is derived from the current date and the anchor.

### Clock in / clock out

- Tapping "Clock In" records the current time (rounded to the nearest quarter hour) as the start of a new entry for today.
- Tapping "Clock Out" records the current time (rounded to the nearest quarter hour) as the end of that entry.
- Lunch deduction: if the total elapsed time between clock-in and clock-out is **4 hours or more**, automatically deduct **30 minutes** from the entry's total. Do not deduct if the entry is under 4 hours.
- **Forgotten clock-out rule**: if an entry has a clock-in but no clock-out, and more than **16 hours** have elapsed since the clock-in, the entry is flagged as "incomplete." It appears in the entry list with no end time and contributes **0 hours** to the pay period total. The user must go in and manually edit it to fix it.

### Leave

- A single "Add leave hour" button on a given day adds 1 hour of leave to that day.
- Tapping again adds another hour. Leave is stored as a simple integer count per day.
- Leave hours count toward the 80-hour pay period total.
- User can remove leave hours the same way (decrement button, or edit the day).

### Rounding

- All times are rounded to the **nearest quarter hour** (0:00, 0:15, 0:30, 0:45).
- Rounding happens at clock-in and clock-out. Stored entries are already rounded.
- Display totals as decimal hours to one decimal place (e.g., 7.5 hrs), not as H:MM.

---

## Headline Number (the hero view)

The home screen leads with the most actionable number: **hours left to work in the pay period.**

But alongside it, show a small cluster of supporting numbers that make it actually useful:

- **Hours worked so far** in this pay period (clocked + leave).
- **Hours remaining** to hit 80.
- **Days remaining** in the pay period (including today).
- **Pace**: average hours per remaining day needed to hit 80. Example: "Average 6.5 hrs/day to finish on time."
- **Today's total**: hours clocked today so far, including any in-progress entry.
- **Projected finish time**: if the user is currently clocked in, and wants to hit 8 hours today, when can they clock out? (e.g., "Clock out at 4:45 PM to hit 8 today.")
- **Status indicator**: a subtle badge — "On pace," "Ahead," or "Behind" — based on whether hours-worked-so-far is >= expected at this point in the period.

These supporting numbers should feel glanceable, not cluttered. Big hero number, small supporting stats below it.

---

## Screens

### 1. Home / Dashboard
- Giant hours-remaining number at the top.
- Supporting stats cluster below it.
- Big "Clock In" / "Clock Out" button (state-dependent — shows current state clearly).
- If clocked in: show clock-in time and running total for current entry.
- Quick-access "Add leave hour for today" button.
- Link/tab to the pay period detail view.

### 2. Pay Period Detail (the scrolly view)
- Vertical scroll showing all 14 days of the current pay period.
- Each day is a card showing: date, day of week, total hours (clocked + leave), and a breakdown of individual entries.
- Today is visually distinct (highlighted or anchored at top on load).
- Tap any day to open the Day Editor.
- Small "+" on each day for a quick leave-hour add without opening the editor.

### 3. Day Editor
- Shows all entries for that day.
- Each clocked entry: start time, end time, computed total, edit and delete affordances.
- Leave counter for the day with +/- buttons.
- "Add entry" button to manually add a start/end time pair.
- Time pickers snap to quarter hours only.

### 4. Settings
- Pay period anchor date (the known-good Sunday).
- That's pretty much it for v1.

---

## Data Model

Minimal. Three things to store.

**TimeEntry**
- `id` (uuid)
- `date` (YYYY-MM-DD, the date the entry belongs to)
- `startTime` (ISO timestamp, rounded to quarter hour)
- `endTime` (ISO timestamp or null if in-progress / incomplete)
- `lunchDeducted` (boolean, computed on close)
- `incomplete` (boolean, true if >16h elapsed with no end time)

**LeaveDay**
- `date` (YYYY-MM-DD, primary key)
- `hours` (integer, count of leave hours for that day)

**Settings**
- `anchorDate` (YYYY-MM-DD, a Sunday)

---

## Tech Stack

- **PWA** — HTML + CSS + JavaScript, installable to iPhone home screen.
- **Framework**: vanilla JS is fine; React or Svelte if preferred. No SSR needed.
- **Storage**: IndexedDB via [Dexie.js](https://dexie.org/) wrapper. Gives schema, queries, and async/await ergonomics without the raw IndexedDB pain.
- **Service worker**: for offline support and home-screen install. Cache the app shell so it opens instantly with no network.
- **Manifest**: `manifest.json` with proper icons, theme color, display: "standalone" so it opens fullscreen from the home screen.
- **Hosting**: any static host works (GitHub Pages, Netlify, Vercel, Cloudflare Pages). HTTPS required for PWA install and service workers.

---

## Design / UX Principles

- One-tap primary actions. Clock in/out and "add leave hour" should never be more than one tap from the home screen.
- Big, thumb-sized buttons. This gets used in a rush.
- Quarter-hour time pickers only — never show minutes dropdowns with all 60 values.
- No confirmation modals for routine actions. Use undo toasts instead.
- Respect iOS system dark mode.
- Haptic feedback on clock in/out (via `navigator.vibrate` where supported).

---

## Edge Cases to Handle

- Clock in when already clocked in → ignore, or prompt "end current entry first?"
- Clock out when not clocked in → disabled button, or no-op.
- Entry that spans midnight → store against the date of the clock-in.
- User changes the anchor date after entries exist → recompute which pay period each entry belongs to; don't delete anything.
- Time zone changes (user travels) → store in local time, assume device time zone is source of truth.
- User clocks in, app is closed, phone restarts → on app reopen, check for any in-progress entry and restore the running clock state.

---

## Future Add-ons (v2+)

- **iCloud / CSV export** for backup and historical review.
- **Notifications**:
  - "You've been clocked in for 9 hours, did you forget to clock out?"
  - "Pay period ends tomorrow, you're X hours short."
  - iOS PWA notifications work but are limited — reliable only if the PWA is installed to home screen and iOS 16.4+. Local scheduled notifications are flaky; consider an iOS Shortcut or a tiny push server if this becomes important.
- **Historical pay periods** — view past periods, see if you hit 80.
- **Leave type tracking** (annual / sick / credit / comp) if the user ever wants richer data.
- **Projected pay period completion** based on typical daily pattern.
- **Widgets** — iOS home screen widget showing hours remaining. Requires native, not PWA.
