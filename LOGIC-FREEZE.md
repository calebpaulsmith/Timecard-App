# LOGIC FREEZE — Timecard core (native port target)

> **Status: FROZEN as of 2026-06-21** for the native iOS port. This document is
> the single, authoritative behavioral spec of the **timecard core** (the free
> tier of the unified product). The Swift `Maxiflex` domain layer ports *this*.
> Source of truth is `REQUIREMENTS.md` + `CLAUDE.md`; this file extracts and
> pins the parts that must port unchanged.
>
> **Scope:** timecard core ONLY. Calendar mode, Google sync, Discover/Invites,
> and the LLM layer are NOT part of this freeze (calendar sync is a separate
> Pro-tier spec built on EventKit; Discover/LLM is excluded entirely).
>
> **Change policy:** once frozen, changes require an explicit decision + a bump
> of the "Freeze revision" below, so the Swift port tracks a stationary target.
> Freeze revision: **F2**.
>
> **Revision history:**
> - **F1** (2026-06-21) — initial freeze.
> - **F2** (2026-06-24) — **Overtime reworked** (owner decision, federal-rule
>   grounded). Maxiflex OT now counts **leave toward the 80-hour requirement**,
>   **leave fills the daily schedule** before work spills to "beyond," every
>   worked entry carries a **per-entry `payKind`** classifying its beyond-schedule
>   hours as overtime *or* **credit hours** (banked 1:1, no premium), and auto
>   premium is **capped at the hours actually over 80** (replacing a boolean gate
>   that over-counted — e.g. 5.75h OT at 81.75/80 → 1.75h). See §4 — the
>   canonical, change-able home for the OT math.

---

## 0. Constants (pin these exactly)

| Constant | Value | Meaning |
| --- | --- | --- |
| `ROUNDING_MINUTES` | 15 | Clock in/out round to nearest quarter hour. |
| `LUNCH_DEDUCT_MINUTES` | 30 | Auto-deducted lunch. |
| `LUNCH_THRESHOLD_HOURS` | 4 | Span ≥ this → auto lunch (when user hasn't set one). |
| `FORGOTTEN_CLOCKOUT_HOURS` | 16 | Open entry older than this → `incomplete`. |
| `PERIOD_DAYS` | 14 | Days per pay period. |
| `PERIOD_TARGET_HOURS` | 80 | Required hours per period. |
| `DEFAULT_ANCHOR` | `2026-05-03` (Sunday) | Default pay-period anchor. |
| `PAYDATE_OFFSET_DAYS` | 12 | Paydate = period end + this. |
| `OT_MULTIPLIER` | 1.5 | FLSA overtime pay multiplier. |
| `HOLIDAY_MULTIPLIER` | 2 | Worked-holiday double-time multiplier. |
| `PACE_DEADBAND_HOURS` | 2 | Ahead/behind threshold around expected. |
| `HOLIDAY_LEAVE_HOURS` | 8 | Leave auto-recorded on a federal holiday. |
| Default schedule | Mon–Fri 09:00–17:30, weekends off | 8h paid day (30-min lunch). |
| Timeline hard bounds | 04:30 – 24:00 | Editing range. |
| Timeline default scale | 06:00 – 18:00 | Auto-expands to fit entries. |

All hours display as **decimal to one place**; quarter values render exactly
(0.75, never 0.8); arbitrary floats trim trailing zeros.

---

## 1. Pay-period model

- Federal **maxiflex biweekly**: 80 hours over 14 days, each period fully
  independent (no carryover, deficit, or surplus).
- A period is a 14-day window aligned to a **Sunday anchor**. "Today's period"
  is derived from the current date + anchor. `payPeriodFor(today, anchor)`.
- **Naming `YYYY-PPNN`:** `YYYY` = year the period *starts* in; `PP01` = first
  anchor-aligned period whose start is ≥ Jan 1 of that year, counting up.
  - Example (anchor 2026-04-19): that period is `2026-PP08`; the period ending
    2025-12-27 is `2025-PP25`.
- **Paydate** = period end + `PAYDATE_OFFSET_DAYS` (12). Example: period ending
  2025-12-27 → paydate 2026-01-08.
- **YTD bucketing uses the PAYDATE year**, not the work-date year. So
  `2025-PP25` counts toward 2026 YTD (its check fell 2026-01-08).
- **DST safety:** when dividing elapsed ms by ms/day and comparing to integer
  day counts, **round to whole days first** (a DST transition can make a span
  off by an hour). See `payPeriodName` pattern.
- Changing the anchor after entries exist **re-buckets** entries into their new
  periods; nothing is deleted.

---

## 2. Time entries

Entry shape (logical): `{ id, date (YYYY-MM-DD), startTime (ISO), endTime (ISO|null),
lunchMinutes (int), payKind (enum: auto|autoCredit|overtime|credit|regular — see
§4.3; legacy `isOvertime` bool migrates: true→overtime), incomplete (bool),
fromDefault (bool), projectId (optional, Pro) }`.

- **Rounding:** clock in and clock out each round to the nearest 15 minutes at
  the moment they're recorded. Stored entries are already rounded.
- **Lunch:** if span (in − out) ≥ 4h, auto-deduct 30 min. Lunch is **editable
  per entry** and, once set, persists exactly; the auto rule only applies when
  the user hasn't set a value. (8.5 clocked = 8.0 paid.)
- **Forgotten clock-out:** an open entry (no `endTime`) older than 16h is
  flagged `incomplete`, contributes **0 hours**, and surfaces in the day editor
  for manual fix. `getOpenEntry()` performs this check and returns null for it.
- **Spans midnight:** store against the **clock-in date**; an explicit "ends
  next day" is allowed via the editor (renders at the far-right of the strip).
- **Hours for an entry** = `(end − start) − lunchMinutes`, in decimal hours.

---

## 3. Leave

- Per-day integer hour count. `+`/`−` stepper; `−` disabled at 0.
- Leave hours **count toward the 80**.
- Leave is never overwritten by applying the default schedule (work entries are;
  leave is preserved).

---

## 4. Overtime (two modes; per pay period)

OT mode is **per pay period**: `otModeForPeriod(period) =
overrides[periodStart] ?? otModeDefault`. The Settings toggle writes
`otModeDefault`; per-period overrides win. Default OT mode = **8-hour mode on**
for fresh installs. Switching a period 8h→Maxiflex when its OT > 0 prompts a
confirmation (the OT will drop from that period's stats/YTD/charts). Historical
periods are NOT retroactively rewritten when the default changes.

### 8-hour mode
- Per day: `OT = max(0, worked − scheduledHoursForIndex(day))`, **ungated** (no
  >80 gate, no fixed-8 floor). Lunch deducted first.
- Scheduled hours come from the **default schedule** for that day-of-period
  index. A normal 8h-scheduled day → `worked − 8`; a 10h day → `worked − 10`.
- **Unscheduled days (weekends / off days) have 0 scheduled hours → ALL their
  worked hours are OT.**

### Maxiflex mode (refined — F2; THIS is the canonical OT math)

**Why these rules (federal grounding).** Flexible/maxiflex OT = work over 8/day
or 40/week, *ordered in advance*; voluntary hours beyond 80 are **credit hours**
(banked 1:1, no premium, 24h carryover cap). Compressed (5-4-9/9-80) OT = work
*beyond the scheduled compressed hours* (a regular 9h day is not OT). **Leave**
is paid pay-status time that the owner's agency **counts toward the 80** but that
**never itself pays a premium**. Sources at the end of this section.

**Per-entry classification.** Every worked entry carries a `payKind`:

| `payKind` | Meaning |
| --- | --- |
| `auto` | engine decides; the entry's beyond-schedule (over-80) hours pay **overtime**. Default. |
| `autoCredit` | same, but those beyond-schedule hours **bank as credit** (no premium). |
| `overtime` | force the **whole** entry to overtime (ordered OT). |
| `credit` | force the **whole** entry to credit hours. |
| `regular` | force the **whole** entry to regular (never premium). |

**Per-day computation** (`worked_d` = Σ paid hours of the day's entries):
1. `overAmount = max(0, (Σ worked_d + Σ leave_d) − 80)` — the hours the period is
   **over 80**, with **leave counted** toward the 80. This is the **cap** on auto
   premium (step 4), and being an amount it subsumes the old boolean gate.
2. `cushion_d = max(0, scheduled_d − leave_d)`. **Leave fills the schedule
   first** (leave is "regular"); only work past the leave-reduced schedule is
   "beyond." (8h sched + 8h leave + 2h worked → the 2h is beyond.)
3. Forced `overtime`/`credit` entries pay their **whole** hours **uncapped** and
   sit **on top of** the schedule (they do NOT consume the cushion → no
   double-count).
4. The `auto`/`autoCredit`/`regular` ("flex") entries produce per-day candidate
   premium = beyond-cushion hours, allocated **latest-start-first**: `auto`→OT,
   `autoCredit`→credit, `regular`→stays regular. **Then the period's total auto
   premium is capped at `overAmount`, kept latest-first across the period** (the
   hours that put you over 80 are the most recent); anything beyond the cap
   reverts to regular. *This is the fix for the over-count: a period only 1.75h
   over 80 yields ≤ 1.75h of auto OT/credit, not the full sum of every
   beyond-schedule hour.*
5. **Worked-holiday** days override: all worked hours OT, 2× when `doubleTime`.

Two gates were evaluated and **rejected**: a **per-week-40 gate** (under-paid the
light week of a 5-4-9 when the period cleared 80) and a **boolean over-80 gate**
(over-paid — flagged every beyond-schedule hour once over 80, e.g. 5.75h OT at
81.75/80; the F2 **amount cap** replaces it). Regular long days stay non-OT
because they're *within schedule*; leave-only periods stay non-OT because the cap
is the over-80 *amount* and beyond-schedule work is still required.

**Toggle semantics (load-bearing).** The period credit-default
(`creditDefaultOverrides[periodStart]`, default off) sets only the `payKind`
**stamped on NEW entries** (`autoCredit` when on, else `auto`). Flipping it
**never** reclassifies existing entries — all classification is **stored per
entry** and user-editable.

### Worked scenarios (regression oracle — keep tests pinned to these)

Schedule = 5-4-9 (Week A 45h, Week B 35h). "Beyond" = work outside schedule.

| # | Setup | Period (w/ leave) | OT | Note |
| --- | --- | --- | --- | --- |
| S1 | Regular 5-4-9, no extra | 80 | 0 | within schedule |
| S2 | +4h beyond in heavy week | 84 | 4 | over 80 |
| S3 | Light week works 45 (10 beyond), A regular | 90 | 10 | light week still earns OT |
| S4 | Light week works 38 (3 beyond), A regular | 83 | 3 | over-80 grants it; no 40-gate |
| S5 | Over 80 via leave only, no beyond work | 84 | 0 | leave never makes OT |
| S6 | +4h beyond but period only 78 | 78 | 0 | under 80 → 0 |
| S7 | 9 days × 9h (9h beyond total), no leave | 81 | **1** | **cap**: OT = hours over 80, not the 9h beyond |
| S8 | 70h worked (14h beyond) + 12h leave | 82 | **2** | leave can't inflate OT past the over-80 cap |

Credit variants: the same "beyond" hours move from `ot` to `credit` when the
entry is `autoCredit`/`credit` (`otDollars` unaffected), and credit obeys the
same over-80 cap.

### Shared
- `periodTotals` is the single OT authority: returns `otByDate`, `ot`,
  **`creditByDate`, `credit`**, and `otDollars`. `dayTotals` / live totals read it.
- **Worked-holiday hours are OT in either mode**, paying 2× when `doubleTime`.
- **OT pay:** `otDollars` blends `OT_MULTIPLIER` (1.5×) and `HOLIDAY_MULTIPLIER`
  (2×) against `hourlyRate`. Credit hours carry **no** premium.
- **`total = worked + leave`** (the "/80" progress, hours-left, and pace read it).

### Status + Phase 2 (NOT yet built)
- **Built (both apps):** leave-in-80 + leave-fills-schedule + the **over-80
  amount cap** (PWA `app.js` + iOS `Domain/PeriodTotals.swift`).
- **Built (iOS Phase 1):** per-entry `payKind` classification + credit hours +
  entry-editor picker (PR #66) + the period **Overtime | Credit** toggle +
  credit surfaced in header/Metrics (PR #69).
- **Built (PWA mirror):** `periodTotals` now runs the same per-entry `payKind`
  engine (`splitMaxiflexDay` + the credit-aware over-80 cap pass) returning
  `credit`/`creditByDate`; entry modal **Pay classification** select; per-period
  **Overtime | Credit** segmented control (`creditDefaultOverrides`); credit
  surfaced in the period stat strip + Metrics; `payKind` rides the `entries`
  row + a CSV `PayKind` column (older rows/exports bridge via `isOvertime`).
- **TODO:** **Phase 2** = credit-hour running **balance** carried across pay
  periods + **24-hour carryover-cap** warning (both apps).

*Sources: OPM [Flexible](https://www.opm.gov/policy-data-oversight/pay-leave/work-schedules/fact-sheets/alternative-flexible-work-schedules/)
· [Compressed](https://www.opm.gov/policy-data-oversight/pay-leave/work-schedules/fact-sheets/alternative-work-schedules-compressed-work-schedules/)
· [Credit hours](https://www.opm.gov/policy-data-oversight/pay-leave/work-schedules/fact-sheets/credit-hours-under-a-flexible-work-schedule/)
· DOL [#22 Hours Worked](https://www.dol.gov/agencies/whd/fact-sheets/22-flsa-hours-worked)
· [#23 Overtime](https://www.dol.gov/agencies/whd/fact-sheets/23-flsa-overtime-pay).*

---

## 5. Federal holidays

- `federalHolidays(year)` computes the 11 OPM holidays for any year; fixed-date
  holidays shift Sat→Fri / Sun→Mon and are tagged "(observed)".
- `autoHolidays` (default **on**): records holidays across a [thisYear−1 ..
  thisYear+2] window — 8h leave on untouched days, schedule-seeded work removed.
- `holidays` map: `{ [YYYY-MM-DD]: { name, doubleTime, removed? } }`. `removed:
  true` is a tombstone (user un-recorded an auto holiday). Worked-holiday hours
  pay 2× when `doubleTime`.
- Day editor can add/remove a holiday and toggle "holiday worked → double time."

---

## 6. Default schedule

- 14 day-of-period slots. Slot shape: `{ enabled, startMin, endMin, leaveHours }`
  or `null` (never configured).
- `enabled` gates whether a WORK entry is seeded on apply. Slot times persist
  when toggled off (re-enabling restores them).
- `leaveHours` (≥ 0 whole hours) seeds recurring leave **independently** of the
  work toggle; on apply it overwrites a day's leave **only when > 0** (so manual
  leave on routine workdays survives).
- Fresh-install default: Mon–Fri 09:00–17:30, weekends off, 0 leave.
- **Apply** overwrites work entries on enabled days for **26 periods (~1 year)**;
  leave is never touched. A toggle controls whether the **current** period is
  included (default include). Holidays override (`holidaySet`): no work, 8h leave.
- Editor: per-row `Leave Nh` stepper; per-row "copy to weekdays" copies times AND
  leave to all 10 weekday slots.

---

## 7. Validation deadline

- Settings picks one of the 14 day-of-period indices, or None. Stored by
  **day-of-period index**, so it persists across all periods (e.g. "always the
  second Thursday").
- Cue: warning-colored left border + a small ✓ by the weekday name on the day
  card. Day editor shows a "Timecard validation due" banner on that day.

---

## 8. Dashboard / metrics math

- **Hero / supporting stats:** hours worked (clocked + leave), hours remaining
  to 80, days remaining, pace, today's total (incl. in-progress), projected
  clock-out to hit 8 today (when clocked in), status badge.
- **Pace:** expected hours by day N (0-indexed) = `80 * (N+1) / 14`. Status:
  `ahead` if worked > expected + 2; `behind` if < expected − 2; else `on-pace`
  (2h deadband prevents flicker).
- **Days left rule (`countWorkdaysRemaining`):** from today through period end —
  - Weekday (Mon–Fri): counts UNLESS it's a pure-leave day (0 worked AND leave
    entered).
  - Weekend (Sat/Sun): counts ONLY IF revealed for the period AND already has
    worked hours.
- **YTD stats** (hours worked, OT $) bucket by **paydate year**, each historical
  period using **its own resolved OT mode**.

---

## 9. CSV format (the backup + migration bridge)

- Single `.csv`, human-readable (a manager can open it in Excel) AND
  round-trippable. Sections marked `# Section: NAME`, in order:
  `SETTINGS`, `DEFAULT_SCHEDULE`, `ENTRIES`, `LEAVE` (+ `PROJECTS` once Projects
  ships; calendar `EVENTS`/`EVENT_HISTORY` exist in the PWA but are NOT part of
  the timecard-core freeze).
- `SETTINGS` values serialize via `JSON.stringify` (types round-trip).
  **Local-only secrets are excluded** (`googleClientId`, `googleToken`, `apiKey`).
- `DEFAULT_SCHEDULE`: 14 rows keyed by `PeriodDay` (0..13) + weekday name +
  `Enabled` (yes/no) + `StartTime`/`EndTime` (HH:MM) + `Leave`.
- `ENTRIES`: `Date, Day, StartTime, EndTime, EndDate, Hours, Lunch, LunchMin,
  Overtime, Incomplete, FromDefault, ID, PayKind` (the `Overtime` yes/no column
  stays for back-compat; `PayKind` is the authoritative new column, older exports
  without it fall back to the Overtime flag). (+ `ProjectId` once Projects ships.)
- Import is header-aware and back-compatible (accepts a legacy 7-row weekday
  schedule; tolerates missing newer columns/sections), and atomic (a parse/write
  failure rolls back).
- **This CSV is the migration path PWA → native.** The Swift app must import the
  current format exactly so existing data carries over.

---

## 10. Data model (logical → SwiftData)

```
TimeEntry { id, date, startTime, endTime, lunchMinutes, incomplete,
            payKind (auto|autoCredit|overtime|credit|regular), fromDefault, projectId? }
LeaveDay  { date (PK), hours }
Setting   { key (PK), value }              // typed JSON values
Project   { id, name, color, archived, createdAt }   // Pro; see REQUIREMENTS "Projects"
```

Settings keys that must port: `anchorDate`, `overtimeModeDefault`,
`overtimeModeOverrides`, `creditDefaultOverrides` (per-period credit-default for
NEW entries — see §4.3), `hourlyRate`, `use24h`, `autoHolidays`, `holidays`,
`validationDay`, `defaultSchedule`, `metricsRange`.

> Note: the PWA's IndexedDB is named `MaxiflexTracker` and must never be renamed
> *in the PWA*. The native app uses its own SwiftData store; the bridge between
> them is the CSV, not a shared database.

---

## 11. UX rules that MUST survive the rebuild (feel, not chrome)

- **One-tap primary actions** (clock in/out, leave ±) — never >1 tap away.
- **Big, thumb-sized buttons** — used in a rush.
- **Quarter-hour input ONLY** — never a 60-minute wheel. (PWA avoids
  `<input type=time>` for this reason; SwiftUI must enforce 15-min granularity
  with a custom picker.)
- **No confirmation modals for routine actions — undo toasts instead.** (Danger
  zone / destructive wipes are the exception.)
- **Glanceable hero number** (hours left) + small supporting stats, not clutter.
- **Lands on the pay-period view**, compact: five weekday cards fit one screen,
  weekends behind reveals.
- **Semantic color system:** calm blue = regular work; **ember/gold = overtime**
  (deliberately flashier, glow/shimmer); teal = leave; pink = holiday. Native
  dark mode.
- **Local-first / private / no account** — a selling point, not just an impl
  detail.
- Haptics on clock in/out.

---

## 12. Verification checklist (port acceptance — must match the PWA)

1. Anchor set to a known Sunday → carousel shows correct 14-day window.
2. Clock in → out → entry rounds to 15 min; lunch deducts at ≥ 4h.
3. Manual entry via day editor → totals update.
4. Leave ± → counts toward 80.
5. Forgotten clock-out (open entry > 16h) → flagged incomplete, contributes 0.
6. Anchor change → entries re-bucket; nothing deleted.
7. 8-hour mode: 9h clocked = 8.5 paid → 0.5 OT/day, summed; OT $ correct.
8. Naming: 2026-04-19 → `2026-PP08`; period ending 2025-12-27 → `2025-PP25`,
   paydate 2026-01-08.
9. YTD OT $: a period whose paydate falls in year N counts toward N.
10. Per-period OT toggle: flip a past 8h period→Maxiflex → confirm modal if OT>0
    → that period's OT (and YTD share) drops to 0; default unchanged; switching
    back restores it (entries untouched).
11. CSV exported from the PWA imports into the native app with identical totals.
12. Metrics: stats grid + daily-hours stacks (regular/OT/leave); each historical
    period reads OT with ITS OWN resolved mode.
