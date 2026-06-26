// app.js — UI layer for the Maxiflex tracker.
// Depends on window.TimeUtil (time.js) and window.DB (db.js).
// Wrapped in an IIFE so its top-level `const`s (T, DB, state) don't collide with
// the shared "script scope" across <script> tags — db.js also declares `const T`.

(function () {
'use strict';

const T = window.TimeUtil;
const DB = window.DB;
const Calendar = window.Calendar;

// The app-wide Google OAuth Web client ID. Set this ONCE (developer step) to give
// every user a one-tap "Sign in with Google" with no client-ID pasting. When
// blank, the app falls back to a per-device client ID entered under Settings →
// Google Calendar sync → Advanced (the personal-tool path). Create it at
// console.cloud.google.com (OAuth client → Web application) with this site
// (https://calebpaulsmith.github.io) as an authorized JavaScript origin.
const EMBEDDED_GOOGLE_CLIENT_ID = '';

const state = {
  anchor: null,           // YYYY-MM-DD
  otModeDefault: true,    // default OT mode applied to periods without overrides
  otModeOverrides: {},    // { [periodStartDate]: bool } — per-period overrides
  creditHoursEnabled: false, // master switch for the whole credit-hours feature (default OFF → extra = OT, credit UI hidden)
  leaveGranularMinutes: false, // leave +/− steps 15 min instead of whole hours (LOGIC-FREEZE §3)
  hourlyRate: 0,          // $/hour straight-time
  use24h: false,
  showWeekends: false,    // legacy/global Sat-Sun visibility — kept for the schedule view's behavior (no longer used by period view)
  shownWeekends: {},      // per-period weekend reveal: { [periodStartDate]: [dayIndex,...] }
  validationDay: null,    // 0..13 day-of-period or null (timecard validation deadline)
  defaultSchedule: Array.from({ length: 14 }, () => null),  // 14 days of period
  holidays: {},           // { [YYYY-MM-DD]: { name, doubleTime } } recorded holidays
  autoHolidays: true,     // auto-record federal holidays (8h leave, no auto work)
  calendarMode: false,    // sticky opt-in Home Calendar reskin
  theme: 'classic',       // selectable color palette (remaps CSS tokens via <html data-theme>)
  expandedDay: null,      // YYYY-MM-DD of the one day-card expanded in place (calendar mode)
  openEntry: null,        // current clocked-in entry or null
  period: null,           // payPeriodFor output for today (the *current* period)
  viewedPeriodOffset: 0,  // 0 = current, -1 = previous, etc.
  viewedPage: 0,          // 0 = Week 1, 1 = Week 2 — carousel scroll position
  viewedWeek: 1,          // 1 or 2 — kept for the schedule view (still uses tabs)
  editingDate: null,      // YYYY-MM-DD in the day editor
  editingEntry: null,     // entry object being edited in modal, or null for new
  editingEvent: null,     // calendar event being edited in the event modal, or null for new
  _eventsByDate: {},      // transient: events bucketed by date for the current period render
  metricsRange: '8pp',    // metrics OT-history range: '8pp' | 'ytd' | '6mo' | '1yr'
  runningTimer: null,     // setInterval handle
  // Google Calendar sync (calendar mode only).
  googleClientId: '',          // user's OAuth Web client id
  googleToken: null,           // { access_token, expiresAt } — local only, never exported
  googleRitzaCalendarId: '',   // shared calendar id mirrored into Ritza's lane + invites
  // Optional work-schedule → calendar sync (off by default). Pushes the default
  // schedule, materialized for a limited forward window, to a chosen calendar
  // (may differ from the primary that events sync to).
  scheduleSyncEnabled: false,
  scheduleSyncCalendarId: '',  // '' → primary; pick any of your writable calendars
  scheduleSyncPeriodsAhead: 2, // current pay period + (N-1) future periods
  _googleCalendars: null,      // cached calendarList after connect
  _googleSyncing: false,
  _googleSyncedAt: 0,
};

// Resolve the OT mode for a given pay period (override beats default).
function otModeForPeriod(period) {
  if (!period) return state.otModeDefault;
  const key = T.formatLocalDate(period.start);
  if (Object.prototype.hasOwnProperty.call(state.otModeOverrides, key)) {
    return !!state.otModeOverrides[key];
  }
  return state.otModeDefault;
}

// Synchronous lookup of OT mode for a YYYY-MM-DD date string.
function otModeForDate(yyyymmdd) {
  if (!state.anchor) return state.otModeDefault;
  const p = T.payPeriodFor(T.parseLocalDate(yyyymmdd), state.anchor);
  return otModeForPeriod(p);
}

// Reflect the sticky calendar-mode flag onto <body> so CSS can layer the
// calendar reskin onto the same views. Phase 0 only sets/removes the attribute;
// no calendar UI keys off it yet beyond future styling hooks.
function applyCalendarMode() {
  if (state.calendarMode) {
    document.body.setAttribute('data-mode', 'calendar');
  } else {
    document.body.removeAttribute('data-mode');
  }
}

// Selectable color themes. Each remaps the semantic CSS tokens in styles.css via
// <html data-theme="id">. 'classic' = the original palette (no attribute, so
// timecard mode stays byte-for-byte). `swatches` are the LIGHT-mode preview
// hexes shown on the Settings card (inline, not var(), so each card previews its
// own palette regardless of the active theme).
const THEMES = [
  { id: 'classic',  name: 'Classic',  mood: 'The original iOS-blue look',
    swatches: ['#0a84ff', '#ffc01e', '#2bb8c4', '#ff375f', '#8b5cf6'] },
  { id: 'pacific',  name: 'Pacific',  mood: 'Calm, trustworthy, focused',
    swatches: ['#0A6CFF', '#E8920C', '#0E9AA7', '#DB2777', '#8B5CF6'] },
  { id: 'sunset',   name: 'Sunset',   mood: 'Warm, energetic, optimistic',
    swatches: ['#E0552B', '#D9760B', '#0C8F94', '#C026A3', '#7E4FD0'] },
  { id: 'clarity',  name: 'Clarity',  mood: 'High-contrast, accessible-first',
    swatches: ['#0058B0', '#B5710A', '#1B8A8F', '#A21C8E', '#009E73'] },
  { id: 'sage',     name: 'Sage',     mood: 'Muted, earthy, low-stimulation',
    swatches: ['#4E7C5B', '#C0891F', '#1F7E86', '#B5557E', '#8A5BA6'] },
  { id: 'midnight', name: 'Midnight', mood: 'Deep, premium, refined',
    swatches: ['#4B43C4', '#C2891A', '#0D8C8F', '#B02E86', '#C56A2A'] },
];
const THEME_IDS = new Set(THEMES.map((t) => t.id));

function applyTheme() {
  const id = THEME_IDS.has(state.theme) ? state.theme : 'classic';
  if (id === 'classic') {
    document.documentElement.removeAttribute('data-theme');
  } else {
    document.documentElement.setAttribute('data-theme', id);
  }
}

// True if a YYYY-MM-DD falls on Saturday or Sunday.
function isWeekendDate(yyyymmdd) {
  const dow = T.parseLocalDate(yyyymmdd).getDay();
  return dow === 0 || dow === 6;
}

// Recorded-holiday lookup for a date → { name, doubleTime } or null. Entries
// flagged `removed` are tombstones (the user un-recorded a holiday that
// auto-record would otherwise re-add) and resolve to null.
function holidayInfoFor(yyyymmdd) {
  const h = state.holidays && state.holidays[yyyymmdd];
  return (h && !h.removed) ? h : null;
}

// Dates of all ACTIVE (non-tombstone) recorded holidays.
function activeHolidayDates() {
  return Object.keys(state.holidays || {}).filter(k => !state.holidays[k].removed);
}

// Federal-holiday name for a date (from the computed calendar) or null.
function federalHolidayNameFor(yyyymmdd) {
  const y = T.parseLocalDate(yyyymmdd).getFullYear();
  const found = T.federalHolidays(y).find(h => h.date === yyyymmdd);
  return found ? found.name : null;
}

// When auto-holidays is on, record any federal holiday in a window around now
// that isn't already recorded: add it to state.holidays, remove any
// schedule-seeded (fromDefault) work on that day, and seed 8h holiday leave on
// otherwise-untouched days. Runs once per holiday (guarded by presence in the
// map), so it never fights the user's later edits.
async function ensureHolidaysSeeded() {
  if (!state.autoHolidays) return;
  const thisYear = new Date().getFullYear();
  let changed = false;
  for (const y of [thisYear - 1, thisYear, thisYear + 1, thisYear + 2]) {
    for (const h of T.federalHolidays(y)) {
      if (state.holidays[h.date]) continue;
      state.holidays[h.date] = { name: h.name, doubleTime: false };
      changed = true;
      const entries = await DB.entriesForDate(h.date);
      const onlyDefault = entries.length > 0 && entries.every(e => e.fromDefault);
      if (entries.length === 0 || onlyDefault) {
        for (const e of entries) await DB.deleteEntry(e.id);
        if ((await DB.getLeave(h.date)) < DB.HOLIDAY_LEAVE_HOURS) {
          await DB.setLeaveHours(h.date, DB.HOLIDAY_LEAVE_HOURS);
        }
      }
    }
  }
  if (changed) await DB.setHolidays(state.holidays);
}

// Record `date` as a holiday (federal name if it is one, else "Holiday"),
// removing schedule-seeded work and seeding 8h leave on an untouched day.
async function markHoliday(yyyymmdd) {
  const name = federalHolidayNameFor(yyyymmdd) || 'Holiday';
  state.holidays[yyyymmdd] = { name, doubleTime: false };
  const entries = await DB.entriesForDate(yyyymmdd);
  const onlyDefault = entries.length > 0 && entries.every(e => e.fromDefault);
  if (entries.length === 0 || onlyDefault) {
    for (const e of entries) {
      await DB.deleteEntry(e.id);
      if (state.openEntry && state.openEntry.id === e.id) state.openEntry = null;
    }
    if ((await DB.getLeave(yyyymmdd)) < DB.HOLIDAY_LEAVE_HOURS) {
      await DB.setLeaveHours(yyyymmdd, DB.HOLIDAY_LEAVE_HOURS);
    }
  }
  await DB.setHolidays(state.holidays);
}

// Un-record a holiday. Leaves any leave/entries on the day as-is. Stored as a
// tombstone so auto-record won't resurrect it on the next load.
async function removeHoliday(yyyymmdd) {
  state.holidays[yyyymmdd] = { removed: true };
  await DB.setHolidays(state.holidays);
}

// Toggle the "holiday worked" (double-time) flag for a recorded holiday.
async function setHolidayWorked(yyyymmdd, on) {
  const h = state.holidays[yyyymmdd];
  if (!h) return;
  h.doubleTime = !!on;
  await DB.setHolidays(state.holidays);
}

const DAY_NAMES = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

// --- Helpers ----------------------------------------------------------------

function $(id) { return document.getElementById(id); }
function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k === 'dataset') Object.assign(e.dataset, v);
    else if (k.startsWith('on')) e.addEventListener(k.slice(2).toLowerCase(), v);
    else if (v === true) e.setAttribute(k, '');
    else if (v === false || v == null) {/* skip */}
    else e.setAttribute(k, v);
  }
  for (const k of kids.flat()) {
    if (k == null || k === false) continue;
    e.appendChild(typeof k === 'string' ? document.createTextNode(k) : k);
  }
  return e;
}
function setView(name) {
  document.body.dataset.view = name;
  window.scrollTo(0, 0);
}
function vibrate(ms = 10) {
  if (navigator.vibrate) try { navigator.vibrate(ms); } catch {}
}

// Fire `callback` when the user presses and holds `target` for `ms`. Cancels
// if the pointer moves too far or releases early. Used for hidden gestures.
function attachLongPress(target, callback, ms = 600) {
  if (!target) return;
  let timer = null, sx = 0, sy = 0;
  const cancel = () => { if (timer) { clearTimeout(timer); timer = null; } };
  target.addEventListener('pointerdown', (ev) => {
    sx = ev.clientX; sy = ev.clientY;
    cancel();
    timer = setTimeout(() => {
      timer = null;
      vibrate(20);
      callback();
    }, ms);
  });
  target.addEventListener('pointermove', (ev) => {
    if (timer && (Math.abs(ev.clientX - sx) > 10 || Math.abs(ev.clientY - sy) > 10)) cancel();
  });
  target.addEventListener('pointerup', cancel);
  target.addEventListener('pointercancel', cancel);
  target.addEventListener('pointerleave', cancel);
}

let toastTimer = null;
function showToast(message, undoFn = null) {
  const t = $('toast');
  t.innerHTML = '';
  t.appendChild(document.createTextNode(message));
  if (undoFn) {
    const btn = el('button', {
      onclick: () => { undoFn(); hideToast(); },
    }, 'Undo');
    t.appendChild(btn);
  }
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(hideToast, 4000);
}
function hideToast() { $('toast').hidden = true; }

// --- Data aggregation -------------------------------------------------------

// Scheduled paid hours for a day-of-period index (0..13), from the user's
// default schedule. 0 when the slot is unset/disabled. Drives the Maxiflex OT
// rule: time worked beyond the scheduled hours is overtime once the period
// passes 80 worked hours.
function scheduledHoursForIndex(i) {
  const slot = state.defaultSchedule[i];
  if (!slot || slot.enabled === false) return 0;
  if (!isFinite(slot.startMin) || !isFinite(slot.endMin) || slot.endMin <= slot.startMin) return 0;
  const start = T.buildDateTime('2000-01-01', Math.floor(slot.startMin / 60), slot.startMin % 60);
  const end = T.buildDateTime('2000-01-01', Math.floor(slot.endMin / 60), slot.endMin % 60);
  return T.hoursForEntry(start, end).hours;
}

// Scheduled paid hours for a specific date, resolved via its day-of-period
// index. Drives the redefined 8-hour-mode OT rule (OT = work beyond the day's
// scheduled hours). Weekends/off days are unscheduled → 0, so all their work
// stays OT.
function scheduledHoursForDate(dateStr) {
  if (!state.anchor) return 0;
  const period = T.payPeriodFor(T.parseLocalDate(dateStr), state.anchor);
  const i = period.days.indexOf(dateStr);
  return i >= 0 ? scheduledHoursForIndex(i) : 0;
}

// Computes totals for one day: { worked, leave, total, regular, overtime, entries }
// `otMode` may be omitted — defaults to the resolved mode for that date. OT is
// sourced from the containing period in Maxiflex mode (the >80h gate and
// outside-schedule rule are period-level concepts), so this function fetches
// the period in that case.
async function dayTotals(yyyymmdd, otMode) {
  const mode = otMode == null ? otModeForDate(yyyymmdd) : otMode;
  const entries = await DB.entriesForDate(yyyymmdd);
  const leave = await DB.getLeave(yyyymmdd);
  let worked = 0;
  for (const e of entries) {
    if (e.incomplete) continue;
    if (!e.endTime) continue;          // in-progress contributes via dedicated path
    worked += T.hoursForEntry(e.startTime, e.endTime, e.lunchMinutes).hours;
  }
  let overtime;
  if (mode) {
    // 8-hour mode (redefined): OT = work beyond the day's scheduled hours.
    overtime = Math.max(0, worked - scheduledHoursForDate(yyyymmdd));
  } else {
    const period = T.payPeriodFor(T.parseLocalDate(yyyymmdd), state.anchor);
    const pt = await periodTotals(period, mode);
    overtime = Math.min(worked, pt.otByDate[yyyymmdd] || 0);
  }
  const regular = Math.max(0, worked - overtime);
  return { worked, leave, total: worked + leave, regular, overtime, entries };
}

// Today includes the running in-progress entry's live elapsed.
async function todayTotalsLive(yyyymmdd, otMode) {
  const mode = otMode == null ? otModeForDate(yyyymmdd) : otMode;
  if (mode) {
    const base = await dayTotals(yyyymmdd, mode);
    if (state.openEntry && state.openEntry.date === yyyymmdd) {
      const now = T.roundToQuarter(new Date());
      const { hours } = T.hoursForEntry(state.openEntry.startTime, now);
      base.worked += hours;
      base.total += hours;
      base.overtime = Math.max(0, base.worked - scheduledHoursForDate(yyyymmdd));
      base.regular = Math.max(0, base.worked - base.overtime);
    }
    return base;
  }
  // Maxiflex: periodTotals already folds the running open entry into today.
  const period = T.payPeriodFor(T.parseLocalDate(yyyymmdd), state.anchor);
  const pt = await periodTotals(period, mode);
  const worked = pt.byDate[yyyymmdd] || 0;
  const leave = pt.leaveMap[yyyymmdd] || 0;
  const overtime = pt.otByDate[yyyymmdd] || 0;
  const entries = await DB.entriesForDate(yyyymmdd);
  return { worked, leave, total: worked + leave, regular: Math.max(0, worked - overtime), overtime, entries };
}

// Enumerate every period from the earliest period that has any entries OR leave
// up through today's period. Used for YTD bucketing across all history.
async function allPeriodsWithData() {
  if (!state.anchor) return [];
  const [allEntries, allLeave] = await Promise.all([
    DB.db.entries.toArray(),
    DB.db.leave.toArray(),
  ]);
  const dates = [];
  for (const e of allEntries) if (e.date) dates.push(e.date);
  for (const l of allLeave) if (l.date) dates.push(l.date);
  if (dates.length === 0) {
    return [T.payPeriodFor(new Date(), state.anchor)];
  }
  dates.sort();
  const firstDate = T.parseLocalDate(dates[0]);
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const firstPeriod = T.payPeriodFor(firstDate, state.anchor);
  const todayPeriod = T.payPeriodFor(today, state.anchor);
  const periods = [];
  const cursor = new Date(firstPeriod.start);
  while (cursor <= todayPeriod.start) {
    periods.push(T.payPeriodFor(cursor, state.anchor));
    cursor.setDate(cursor.getDate() + T.PAY_PERIOD_DAYS);
  }
  return periods;
}

// Sum OT hours and OT $ across all periods whose paydate falls in `year`.
// Each period is evaluated with ITS OWN OT mode. Maxiflex periods can now
// carry OT too (explicit entries, outside-schedule work past 80h, worked
// holidays), so they are no longer skipped. OT $ comes from each period's
// otDollars (which blends 1.5× overtime and 2× holiday double-time).
async function ytdOvertime(year) {
  const periods = await allPeriodsWithData();
  let hours = 0, dollars = 0;
  for (const p of periods) {
    if (T.paydateYear(p) !== year) continue;
    const t = await periodTotals(p, otModeForPeriod(p));
    hours += t.ot;
    dollars += t.otDollars;
  }
  return { hours, dollars };
}

// Sum hours WORKED across all periods whose paydate falls in `year`. Bucketed
// by paydate year (a Dec period paid in January counts toward January's year).
// Mode-independent — worked hours don't depend on the OT split.
async function ytdHoursWorked(year) {
  const periods = await allPeriodsWithData();
  let worked = 0;
  for (const p of periods) {
    if (T.paydateYear(p) !== year) continue;
    const t = await periodTotals(p, otModeForPeriod(p));
    worked += t.worked;
  }
  return worked;
}

// Credit-hour bank (Phase 2). Fold earned + spent credit across all periods
// with data, then read off the bank slot for TODAY's period (the running
// balance "now"). Returns { balance, carryOut, lost, used } via T.creditBankSlot.
// Mirrors iOS MetricsViewModel.reloadCreditBank.
async function computeCreditBank() {
  const periods = await allPeriodsWithData();
  const usedMap = await DB.getCreditUsedMap();
  const byPeriod = [];
  for (const p of periods) {
    const start = T.formatLocalDate(p.start);
    const t = await periodTotals(p, otModeForPeriod(p));
    let used = 0;
    for (const d of p.days) used += Number(usedMap[d]) || 0;
    // Keep only credit-relevant periods (earn or spend); inert periods are no-ops.
    if (t.credit > 0.0001 || used > 0.0001) byPeriod.push({ start, earned: t.credit, used });
  }
  const folded = T.creditBankFold(byPeriod);
  const currentStart = T.formatLocalDate(T.payPeriodFor(new Date(), state.anchor).start);
  return T.creditBankSlot(currentStart, folded);
}

// Split a day's worked units into forced + candidate-auto premium hours under
// the refined Maxiflex rule (the period-level over-80 cap is applied separately
// by `periodTotals`). Mirrors iOS `splitMaxiflexDay` (Domain/PeriodTotals.swift):
//   - forced `overtime`/`credit` units pay their WHOLE hours (uncapped) and sit
//     ON TOP of the schedule (they don't consume the cushion → no double-count);
//   - `auto`/`autoCredit`/`regular` units share the day's beyond-cushion hours
//     (leave already filled the schedule), allocated latest-start-first:
//     `auto`→OT candidate, `autoCredit`→credit candidate, `regular`→stays regular.
// Each unit is { hours, kind, sortKey } (sortKey = minutes-since-midnight).
function splitMaxiflexDay(units, cushion) {
  let forcedOT = 0, forcedCredit = 0;
  for (const u of units) {
    if (u.kind === 'overtime') forcedOT += u.hours;
    else if (u.kind === 'credit') forcedCredit += u.hours;
  }
  const flex = units.filter(u => u.kind === 'auto' || u.kind === 'autoCredit' || u.kind === 'regular');
  const flexWorked = flex.reduce((s, u) => s + u.hours, 0);
  let pool = Math.max(0, flexWorked - cushion);
  let autoOT = 0, autoCredit = 0;
  for (const u of flex.slice().sort((a, b) => b.sortKey - a.sortKey)) {  // latest-first
    if (pool <= 0) break;
    const slice = Math.min(pool, u.hours);
    if (u.kind === 'auto') autoOT += slice;
    else if (u.kind === 'autoCredit') autoCredit += slice;
    // `regular` absorbs the slice but stays regular (no premium).
    pool -= slice;
  }
  return { forcedOT, forcedCredit, autoOT, autoCredit };
}

// Totals for the whole pay period. `otMode` may be omitted — defaults to the
// resolved mode for that specific period. This is the single source of truth
// for overtime + credit hours. Returns per-day OT (`otByDate`) and credit
// (`creditByDate`), totals (`ot`, `credit`), and blended OT dollars (`otDollars`).
//
// OT rules (canonical in LOGIC-FREEZE §4; mirrors iOS Domain/PeriodTotals.swift):
//   - 8-hour mode: per-day work beyond that day's SCHEDULED hours is OT,
//     ungated. Unscheduled weekends/off days yield all-OT (0 scheduled hrs).
//     `payKind` is ignored entirely in this mode.
//   - Maxiflex mode: per-entry `payKind` classification, with leave counting
//     toward the 80h requirement and filling the daily schedule first. Forced
//     overtime/credit are uncapped; auto/autoCredit beyond-schedule hours are
//     candidates capped at the period's hours-over-80, kept latest-first — so a
//     period only 1.75h over 80 yields ≤ 1.75h of auto OT/credit, not the full
//     sum of every beyond-schedule hour.
//   - Worked-holiday hours are OT in either mode (added on top), and pay at 2×
//     instead of 1.5× when the day is flagged double-time. (Holiday wiring is
//     layered in by `holidayInfoFor`; absent that it is a no-op.)
// When the credit-hours feature is OFF (default), collapse credit kinds so all
// extra hours pay overtime: autoCredit→auto (beyond-schedule over-80 → OT),
// credit→overtime (force the whole entry to OT). Stored payKinds are untouched,
// so it's a non-destructive view switch. Mirrors iOS effectivePayKind.
function effectivePayKind(kind) {
  if (state.creditHoursEnabled) return kind;
  if (kind === 'autoCredit') return 'auto';
  if (kind === 'credit') return 'overtime';
  return kind;
}

async function periodTotals(period, otMode) {
  const mode = otMode == null ? otModeForPeriod(period) : otMode;
  const entries = await DB.entriesForPeriod(period);
  const leaveMap = await DB.leaveForPeriod(period);
  const byDate = {};          // total worked hours per day
  const units = {};           // per-day worked units (Maxiflex split input)
  for (const d of period.days) { byDate[d] = 0; units[d] = []; }
  const minutesOfDay = (iso) => { const t = new Date(iso); return t.getHours() * 60 + t.getMinutes(); };
  for (const e of entries) {
    if (e.incomplete || !e.endTime) continue;
    if (!(e.date in byDate)) continue;
    const h = T.hoursForEntry(e.startTime, e.endTime, e.lunchMinutes).hours;
    byDate[e.date] += h;
    units[e.date].push({ hours: h, kind: effectivePayKind(DB.entryPayKind(e)), sortKey: minutesOfDay(e.startTime) });
  }
  // Fold the running open entry into today.
  const todayStr = T.formatLocalDate(new Date());
  if (state.openEntry && state.openEntry.date === todayStr && todayStr in byDate) {
    const now = T.roundToQuarter(new Date());
    const h = T.hoursForEntry(state.openEntry.startTime, now).hours;
    byDate[todayStr] += h;
    units[todayStr].push({ hours: h, kind: effectivePayKind(DB.entryPayKind(state.openEntry)), sortKey: minutesOfDay(state.openEntry.startTime) });
  }

  let worked = 0;
  for (const d of period.days) worked += byDate[d];
  // Leave counts toward the maxiflex 80-hour requirement (paid pay-status time),
  // so the over-80 cap runs off worked + leave — not worked alone. Without this,
  // taking leave in a period wrongly suppressed earned OT.
  let leaveTotal = 0;
  for (const d of period.days) leaveTotal += (leaveMap[d] || 0);
  // Hours the period is OVER 80 (leave counted) — the cap on maxiflex auto
  // premium. An *amount*, not a boolean. See LOGIC-FREEZE §4.
  const overAmount = Math.max(0, (worked + leaveTotal) - T.PAY_PERIOD_TARGET);

  const rate = state.hourlyRate;
  const otByDate = {};
  const creditByDate = {};
  const autoOTByDate = {};      // maxiflex per-day OT candidates (capped below)
  const autoCreditByDate = {};  // maxiflex per-day credit candidates (capped below)
  let ot = 0, credit = 0, leave = 0, otDollars = 0;

  // Pass 1: holidays, 8h-mode OT, and the per-day Maxiflex forced + auto split.
  for (let i = 0; i < period.days.length; i++) {
    const d = period.days[i];
    const holiday = holidayInfoFor(d);     // null unless a recorded holiday
    otByDate[d] = 0; creditByDate[d] = 0; autoOTByDate[d] = 0; autoCreditByDate[d] = 0;
    if (holiday) {
      // Worked time on a holiday is entirely OT; double-time days pay at 2×.
      const dayOT = byDate[d];
      otByDate[d] = dayOT;
      ot += dayOT;
      otDollars += dayOT * rate * (holiday.doubleTime ? T.HOLIDAY_MULTIPLIER : T.OT_MULTIPLIER);
    } else if (mode) {
      // 8-hour mode: OT = work beyond that day's SCHEDULED hours, ungated.
      const dayOT = Math.max(0, byDate[d] - scheduledHoursForIndex(i));
      otByDate[d] = dayOT;
      ot += dayOT;
      otDollars += dayOT * rate * T.OT_MULTIPLIER;
    } else {
      // Maxiflex: forced premium is uncapped; auto beyond-schedule hours are
      // candidates capped at overAmount in pass 2. Leave fills the schedule.
      const cushion = Math.max(0, scheduledHoursForIndex(i) - (leaveMap[d] || 0));
      const s = splitMaxiflexDay(units[d], cushion);
      otByDate[d] = s.forcedOT;
      creditByDate[d] = s.forcedCredit;
      ot += s.forcedOT; credit += s.forcedCredit;
      otDollars += s.forcedOT * rate * T.OT_MULTIPLIER;
      autoOTByDate[d] = s.autoOT;
      autoCreditByDate[d] = s.autoCredit;
    }
    leave += (leaveMap[d] || 0);
  }

  // Pass 2 (Maxiflex): pay auto premium only up to the hours over 80, kept
  // latest-first (the hours that put you over 80 are the most recent). OT is
  // drawn before credit within each day, matching iOS.
  if (!mode) {
    let budget = overAmount;
    for (let i = period.days.length - 1; i >= 0; i--) {
      if (budget <= 0) break;
      const d = period.days[i];
      const kOT = Math.min(autoOTByDate[d] || 0, budget); budget -= kOT;
      const kCredit = Math.min(autoCreditByDate[d] || 0, budget); budget -= kCredit;
      otByDate[d] += kOT;
      creditByDate[d] += kCredit;
      ot += kOT; credit += kCredit;
      otDollars += kOT * rate * T.OT_MULTIPLIER;
    }
  }
  return { worked, ot, credit, leave, total: worked + leave,
           byDate, otByDate, creditByDate, leaveMap, mode, otDollars };
}

// --- Boot / initial load ----------------------------------------------------

async function init() {
  // Wire up event listeners FIRST so the UI is responsive even if data loading fails.
  // (e.g. Dexie / IndexedDB blocked in some private-mode contexts, slow CDN, etc.)
  try {
    wireGlobalEvents();
  } catch (err) {
    console.error('Failed to wire events:', err);
    showToast('UI failed to initialize: ' + err.message);
    return;
  }

  // Ask the browser to mark our storage as "do not evict." Best-effort — fires
  // a permission prompt on some platforms; silently granted on installed PWAs.
  if (navigator.storage && navigator.storage.persist) {
    navigator.storage.persist().catch(() => {});
  }

  // Now load persisted state. If this throws, surface the error rather than dying silently.
  try {
    if (!window.DB) throw new Error('Database library failed to load (offline?). Refresh while online.');
    state.anchor = await DB.getAnchor();
    state.otModeDefault = await DB.getOvertimeModeDefault();
    state.otModeOverrides = await DB.getOvertimeModeOverrides();
    state.creditHoursEnabled = await DB.getCreditHoursEnabled();
    state.leaveGranularMinutes = await DB.getLeaveGranular();
    state.hourlyRate = await DB.getHourlyRate();
    state.use24h = await DB.getUse24h();
    state.showWeekends = !!(await DB.getSetting('showWeekends', false));
    state.shownWeekends = (await DB.getSetting('shownWeekends', null)) || {};
    state.validationDay = await DB.getValidationDay();
    state.defaultSchedule = await DB.getDefaultSchedule();
    state.metricsRange = (await DB.getSetting('metricsRange', '8pp')) || '8pp';
    // First-launch: persist the Mon-Fri-on defaults so any toggle the user
    // flips (e.g., turning Wed off) sticks across reloads.
    if ((await DB.getSetting('defaultSchedule', null)) == null) {
      await DB.setDefaultSchedule(state.defaultSchedule);
    }
    state.autoHolidays = await DB.getAutoHolidays();
    state.holidays = await DB.getHolidays();
    state.calendarMode = await DB.getCalendarMode();
    state.theme = await DB.getTheme();
    applyTheme();
    // Discover/Invites settings + seed the connector sources on first run.
    state.proxyBase = (await DB.getSetting('proxyBase', '')) || '';
    state.homeLatLng = await DB.getSetting('homeLatLng', null);
    // Google Calendar sync settings (token + client id kept local; not exported).
    // An embedded app-wide client id (if set) wins so users never paste one.
    state.googleClientIdEmbedded = !!EMBEDDED_GOOGLE_CLIENT_ID;
    state.googleClientId = EMBEDDED_GOOGLE_CLIENT_ID || (await DB.getSetting('googleClientId', '')) || '';
    state.googleToken = await DB.getSetting('googleToken', null);
    state.googleRitzaCalendarId = (await DB.getSetting('googleRitzaCalendarId', '')) || '';
    state.scheduleSyncEnabled = !!(await DB.getSetting('scheduleSyncEnabled', false));
    state.scheduleSyncCalendarId = (await DB.getSetting('scheduleSyncCalendarId', '')) || '';
    state.scheduleSyncPeriodsAhead = Math.max(1, (await DB.getSetting('scheduleSyncPeriodsAhead', 2)) | 0) || 2;
    if (window.Connectors) {
      try { await DB.seedSources(Connectors.DEFAULT_SOURCES, 2); } catch (e) { console.warn('seed sources', e); }
    }
    applyCalendarMode();
    state.openEntry = await DB.getOpenEntry();
    // Record federal holidays (8h leave, no auto work) when the setting is on.
    await ensureHolidaysSeeded();
    // ensureHolidaysSeeded may have deleted schedule-seeded entries on holidays.
    if (state.openEntry) state.openEntry = await DB.getOpenEntry();
  } catch (err) {
    console.error('Failed to load data:', err);
    showToast('Data load error: ' + err.message);
    return;
  }

  // Land the carousel on whichever week contains today.
  // Carousel pages: 0 = Week 1, 1 = Week 2.
  if (state.anchor) {
    const today = new Date();
    const period = T.payPeriodFor(today, state.anchor);
    state.viewedPage = period.dayIndex < 7 ? 0 : 1;
  } else {
    state.viewedPage = 0;
  }

  await renderAll();
  scrollCarouselTo(state.viewedPage, /*instant*/ true);
  maybeShowInstallPrompt();
}

// Deferred Chrome/Android install prompt event, captured at load. Null until
// the browser decides the PWA is installable (and again null after .prompt()).
let deferredInstallEvent = null;
window.addEventListener('beforeinstallprompt', (ev) => {
  ev.preventDefault();
  deferredInstallEvent = ev;
  // If the Android modal is already on screen (early visit) reveal the button.
  const btn = document.getElementById('androidInstallNow');
  if (btn && !document.getElementById('androidInstallModal').hidden) {
    btn.hidden = false;
    const hint = document.getElementById('androidInstallNativeHint');
    const steps = document.getElementById('androidInstallManualSteps');
    if (hint) hint.hidden = false;
    if (steps) steps.hidden = true;
  }
});

// Show a one-time install instruction modal for mobile users who haven't
// installed the PWA. iPhone gets Share/Add-to-Home-Screen steps; Android gets
// the native install button when available, falling back to manual steps.
// Dismissed forever once acknowledged. The dismissal flag is wiped by "Clear
// all data" so the prompt re-appears.
async function maybeShowInstallPrompt() {
  try {
    if (await DB.getSetting('installPromptDismissed', false)) return;
    const isStandalone = window.matchMedia('(display-mode: standalone)').matches
      || window.navigator.standalone === true;
    if (isStandalone) return;
    const ua = navigator.userAgent || '';
    if (/iPhone|iPod|iPad/i.test(ua)) {
      $('installPromptModal').hidden = false;
    } else if (/Android/i.test(ua)) {
      const hasNative = !!deferredInstallEvent;
      $('androidInstallNativeHint').hidden = !hasNative;
      $('androidInstallManualSteps').hidden = hasNative;
      $('androidInstallNow').hidden = !hasNative;
      $('androidInstallModal').hidden = false;
    }
  } catch {}
  // Ask the browser to keep our IndexedDB durable (Android Chrome may evict
  // under storage pressure otherwise). Safe to call repeatedly; no-op if
  // unsupported or already granted.
  try {
    if (navigator.storage && navigator.storage.persist) {
      navigator.storage.persist();
    }
  } catch {}
}

function wireGlobalEvents() {
  // Navigation: data-goto attributes switch the body data-view between
  // 'main' (the carousel), 'day', 'settings', and 'schedule'.
  document.body.addEventListener('click', (ev) => {
    const t = ev.target.closest('[data-goto]');
    if (!t) return;
    const dest = t.dataset.goto;
    setView(dest);
    if (dest === 'main') {
      // Re-paint current period pages and restore the carousel scroll position
      // (display:none from being off-screen earlier may have reset it).
      renderPeriodPages();
      requestAnimationFrame(() => scrollCarouselTo(state.viewedPage, true));
    }
    if (dest === 'settings') renderSettings();
    if (dest === 'schedule') renderScheduleView();
    if (dest === 'metrics') renderMetrics();
  });

  // Period chevrons (one pair per week page) step by whole period.
  document.body.addEventListener('click', (ev) => {
    const chev = ev.target.closest('.period-prev, .period-next');
    if (!chev) return;
    if (chev.classList.contains('period-prev')) {
      state.viewedPeriodOffset -= 1;
    } else {
      if (state.viewedPeriodOffset >= 0) return; // no future
      state.viewedPeriodOffset += 1;
    }
    renderPeriodPages();
  });

  // Visible per-period OT/Maxiflex segmented control. Tapping the inactive
  // segment flips the viewed period's mode (with the OT-erasure confirm when
  // switching off 8h on a period that already accumulated OT).
  document.body.addEventListener('click', (ev) => {
    const seg = ev.target.closest('.seg-control.period-mode .seg-btn');
    if (!seg) return;
    if (!state.anchor) return;
    const wantOt = seg.dataset.mode === 'ot';
    const viewed = T.payPeriodOffset(new Date(), state.anchor, state.viewedPeriodOffset);
    const currentMode = otModeForPeriod(viewed);
    if (wantOt === currentMode) return; // already in this mode — no-op
    onTogglePeriodMode(viewed, currentMode);
  });

  // Per-period flex-default control ("Overtime | Credit"). Sets whether NEW
  // maxiflex entries for the viewed period bank beyond-schedule hours as credit
  // instead of overtime. Never reclassifies existing entries (LOGIC-FREEZE §4.3).
  document.body.addEventListener('click', async (ev) => {
    const seg = ev.target.closest('.seg-control.credit-mode .seg-btn');
    if (!seg) return;
    if (!state.anchor) return;
    const wantCredit = seg.dataset.credit === 'credit';
    const viewed = T.payPeriodOffset(new Date(), state.anchor, state.viewedPeriodOffset);
    const periodStart = viewed.days[0];
    if ((await DB.getCreditDefaultForPeriodStart(periodStart)) === wantCredit) return;
    await DB.setCreditDefaultOverride(periodStart, wantCredit);
    await renderAll();
  });

  // Backdoor: long-press the period name also flips that period's OT mode
  // (kept for back-compat; the visible control above is the primary affordance).
  for (const id of ['periodNameW1', 'periodNameW2']) {
    attachLongPress($(id), async () => {
      if (!state.anchor) return;
      const viewed = T.payPeriodOffset(new Date(), state.anchor, state.viewedPeriodOffset);
      await onTogglePeriodMode(viewed, otModeForPeriod(viewed));
    });
  }

  // Page dots: tap to jump to that carousel page (0 = Week 1, 1 = Week 2).
  $('pageDots').addEventListener('click', (ev) => {
    const dot = ev.target.closest('.dot');
    if (!dot) return;
    const idx = Number(dot.dataset.pageIdx);
    if (idx === 0 || idx === 1) scrollCarouselTo(idx, false);
  });

  // Carousel scroll → keep state.viewedPage and active dot in sync.
  const carousel = $('mainCarousel');
  let scrollDebounce = null;
  carousel.addEventListener('scroll', () => {
    if (scrollDebounce) cancelAnimationFrame(scrollDebounce);
    scrollDebounce = requestAnimationFrame(() => {
      const w = carousel.clientWidth || 1;
      const idx = Math.round(carousel.scrollLeft / w);
      if (idx !== state.viewedPage) {
        state.viewedPage = idx;
        updatePageDots();
      }
    });
  });

  // Schedule view still uses week tabs — keep that wiring intact.
  document.body.addEventListener('click', (ev) => {
    const tab = ev.target.closest('.week-tab');
    if (!tab) return;
    const wk = Number(tab.dataset.week);
    if (wk !== 1 && wk !== 2) return;
    if (tab.closest('#schedWeekTabs')) {
      state.viewedWeek = wk;
      renderScheduleView();
    }
  });

  // Swipe between Week 1 / Week 2 inside the schedule view (which isn't part
  // of the main carousel).
  attachSwipeNav(document.querySelector('section[data-view-name="schedule"]'), (dir) => {
    if (dir > 0 && state.viewedWeek === 1) {
      state.viewedWeek = 2;
      renderScheduleView();
    } else if (dir < 0 && state.viewedWeek === 2) {
      state.viewedWeek = 1;
      renderScheduleView();
    }
  });

  // Per-period mode confirmation modal (OT-erasure prompt).
  $('modeConfirmCancel').addEventListener('click', () => {
    $('modeConfirmModal').hidden = true;
    pendingModeChange = null;
  });
  $('modeConfirmOk').addEventListener('click', async () => {
    $('modeConfirmModal').hidden = true;
    const pending = pendingModeChange;
    pendingModeChange = null;
    if (pending) await applyPeriodMode(pending.period, pending.nextMode);
  });

  $('holidayToggleBtn').addEventListener('click', async () => {
    const d = state.editingDate;
    if (!d) return;
    if (holidayInfoFor(d)) {
      await removeHoliday(d);
      showToast('Holiday removed');
    } else {
      await markHoliday(d);
      showToast('Holiday recorded · 8 hr leave');
    }
    vibrate(8);
    await renderDayView();
    await renderAll();
  });
  $('holidayWorkedToggle').addEventListener('change', async (ev) => {
    const d = state.editingDate;
    if (!d) return;
    await setHolidayWorked(d, ev.target.checked);
    vibrate(8);
    await renderDayView();
    await renderAll();
  });

  $('addEntryBtn').addEventListener('click', () => openEntryModal(null));
  $('copyDayBtn').addEventListener('click', onCopyDayToWeekdays);
  $('clockBtn').addEventListener('click', onClockToggle);
  $('leavePlus').addEventListener('click', async () => {
    const d = state.editingDate;
    await DB.addLeaveMinutes(d, state.leaveGranularMinutes ? 15 : 60);
    vibrate(8);
    renderDayView();
  });
  $('leaveMinus').addEventListener('click', async () => {
    const d = state.editingDate;
    const prev = await DB.getLeaveMinutes(d);
    if (prev <= 0) return;
    const step = state.leaveGranularMinutes ? 15 : 60;
    await DB.setLeaveMinutes(d, prev - step);
    showToast('Removed leave', async () => {
      await DB.setLeaveMinutes(d, prev);
      renderDayView();
    });
    vibrate(8);
    renderDayView();
  });
  $('leaveGranularToggle').addEventListener('change', async (ev) => {
    state.leaveGranularMinutes = ev.target.checked;
    await DB.setLeaveGranular(state.leaveGranularMinutes);
    renderDayView();
  });
  // Credit-hours spend stepper (0.5h steps, like leave but drawn from the bank).
  $('creditUsedPlus').addEventListener('click', async () => {
    const d = state.editingDate;
    await DB.setCreditUsed(d, (await DB.getCreditUsed(d)) + 0.5);
    vibrate(8);
    renderDayView();
  });
  $('creditUsedMinus').addEventListener('click', async () => {
    const d = state.editingDate;
    const prev = await DB.getCreditUsed(d);
    if (prev <= 0) return;
    await DB.setCreditUsed(d, prev - 0.5);
    vibrate(8);
    renderDayView();
  });

  $('anchorInput').addEventListener('change', onAnchorChange);
  $('otToggle').addEventListener('change', async (ev) => {
    state.otModeDefault = ev.target.checked;
    await DB.setOvertimeModeDefault(state.otModeDefault);
    renderAll();
  });
  $('creditHoursToggle').addEventListener('change', async (ev) => {
    state.creditHoursEnabled = ev.target.checked;
    await DB.setCreditHoursEnabled(state.creditHoursEnabled);
    showToast(state.creditHoursEnabled
      ? 'Credit hours on — classify entries as overtime or credit'
      : 'Credit hours off — all extra hours pay overtime');
    renderAll();
  });
  $('hourlyRateInput').addEventListener('change', async (ev) => {
    const n = Number(ev.target.value);
    state.hourlyRate = isFinite(n) && n > 0 ? n : 0;
    await DB.setHourlyRate(state.hourlyRate);
    showToast(state.hourlyRate > 0
      ? `Rate saved: ${T.formatMoney(state.hourlyRate)}/hr`
      : 'Rate cleared');
    renderAll();
  });

  // Modal
  $('entryCancel').addEventListener('click', closeEntryModal);
  $('entrySave').addEventListener('click', saveEntryFromModal);
  $('entryPayKind').addEventListener('change', updatePayKindHint);

  // Event modal (calendar mode)
  $('addEventBtn').addEventListener('click', () => openEventModal(state.editingDate, null));
  $('eventCancel').addEventListener('click', closeEventModal);
  $('eventSave').addEventListener('click', saveEventFromModal);
  $('eventDelete').addEventListener('click', deleteEventFromModal);
  $('eventAllDay').addEventListener('change', syncBacklogUi);
  $('eventBacklog').addEventListener('change', syncBacklogUi);
  $('eventRepeat').addEventListener('change', () => syncRepeatUi(state.editingDate));
  $('eventEnds').addEventListener('change', () => syncRepeatUi(state.editingDate));
  $('eventByday').addEventListener('click', (ev) => {
    const btn = ev.target.closest('.byday-day');
    if (btn) btn.classList.toggle('selected');
  });
  let suggestTimer = null;
  $('eventTitle').addEventListener('input', (ev) => {
    clearTimeout(suggestTimer);
    const q = ev.target.value;
    suggestTimer = setTimeout(() => renderEventSuggestions(q), 120);
  });
  $('eventTitle').addEventListener('focus', (ev) => renderEventSuggestions(ev.target.value));
  // Recurring this/all choice
  $('recurThis').addEventListener('click', () => resolveRecurChoice('this'));
  $('recurFollowing').addEventListener('click', () => resolveRecurChoice('following'));
  $('recurAll').addEventListener('click', () => resolveRecurChoice('all'));
  // Discover: sources manager + add/edit form
  $('sourcesClose').addEventListener('click', closeSourcesModal);
  $('sourceAddBtn').addEventListener('click', () => openSourceForm(null));
  $('sfCancel').addEventListener('click', () => { closeSourceForm(); openSourcesModal(); });
  $('sfSave').addEventListener('click', saveSourceFromForm);
  $('sfDelete').addEventListener('click', deleteSourceFromForm);
  $('recurCancel').addEventListener('click', () => { $('recurChoiceModal').hidden = true; pendingRecur = null; });
  // Time-picker options are populated by populateTimeSelects() at modal-open
  // time, so they reflect the current 24h-mode setting.

  // 24h toggle
  $('use24hToggle').addEventListener('change', async (ev) => {
    state.use24h = ev.target.checked;
    await DB.setUse24h(state.use24h);
    renderAll();
    if (!$('entryModal').hidden) {
      // If modal is open, rebuild it with the new format.
      openEntryModal(state.editingEntry);
    }
  });

  $('autoHolidaysToggle').addEventListener('change', async (ev) => {
    state.autoHolidays = ev.target.checked;
    await DB.setAutoHolidays(state.autoHolidays);
    if (state.autoHolidays) {
      await ensureHolidaysSeeded();
      state.openEntry = await DB.getOpenEntry();
      showToast('Federal holidays will be recorded automatically');
    } else {
      showToast('Auto-record off · existing holidays kept');
    }
    await renderAll();
  });

  $('calendarModeToggle').addEventListener('change', async (ev) => {
    state.calendarMode = ev.target.checked;
    if (!state.calendarMode) state.expandedDay = null;
    await DB.setCalendarMode(state.calendarMode);
    applyCalendarMode();
    showToast(state.calendarMode ? 'Calendar mode on' : 'Calendar mode off');
    await renderAll();
  });

  // Theme picker — delegated click on the swatch cards (re-rendered each open).
  $('themePicker').addEventListener('click', async (ev) => {
    const card = ev.target.closest('.theme-option');
    if (!card) return;
    const id = card.getAttribute('data-theme-id');
    if (!id || id === state.theme) return;
    state.theme = id;
    await DB.setTheme(id);
    applyTheme();
    renderThemePicker();
    const t = THEMES.find((x) => x.id === id);
    showToast(`Theme: ${t ? t.name : id}`);
  });

  $('validationDaySelect').addEventListener('change', async (ev) => {
    const v = ev.target.value;
    state.validationDay = v === '' ? null : Number(v);
    await DB.setValidationDay(state.validationDay);
    renderAll();
  });

  // Default schedule
  $('applyScheduleBtn').addEventListener('click', onApplyDefaultSchedule);

  // Backup / restore
  $('exportBtn').addEventListener('click', onExport);
  $('exportIcsBtn').addEventListener('click', onExportCalendar);
  $('importBtn').addEventListener('click', () => $('importFile').click());
  $('importFile').addEventListener('change', onImport);
  $('exportEventsIcsBtn').addEventListener('click', onExportEventsIcs);
  $('importEventsIcsBtn').addEventListener('click', () => $('importEventsIcsFile').click());
  $('importEventsIcsFile').addEventListener('change', onImportEventsIcs);

  // Google Calendar sync
  $('googleConnectBtn').addEventListener('click', onGoogleConnect);
  $('googleSyncBtn').addEventListener('click', onGoogleSyncClick);
  $('googleDisconnectBtn').addEventListener('click', onGoogleDisconnect);
  $('googleRitzaSelect').addEventListener('change', async (ev) => {
    state.googleRitzaCalendarId = ev.target.value || '';
    await DB.setSetting('googleRitzaCalendarId', state.googleRitzaCalendarId);
    if (state.googleRitzaCalendarId) {
      setGoogleStatus('Syncing Ritza’s calendar…');
      await maybeSyncGoogle(true);
      setGoogleStatus('Connected · Ritza’s calendar linked');
    }
  });
  $('scheduleSyncToggle').addEventListener('change', async (ev) => {
    state.scheduleSyncEnabled = !!ev.target.checked;
    await DB.setSetting('scheduleSyncEnabled', state.scheduleSyncEnabled);
    setGoogleStatus(state.scheduleSyncEnabled ? 'Syncing work schedule…' : 'Removing synced schedule…');
    await maybeSyncGoogle(true);
    setGoogleStatus('Connected');
  });
  $('scheduleSyncCalendarSelect').addEventListener('change', async (ev) => {
    state.scheduleSyncCalendarId = ev.target.value || '';
    await DB.setSetting('scheduleSyncCalendarId', state.scheduleSyncCalendarId);
    if (state.scheduleSyncEnabled) {
      setGoogleStatus('Moving schedule to the chosen calendar…');
      await maybeSyncGoogle(true);
      setGoogleStatus('Connected');
    }
  });
  $('scheduleSyncPeriodsInput').addEventListener('change', async (ev) => {
    const n = Math.min(26, Math.max(1, parseInt(ev.target.value, 10) || 2));
    state.scheduleSyncPeriodsAhead = n;
    ev.target.value = String(n);
    await DB.setSetting('scheduleSyncPeriodsAhead', n);
    if (state.scheduleSyncEnabled) { await maybeSyncGoogle(true); }
  });

  // Danger zone
  $('clearAllBtn').addEventListener('click', onClearAll);

  $('installPromptOk').addEventListener('click', async () => {
    $('installPromptModal').hidden = true;
    try { await DB.setSetting('installPromptDismissed', true); } catch {}
  });

  $('androidInstallOk').addEventListener('click', async () => {
    $('androidInstallModal').hidden = true;
    try { await DB.setSetting('installPromptDismissed', true); } catch {}
  });

  $('androidInstallNow').addEventListener('click', async () => {
    if (!deferredInstallEvent) return;
    try {
      deferredInstallEvent.prompt();
      await deferredInstallEvent.userChoice;
    } catch {}
    deferredInstallEvent = null;
    $('androidInstallModal').hidden = true;
    try { await DB.setSetting('installPromptDismissed', true); } catch {}
  });

  $('confirmCancel').addEventListener('click', () => { $('confirmModal').hidden = true; });
  $('confirmOk').addEventListener('click', async () => {
    $('confirmModal').hidden = true;
    await DB.clockOut();
    state.openEntry = await DB.clockIn();
    vibrate(10);
    renderAll();
  });

  // Keep running clock fresh
  state.runningTimer = setInterval(() => {
    if (state.openEntry) renderAll();
  }, 20000);
}

// Per-period weekend reveal helpers. Each pay period keeps its own list of
// "revealed" weekend day indices (0=Sun-1, 6=Sat-1, 7=Sun-2, 13=Sat-2).
// Hiding a weekend day just removes it from the list — it never deletes the
// underlying entries or leave.
function isWeekendShown(period, dayIdx) {
  const key = period.days[0];
  const arr = state.shownWeekends[key];
  return Array.isArray(arr) && arr.includes(dayIdx);
}
async function setWeekendShown(period, dayIdx, on) {
  const key = period.days[0];
  const cur = Array.isArray(state.shownWeekends[key]) ? state.shownWeekends[key].slice() : [];
  const has = cur.includes(dayIdx);
  if (on && !has) cur.push(dayIdx);
  if (!on && has) cur.splice(cur.indexOf(dayIdx), 1);
  if (cur.length) state.shownWeekends[key] = cur;
  else delete state.shownWeekends[key];
  try { await DB.setSetting('shownWeekends', state.shownWeekends); } catch {}
}

// "+ Add Sunday/Saturday" button (per period, per weekend day).
function buildAddDayBtn(label, period, dayIdx) {
  return el('button', {
    class: 'add-day-btn',
    onclick: async () => {
      await setWeekendShown(period, dayIdx, true);
      renderPeriodPages();
    },
  }, label);
}

// "× Hide Saturday/Sunday" footer — hides the weekend day card but leaves any
// entries / leave intact (data is not touched).
function buildHideDayBtn(label, period, dayIdx) {
  return el('button', {
    class: 'hide-day-btn',
    onclick: async () => {
      await setWeekendShown(period, dayIdx, false);
      renderPeriodPages();
    },
  }, label);
}

// Count work days remaining in the period (today inclusive). Rules:
//   - A weekday (Mon-Fri) counts UNLESS it's a pure-leave day — 0 hours
//     worked AND some leave entered (you're off, nothing to work).
//   - A weekend day counts ONLY IF it's revealed for this period AND it
//     already has hours worked on it.
// `totals` supplies byDate (worked hours) and leaveMap.
function countWorkdaysRemaining(period, totals) {
  let count = 0;
  for (let i = period.dayIndex; i < T.PAY_PERIOD_DAYS; i++) {
    const d = period.days[i];
    const dow = T.parseLocalDate(d).getDay();
    const worked = (totals.byDate && totals.byDate[d]) || 0;
    const leave = (totals.leaveMap && totals.leaveMap[d]) || 0;
    const isWeekend = dow === 0 || dow === 6;
    if (isWeekend) {
      if (isWeekendShown(period, i) && worked > 0) count++;
    } else {
      if (!(worked === 0 && leave > 0)) count++;
    }
  }
  return count;
}

// Step the week pointer by `dir` (+1 or -1), wrapping into adjacent periods.
// Forward-stops at today's period week 2 (no future).
function advanceWeek(dir) {
  if (dir > 0) {
    if (state.viewedWeek === 1) {
      state.viewedWeek = 2;
    } else if (state.viewedPeriodOffset < 0) {
      state.viewedPeriodOffset += 1;
      state.viewedWeek = 1;
    }
  } else if (dir < 0) {
    if (state.viewedWeek === 2) {
      state.viewedWeek = 1;
    } else {
      state.viewedPeriodOffset -= 1;
      state.viewedWeek = 2;
    }
  }
}

// Attach a simple horizontal-swipe handler. callback(dir) fires once per swipe,
// dir = +1 for left-swipe (next), -1 for right-swipe (prev).
function attachSwipeNav(target, callback) {
  if (!target) return;
  let downX = 0, downY = 0, downT = 0, tracking = false;
  let pointerId = null, justSwiped = false;
  const SWIPE_MIN_PX = 40;       // easier threshold than before
  const SWIPE_MAX_MS = 1200;     // longer time window

  target.addEventListener('pointerdown', (ev) => {
    // Don't start a swipe on drag-handles, buttons, or form controls.
    if (ev.target.closest('.tl-hit, button, input, select, textarea, .leave-mini')) return;
    if (ev.pointerType === 'mouse' && ev.button !== 0) return;
    downX = ev.clientX; downY = ev.clientY; downT = Date.now();
    tracking = true;
    pointerId = ev.pointerId;
  });
  target.addEventListener('pointerup', (ev) => {
    if (!tracking || ev.pointerId !== pointerId) return;
    tracking = false;
    const dx = ev.clientX - downX;
    const dy = ev.clientY - downY;
    const dt = Date.now() - downT;
    if (Math.abs(dx) < SWIPE_MIN_PX) return;
    if (Math.abs(dy) > Math.abs(dx)) return;
    if (dt > SWIPE_MAX_MS) return;
    justSwiped = true;
    setTimeout(() => { justSwiped = false; }, 350);
    callback(dx < 0 ? +1 : -1);
  });
  target.addEventListener('pointercancel', () => { tracking = false; });
  // Swallow any click that fires after a swipe so we don't navigate into a
  // day editor by accident.
  target.addEventListener('click', (ev) => {
    if (justSwiped) {
      ev.stopPropagation();
      ev.preventDefault();
    }
  }, true);
}

// --- Rendering --------------------------------------------------------------

async function renderAll() {
  const view = document.body.dataset.view;
  if (view === 'main') await renderPeriodPages();
  else if (view === 'day') await renderDayView();
  else if (view === 'metrics') await renderMetrics();
  else if (view === 'schedule') renderScheduleView();
  if (state.calendarMode) maybeSyncGoogle();   // throttled background two-way sync
}

// --- Metrics view ----------------------------------------------------------
// Replaces the old Home page. Always shows the CURRENT pay period (today's
// period). Layout: hero number → stats grid → daily-hours chart → either a
// pace chart (Maxiflex mode) or an OT-history chart with range selector (8h
// mode). All math respects the resolved per-period OT mode.

async function renderMetrics() {
  const root = $('metricsContent');
  if (!root) return;
  root.innerHTML = '';

  if (!state.anchor) {
    root.appendChild(el('div', { class: 'metrics-empty' },
      'Set an anchor date in Settings first.'));
    return;
  }

  const period = T.payPeriodFor(new Date(), state.anchor);
  state.period = period;
  const mode = otModeForPeriod(period);
  const totals = await periodTotals(period, mode);
  const remaining = Math.max(0, T.PAY_PERIOD_TARGET - totals.total);
  const workdaysLeft = countWorkdaysRemaining(period, totals);
  const paceHrs = T.pace(totals.total, Math.max(1, workdaysLeft));
  const status = T.paceStatus(totals.total, period.dayIndex);
  const todayStr = T.formatLocalDate(new Date());
  const todayLive = await todayTotalsLive(todayStr, mode);

  // Header strip: period name · paydate
  const periodName = T.payPeriodName(period, state.anchor);
  const paydate = T.paydateFor(period);
  const paydateStr = paydate.toLocaleDateString(undefined,
    { month: 'short', day: 'numeric', year: 'numeric' });
  root.appendChild(el('div', { class: 'metrics-period-line' },
    el('span', { class: 'metrics-period-name' }, periodName),
    el('span', { class: 'metrics-period-paydate' }, `Paydate: ${paydateStr}`),
  ));

  // Hero number — OT in 8h mode, hours-left in Maxiflex (where OT, if any,
  // surfaces in the stats grid below rather than the hero).
  const hero = el('div', { class: 'hero' });
  if (mode) {
    hero.appendChild(el('div', { class: 'hero-label' }, 'OT this period'));
    hero.appendChild(el('div', { class: 'hero-number' }, T.formatHours(totals.ot)));
    if (state.hourlyRate > 0 && totals.ot > 0) {
      hero.appendChild(el('div', { class: 'hero-sub' },
        T.formatMoney(totals.otDollars) + ' OT pay'));
    }
  } else {
    hero.appendChild(el('div', { class: 'hero-label' }, 'Hours left this period'));
    hero.appendChild(el('div', { class: 'hero-number' }, T.formatHours(remaining)));
    const badgeText = status === 'on-pace' ? 'On pace' : status[0].toUpperCase() + status.slice(1);
    hero.appendChild(el('div', { class: 'status-badge ' + status }, badgeText));
  }
  root.appendChild(hero);

  // Stats grid — flexible set of cards depending on mode + OT + hourlyRate.
  const currentYear = new Date().getFullYear();
  const showOT = mode || totals.ot > 0;
  const grid = el('div', { class: 'stats-grid' });
  grid.appendChild(buildStatCard('Worked', T.formatHours(totals.total)));
  grid.appendChild(buildStatCard('Today', T.formatHours(todayLive.total)));
  grid.appendChild(buildStatCard('Days left', String(workdaysLeft)));
  if (!mode) {
    grid.appendChild(buildStatCard('Pace', T.formatHours(paceHrs) + '/d'));
    // In Maxiflex the hero shows hours-left, so surface OT hours as a card.
    if (totals.ot > 0) {
      grid.appendChild(buildStatCard('OT this period', T.formatHours(totals.ot)));
    }
    if (totals.credit > 0) {
      grid.appendChild(buildStatCard('Credit this period', T.formatHours(totals.credit)));
    }
  }
  // YTD hours worked — every period whose paydate falls in this year.
  const ytdHrs = await ytdHoursWorked(currentYear);
  grid.appendChild(buildStatCard(`${currentYear} hrs`, T.formatHours(ytdHrs)));
  if (state.hourlyRate > 0 && showOT) {
    grid.appendChild(buildStatCard('OT $ this period', T.formatMoney(totals.otDollars)));
    const ytd = await ytdOvertime(currentYear);
    grid.appendChild(buildStatCard(`${currentYear} OT $`, T.formatMoney(ytd.dollars)));
  }
  if (state.openEntry) {
    const prior = await dayTotals(todayStr, mode);
    const targetForThisEntry = 8 - prior.worked;
    if (targetForThisEntry > 0) {
      const proj = T.projectedClockOut(state.openEntry.startTime, targetForThisEntry);
      grid.appendChild(buildStatCard('Clock out at', T.formatTime(proj, state.use24h)));
    }
  }
  root.appendChild(grid);

  // Credit-hour bank (Phase 2) — only when the feature is on.
  if (state.creditHoursEnabled) {
    const bank = await computeCreditBank();
    const section = el('div', { class: 'credit-bank-section' });
    section.appendChild(el('h2', { class: 'section-heading' }, 'Credit-hour bank'));
    const bankGrid = el('div', { class: 'stats-grid' });
    bankGrid.appendChild(buildStatCard('Credit balance', T.formatHours(bank.carryOut) + ' h'));
    if (bank.used > 0) {
      bankGrid.appendChild(buildStatCard('Used this period', T.formatHours(bank.used) + ' h'));
    }
    section.appendChild(bankGrid);
    if (bank.lost > 0.0001) {
      section.appendChild(el('div', { class: 'credit-bank-warn' },
        `⚠ ${T.formatHours(bank.lost)} h over the ${T.formatHours(T.CREDIT_CARRYOVER_CAP)}-hour carryover cap will be forfeited at period end. Use credit hours down to ${T.formatHours(T.CREDIT_CARRYOVER_CAP)} h to keep them.`));
    }
    section.appendChild(el('div', { class: 'hint' },
      `Credit hours carry forward, but at most ${T.formatHours(T.CREDIT_CARRYOVER_CAP)} h roll into the next pay period — anything above is lost. Spend credit from a day's "Use credit hours" stepper.`));
    root.appendChild(section);
  }

  // Chart 1: Daily hours bar chart for this period.
  root.appendChild(buildChartSection('This period — daily hours',
    buildDailyHoursChart(period, totals, mode, todayStr),
    buildDailyLegend(showOT)));

  // Chart 2: pace cumulative (Maxiflex mode) OR recent-OT bars (8h mode).
  if (mode) {
    const otChart = await buildRecentOTChart(state.metricsRange);
    root.appendChild(buildChartSection('Recent overtime',
      otChart,
      buildRangeSelector()));
  } else {
    const paceChart = buildPaceChart(period, totals);
    root.appendChild(buildChartSection('This period — pace', paceChart, null));
  }

  // Calendar mode: the "need to schedule" backlog (§7).
  if (state.calendarMode) {
    await renderInvitesInto(root);
    await renderBacklogInto(root);
    maybeRefreshInvites();   // background; re-renders when new invites land
  }
}

// --- Discover / Invites -----------------------------------------------------

// Fetch every enabled source, normalize → upsert pending invites. Socrata
// sources are fetched directly (CORS-OK); proxied sources (ActiveNet, .ics) go
// through `state.proxyBase` and are skipped when none is set. Returns the count
// of NEW pending invites. Pure-ish: all the source-specific logic lives in
// window.Connectors; this just moves bytes and persists.
async function refreshInvites() {
  if (!state.calendarMode || !window.Connectors) return 0;
  let sources;
  try { sources = await DB.getSources(); } catch { return 0; }
  const today = T.formatLocalDate(new Date());
  const home = state.homeLatLng || Connectors.HOME_FALLBACK;
  const proxyBase = (state.proxyBase || '').replace(/\/$/, '');
  let total = 0;
  for (const src of sources) {
    if (src.enabled === false) continue;
    let req;
    try { req = Connectors.prepare(src, { today, home }); } catch { continue; }
    let url = req.url;
    const opts = { method: req.method || 'GET', headers: req.headers || {} };
    if (req.method === 'POST') opts.body = req.body;
    if (req.proxied) {
      if (!proxyBase) continue;   // needs the tunnel; none configured yet
      url = proxyBase + '/proxy?url=' + encodeURIComponent(req.url);
    }
    try {
      const resp = await fetch(url, opts);
      if (!resp.ok) continue;
      const raw = src.type === 'ics' ? await resp.text() : await resp.json();
      const invites = Connectors.ingest(src, raw, { today, home });
      total += await DB.upsertInvites(invites);
      await DB.setSourceFetched(src.id);
    } catch (e) {
      console.warn('source fetch failed:', src.id, e);
    }
  }
  return total;
}

// Background refresh, throttled to once per 10 min (or forced). Re-renders the
// metrics view if new invites arrived while it's showing.
async function maybeRefreshInvites(force) {
  if (!state.calendarMode || state._invitesRefreshing) return;
  const now = Date.now();
  if (!force && state._invitesFetchedAt && now - state._invitesFetchedAt < 10 * 60 * 1000) return;
  state._invitesRefreshing = true;
  try {
    const n = await refreshInvites();
    state._invitesFetchedAt = Date.now();
    if (n > 0 && document.body.dataset.view === 'metrics') renderMetrics();
  } finally {
    state._invitesRefreshing = false;
  }
}

// --- Google Calendar sync ---------------------------------------------------
// Two-way sync of the user's events with their PRIMARY Google calendar, plus a
// read-only mirror of a shared calendar (Ritza's) into her person lane AND the
// Invites lane. Pure OAuth/API/mappers live in google.js (window.GoogleCal);
// this is the DB-reconciliation layer. All of it is calendar-mode gated — plain
// timecard mode never touches it and stays network-free.

function isGoogleConnected() {
  return !!(window.GoogleCal && state.googleClientId && state.googleToken && state.googleToken.access_token);
}

// Return a valid access token, silently refreshing an expired one (or, when
// `interactive`, showing the consent UI). Persists the token locally.
async function ensureGoogleToken(interactive) {
  if (!window.GoogleCal) throw new Error('Google module not loaded');
  if (!state.googleClientId) throw new Error('Enter your Google OAuth client ID first');
  const tok = state.googleToken;
  if (!interactive && tok && tok.access_token && tok.expiresAt > Date.now()) return tok.access_token;
  const wantInteractive = interactive || !tok;
  let resp;
  try {
    resp = await GoogleCal.requestToken(state.googleClientId, { interactive: wantInteractive });
  } catch (e) {
    if (!wantInteractive) throw new Error('Google session expired — tap Connect to re-authorize');
    throw e;
  }
  state.googleToken = resp;
  await DB.setSetting('googleToken', resp);
  return resp.access_token;
}

function setGoogleStatus(msg) {
  const elx = $('googleStatus');
  if (elx) elx.textContent = msg || '';
}

// Reflect connection state onto the settings controls (called from renderSettings
// and after connect/disconnect).
function renderGoogleControls() {
  const connected = isGoogleConnected();
  const idIn = $('googleClientId');
  // Hide the developer client-ID field entirely when one is baked into the app.
  const adv = $('googleAdvanced');
  if (adv) adv.hidden = state.googleClientIdEmbedded;
  if (idIn && !state.googleClientIdEmbedded && document.activeElement !== idIn) {
    idIn.value = state.googleClientIdEmbedded ? '' : (state.googleClientId || '');
  }
  const connectBtn = $('googleConnectBtn');
  if (connectBtn) {
    const label = connectBtn.querySelector('span');
    if (label) label.textContent = connected ? 'Reconnect Google' : 'Sign in with Google';
  }
  const syncBtn = $('googleSyncBtn');
  if (syncBtn) syncBtn.hidden = !connected;
  const disBtn = $('googleDisconnectBtn');
  if (disBtn) disBtn.hidden = !connected;
  const ritzaWrap = $('googleRitzaWrap');
  if (ritzaWrap) ritzaWrap.hidden = !connected;
  const schedWrap = $('scheduleSyncWrap');
  if (schedWrap) schedWrap.hidden = !connected;
  const schedToggle = $('scheduleSyncToggle');
  if (schedToggle) schedToggle.checked = !!state.scheduleSyncEnabled;
  const schedPeriods = $('scheduleSyncPeriodsInput');
  if (schedPeriods && document.activeElement !== schedPeriods) schedPeriods.value = String(state.scheduleSyncPeriodsAhead || 2);
  if (connected && state._googleCalendars) { populateRitzaSelect(); populateScheduleCalSelect(); }
}

// Writable calendars the schedule can be pushed to (own/owner/writer roles).
// Primary is offered as the default first entry.
function populateScheduleCalSelect() {
  const sel = $('scheduleSyncCalendarSelect');
  if (!sel) return;
  const cur = state.scheduleSyncCalendarId || '';
  sel.innerHTML = '';
  sel.appendChild(el('option', { value: '' }, 'Primary (you)'));
  for (const c of (state._googleCalendars || [])) {
    if (c.primary) continue;                              // already covered by "Primary"
    if (c.accessRole && c.accessRole !== 'owner' && c.accessRole !== 'writer') continue;
    sel.appendChild(el('option', { value: c.id }, c.summaryOverride || c.summary || c.id));
  }
  sel.value = cur;
}

function populateRitzaSelect() {
  const sel = $('googleRitzaSelect');
  if (!sel) return;
  const cur = state.googleRitzaCalendarId || '';
  sel.innerHTML = '';
  sel.appendChild(el('option', { value: '' }, '— none —'));
  for (const c of (state._googleCalendars || [])) {
    const label = (c.summaryOverride || c.summary || c.id) + (c.primary ? ' (you)' : '');
    sel.appendChild(el('option', { value: c.id }, label));
  }
  sel.value = cur;
}

async function loadGoogleCalendars() {
  const token = await ensureGoogleToken(false);
  state._googleCalendars = await GoogleCal.listCalendars(token);
  populateRitzaSelect();
  return state._googleCalendars;
}

async function onGoogleConnect() {
  // Prefer the app-wide embedded client id; otherwise fall back to the
  // per-device one from the Advanced field (personal-tool path).
  let clientId = EMBEDDED_GOOGLE_CLIENT_ID;
  if (!clientId) {
    const idInput = $('googleClientId');
    clientId = (idInput && idInput.value || '').trim();
    if (!clientId) { showToast('No Google client ID set — add one under Advanced'); return; }
    await DB.setSetting('googleClientId', clientId);
  }
  state.googleClientId = clientId;
  setGoogleStatus('Connecting…');
  try {
    await ensureGoogleToken(true);
    await loadGoogleCalendars();
    setGoogleStatus('Connected. Syncing…');
    renderGoogleControls();
    await googleSyncNow();
    setGoogleStatus('Connected · last sync just now');
    showToast('Google Calendar connected');
  } catch (e) {
    console.error(e);
    setGoogleStatus('Connection failed: ' + e.message);
    showToast('Google connect failed: ' + e.message);
  }
  renderGoogleControls();
  await renderAll();
}

async function onGoogleDisconnect() {
  try { if (state.googleToken) await GoogleCal.revokeToken(state.googleToken.access_token); } catch {}
  state.googleToken = null;
  state._googleCalendars = null;
  await DB.setSetting('googleToken', null);
  setGoogleStatus('Disconnected. (Already-synced events stay on this device.)');
  showToast('Google disconnected');
  renderGoogleControls();
}

async function onGoogleSyncClick() {
  if (!isGoogleConnected()) { showToast('Connect Google first'); return; }
  setGoogleStatus('Syncing…');
  try {
    await googleSyncNow();
    setGoogleStatus('Synced · just now');
    showToast('Google sync complete');
  } catch (e) {
    console.error(e);
    setGoogleStatus('Sync failed: ' + e.message);
    showToast('Sync failed: ' + e.message);
  }
  await renderAll();
}

// Full sync pass: push local-origin changes up, then pull primary down (so our
// just-pushed events come back matched, never duplicated), then mirror Ritza.
async function googleSyncNow() {
  if (!state.calendarMode || !isGoogleConnected() || state._googleSyncing) return;
  state._googleSyncing = true;
  try {
    const token = await ensureGoogleToken(false);
    const now = new Date();
    const min = new Date(now); min.setMonth(min.getMonth() - 1);
    const max = new Date(now); max.setMonth(max.getMonth() + 6);
    const timeMin = min.toISOString(), timeMax = max.toISOString();
    await pushLocalToGoogle(token);
    // Push local deletions up BEFORE pulling, so events the user deleted are
    // removed from Google and don't get re-pulled (the resurrection bug).
    await pushDeletionsToGoogle(token);
    // Don't pull our own schedule-pushed events back into the in-app calendar
    // (relevant only when the schedule targets the primary calendar).
    const schedMap = (await DB.getSetting('scheduleSyncMap', null)) || {};
    const schedIds = new Set(Object.values(schedMap.items || {}).map(r => r && r.googleId).filter(Boolean));
    await pullGoogleCalendar(token, 'primary', { timeMin, timeMax, color: 'personal', source: 'google', skipIds: schedIds });
    if (state.googleRitzaCalendarId) {
      await pullRitzaCalendar(token, state.googleRitzaCalendarId, { timeMin, timeMax });
    }
    // Optional one-way work-schedule push (off by default). When on, materialize
    // the default schedule for a limited forward window onto the chosen calendar;
    // when off, tear down anything we previously pushed.
    if (state.scheduleSyncEnabled) await syncScheduleToGoogle(token);
    else await cleanupScheduleSync(token);
    state._googleSyncedAt = Date.now();
    await DB.setSetting('googleLastSync', new Date().toISOString());
  } finally {
    state._googleSyncing = false;
  }
}

// Push user-owned events (source local/google) to the primary calendar. New
// ones are inserted (their googleId is saved); locally-edited ones are patched.
// Skips backlog, recurrence overrides, and Ritza's read-only mirror.
async function pushLocalToGoogle(token) {
  const lastSync = (await DB.getSetting('googleLastSync', null)) || '1970-01-01T00:00:00Z';
  const all = await DB.db.events.toArray();
  for (const ev of all) {
    if (ev.needsScheduling || !ev.date) continue;        // backlog
    if (ev.source === 'ritza') continue;                 // read-only mirror
    if (ev.seriesId && !ev.rrule) continue;              // recurrence override — deferred
    const resource = GoogleCal.toGoogleResource(ev);
    try {
      if (!ev.googleId) {
        const created = await GoogleCal.insertEvent(token, 'primary', resource);
        if (created && created.id) {
          await DB.upsertEvent({ ...ev, googleId: created.id, source: ev.source === 'google' ? 'google' : ev.source, gUpdated: created.updated || null });
        }
      } else if ((ev.updatedAt || '') > lastSync) {
        const updated = await GoogleCal.patchEvent(token, 'primary', ev.googleId, resource);
        if (updated && updated.updated) await DB.upsertEvent({ ...ev, gUpdated: updated.updated });
      }
    } catch (e) {
      if (e.status === 404 || e.status === 410) {
        // Remote copy is gone — drop the stale link so a later sync re-creates it.
        await DB.upsertEvent({ ...ev, googleId: null });
      } else {
        console.warn('push failed', ev.id, e.message);
      }
    }
  }
}

// Push local deletions up to Google. Each tombstone (recorded when the user
// deletes an event that has a googleId) becomes a remote DELETE; on success — or
// if the remote is already gone (404/410) — the tombstone is cleared. A failed
// delete keeps its tombstone so the pull skips it and the next sync retries.
async function pushDeletionsToGoogle(token) {
  const tombs = await DB.eventTombstones();
  for (const t of tombs) {
    try {
      await GoogleCal.deleteEvent(token, t.calendarId || 'primary', t.googleId);
      await DB.removeEventTombstone(t.googleId);
    } catch (e) {
      if (e.status === 404 || e.status === 410) {
        await DB.removeEventTombstone(t.googleId);   // already gone remotely
      } else {
        console.warn('delete push failed', t.googleId, e.message);
      }
    }
  }
}

// Pull a calendar into local events (reconciled by googleId). `opts.source` /
// `opts.color` tag the rows. Cancelled events tombstone the local copy. Skips
// rows whose remote `updated` stamp is unchanged to avoid needless churn, and
// rows whose deletion we haven't managed to push up yet (so they don't resurrect).
async function pullGoogleCalendar(token, calendarId, opts) {
  let gevents;
  try { gevents = await GoogleCal.listEvents(token, calendarId, { timeMin: opts.timeMin, timeMax: opts.timeMax }); }
  catch (e) { console.warn('pull failed', calendarId, e.message); return; }
  const tombSet = new Set((await DB.eventTombstones()).map(t => t.googleId));
  for (const g of gevents) {
    if (opts.skipIds && opts.skipIds.has(g.id)) continue;   // our own schedule push
    if (tombSet.has(g.id)) continue;                        // deletion pending push-up
    const mapped = GoogleCal.fromGoogleEvent(g);
    if (!mapped) continue;
    const existing = await DB.eventByGoogleId(g.id);
    if (mapped.cancelled) { if (existing) await DB.deleteEvent(existing.id); continue; }
    if (existing && existing.gUpdated && existing.gUpdated === mapped.updated) continue;
    await DB.upsertEvent({
      id: existing ? existing.id : undefined,
      googleId: g.id,
      title: mapped.title, date: mapped.date, allDay: mapped.allDay,
      startMin: mapped.startMin, endMin: mapped.endMin,
      notes: mapped.notes, location: mapped.location, rrule: mapped.rrule,
      exdates: existing ? existing.exdates : [],
      seriesId: existing ? existing.seriesId : null,
      color: existing ? existing.color : opts.color,
      source: opts.source,
      gUpdated: mapped.updated,
      needsScheduling: false,
    });
  }
}

// Ritza's shared calendar: a read-only 'ritza' mirror (renders in her person
// lane) PLUS pending invites (accept → your own event that then syncs to your
// primary). Mirror rows no longer present on her calendar are reconciled away.
async function pullRitzaCalendar(token, calendarId, opts) {
  let gevents;
  try { gevents = await GoogleCal.listEvents(token, calendarId, { timeMin: opts.timeMin, timeMax: opts.timeMax }); }
  catch (e) { console.warn('ritza pull failed', e.message); return; }
  const today = T.formatLocalDate(new Date());
  const fresh = new Set();
  const invites = [];
  for (const g of gevents) {
    const mapped = GoogleCal.fromGoogleEvent(g);
    if (!mapped) continue;
    const existing = await DB.eventByGoogleId(g.id);
    if (mapped.cancelled) {
      if (existing && existing.source === 'ritza') await DB.deleteEvent(existing.id);
      continue;
    }
    fresh.add(g.id);
    if (!(existing && existing.source === 'ritza' && existing.gUpdated === mapped.updated)) {
      await DB.upsertEvent({
        id: (existing && existing.source === 'ritza') ? existing.id : undefined,
        googleId: g.id,
        title: mapped.title, date: mapped.date, allDay: mapped.allDay,
        startMin: mapped.startMin, endMin: mapped.endMin,
        notes: mapped.notes, location: mapped.location, rrule: mapped.rrule,
        color: 'ritza', source: 'ritza', gUpdated: mapped.updated,
        needsScheduling: false,
      });
    }
    if (mapped.date >= today) {
      invites.push({
        externalId: 'ritza:' + g.id,
        source: 'local',            // accept → my own event (syncs to my primary)
        sourceLabel: 'Ritza',
        title: mapped.title, category: 'invite', color: 'personal',
        date: mapped.date, allDay: mapped.allDay,
        startMin: mapped.startMin, endMin: mapped.endMin,
        location: mapped.location || '', url: null, pending: true,
      });
    }
  }
  if (invites.length) { try { await DB.upsertInvites(invites); } catch (e) { console.warn(e); } }
  // Reconcile: drop in-window mirror rows that vanished from Ritza's calendar.
  const lo = opts.timeMin.slice(0, 10), hi = opts.timeMax.slice(0, 10);
  for (const m of await DB.eventsBySource('ritza')) {
    if (m.googleId && !fresh.has(m.googleId) && m.date >= lo && m.date <= hi) {
      await DB.deleteEvent(m.id);
    }
  }
}

// --- Work-schedule → calendar sync (optional, off by default) ---------------
//
// One-way push of the default work schedule onto a chosen Google calendar (may
// differ from the primary that events sync to), bounded to a LIMITED forward
// window of `scheduleSyncPeriodsAhead` whole pay periods (default 2 = this
// period + next). Reconciled against a local-only bookkeeping map
// (`scheduleSyncMap` = { calendarId, items:{ key:{googleId,sig} } }) so the
// window rolls forward each sync: new in-window days are inserted, edited days
// patched, and days that fall out of the window (or out of the schedule) are
// deleted. Unlike user-added events — which sync for all time — the schedule is
// never carried beyond the window. Materialization is pure (T.buildScheduleSyncEvents).

function scheduleEventSig(e) {
  return [e.title, e.allDay ? 1 : 0, e.startMin, e.endMin, e.date].join('|');
}

// Delete every event we've pushed for the schedule from `calendarId`, returning
// a fresh empty items map. Tolerates already-gone remotes (404/410).
async function deleteScheduleItems(token, calendarId, items) {
  for (const key of Object.keys(items || {})) {
    const rec = items[key];
    if (!rec || !rec.googleId) continue;
    try { await GoogleCal.deleteEvent(token, calendarId, rec.googleId); }
    catch (e) { if (e.status !== 404 && e.status !== 410) console.warn('schedule delete', key, e.message); }
  }
}

async function syncScheduleToGoogle(token) {
  const anchor = await DB.getAnchor();
  if (!anchor) return;                          // no anchor → no pay-period window
  const calId = state.scheduleSyncCalendarId || 'primary';
  const map = (await DB.getSetting('scheduleSyncMap', null)) || { calendarId: calId, items: {} };
  if (!map.items) map.items = {};
  // If the target calendar changed, remove what we put on the old one first so
  // we don't orphan stale schedule events there.
  if (map.calendarId && map.calendarId !== calId) {
    await deleteScheduleItems(token, map.calendarId, map.items);
    map.items = {};
  }
  map.calendarId = calId;

  const schedule = await DB.getDefaultSchedule();
  const holidays = await DB.getHolidays();
  const period = T.payPeriodFor(new Date(), anchor);
  const startStr = T.formatLocalDate(period.start);
  const periodsAhead = Math.max(1, state.scheduleSyncPeriodsAhead | 0);
  const desired = T.buildScheduleSyncEvents(schedule, startStr, periodsAhead, holidays);
  const desiredKeys = new Set(desired.map(e => e.key));

  for (const e of desired) {
    const resource = GoogleCal.toGoogleResource({
      title: e.title, notes: '', location: '',
      date: e.date, allDay: e.allDay, startMin: e.startMin, endMin: e.endMin, rrule: null,
    });
    const rec = map.items[e.key];
    const sig = scheduleEventSig(e);
    try {
      if (!rec || !rec.googleId) {
        const created = await GoogleCal.insertEvent(token, calId, resource);
        if (created && created.id) map.items[e.key] = { googleId: created.id, sig };
      } else if (rec.sig !== sig) {
        await GoogleCal.patchEvent(token, calId, rec.googleId, resource);
        map.items[e.key] = { googleId: rec.googleId, sig };
      }
    } catch (err) {
      if (err.status === 404 || err.status === 410) delete map.items[e.key];
      else console.warn('schedule push', e.key, err.message);
    }
  }
  // Prune anything no longer in the window (rolled past) or no longer scheduled.
  for (const key of Object.keys(map.items)) {
    if (desiredKeys.has(key)) continue;
    const rec = map.items[key];
    try { if (rec && rec.googleId) await GoogleCal.deleteEvent(token, calId, rec.googleId); }
    catch (err) { if (err.status !== 404 && err.status !== 410) console.warn('schedule prune', key, err.message); }
    delete map.items[key];
  }
  await DB.setSetting('scheduleSyncMap', map);
}

// Schedule sync turned off (or never on): tear down anything we pushed so the
// chosen calendar doesn't keep stale schedule events. No-op when nothing synced.
async function cleanupScheduleSync(token) {
  const map = await DB.getSetting('scheduleSyncMap', null);
  if (!map || !map.items || !Object.keys(map.items).length) return;
  await deleteScheduleItems(token, map.calendarId || 'primary', map.items);
  await DB.setSetting('scheduleSyncMap', { calendarId: map.calendarId || '', items: {} });
}

// Background sync, throttled to once per 10 min (or forced). Re-renders the
// current view if anything changed.
async function maybeSyncGoogle(force) {
  if (!state.calendarMode || !isGoogleConnected() || state._googleSyncing) return;
  const now = Date.now();
  if (!force && state._googleSyncedAt && now - state._googleSyncedAt < 10 * 60 * 1000) return;
  try {
    await googleSyncNow();
    const v = document.body.dataset.view;
    if (v === 'metrics') await renderMetrics();
    else if (v === 'main') await renderPeriodPages();
    else if (v === 'day') await renderDayView();
  } catch (e) { console.warn('google sync', e); }
}

// The Invites lane (the curated "unaccepted invites" pile). Accept → drops it
// onto its day as a real event; Dismiss → tombstones it (won't re-appear, and
// later feeds the recommender). PUSH affordance = the count badge in the head.
async function renderInvitesInto(root) {
  let items;
  try { items = await DB.pendingInvites(); } catch { items = []; }
  const today = T.formatLocalDate(new Date());
  items = items.filter(iv => !iv.date || iv.date >= today);

  const wrap = el('div', { class: 'metric-chart invites' });
  const head = el('div', { class: 'metric-chart-head' },
    el('div', { class: 'metric-chart-title' }, 'Invites'),
    items.length ? el('span', { class: 'invite-badge', title: 'New invites' }, String(items.length)) : null,
    el('div', { class: 'invite-head-actions' },
      el('button', { class: 'cal-action-btn', onclick: openSourcesModal }, 'Sources'),
      el('button', {
        class: 'cal-action-btn',
        onclick: async () => { await maybeRefreshInvites(true); renderMetrics(); },
      }, state._invitesRefreshing ? '…' : 'Refresh'),
    ),
  );
  wrap.appendChild(head);

  if (!items.length) {
    wrap.appendChild(el('div', { class: 'backlog-empty' },
      'No invites yet — local events near you show up here to accept or dismiss.'));
    root.appendChild(wrap);
    return;
  }

  for (const iv of items.slice(0, 50)) {
    const dot = el('span', { class: 'ev-dot' });
    dot.style.background = Calendar.colorVar(iv.color || 'personal');
    const meta = [iv.date ? T.formatDateShort(iv.date) : null, iv.location, iv.sourceLabel]
      .filter(Boolean).join(' · ');
    const titleEl = iv.url
      ? el('a', { href: iv.url, target: '_blank', rel: 'noopener', class: 'invite-title-link' }, iv.title)
      : el('span', {}, iv.title);
    wrap.appendChild(el('div', { class: 'backlog-row invite-row' },
      el('div', { class: 'backlog-main' }, dot,
        el('div', { class: 'invite-text' }, titleEl, el('div', { class: 'invite-meta' }, meta))),
      el('div', { class: 'backlog-actions' },
        el('button', {
          class: 'cal-action-btn',
          onclick: async () => {
            await DB.upsertEvent({
              title: iv.title, date: iv.date, allDay: !!iv.allDay,
              startMin: iv.startMin, endMin: iv.endMin,
              color: iv.color || 'personal', location: iv.location || '',
              notes: iv.url ? ('More info: ' + iv.url) : '', source: iv.source,
            });
            await DB.acceptInvite(iv.externalId);
            showToast('Added to ' + (iv.date ? T.formatDateShort(iv.date) : 'your calendar'));
            await renderMetrics();
          },
        }, 'Accept'),
        el('button', {
          class: 'cal-action-btn danger-text',
          onclick: async () => {
            await DB.dismissInvite(iv.externalId);
            showToast('Dismissed', async () => {
              const back = await DB.db.invites.get(iv.externalId);
              if (back) { await DB.db.invites.put({ ...back, status: 'pending' }); await renderMetrics(); }
            });
            await renderMetrics();
          },
        }, 'Dismiss'),
      ),
    ));
  }
  root.appendChild(wrap);
}

// Backlog of needsScheduling events: each can be scheduled onto a day (date
// picker), edited, or deleted. Shown on the Metrics/overview screen.
async function renderBacklogInto(root) {
  let items;
  try { items = await DB.backlogEvents(); }
  catch { items = []; }
  const wrap = el('div', { class: 'metric-chart backlog' });
  wrap.appendChild(el('div', { class: 'metric-chart-head' },
    el('div', { class: 'metric-chart-title' }, 'Need to schedule')));
  if (!items.length) {
    wrap.appendChild(el('div', { class: 'backlog-empty' },
      'Nothing waiting. Add an event with "no date yet" to park it here.'));
    root.appendChild(wrap);
    return;
  }
  items.sort((a, b) => (b.updatedAt || '').localeCompare(a.updatedAt || ''));
  for (const ev of items) {
    const dot = el('span', { class: 'ev-dot' });
    dot.style.background = Calendar.colorVar(ev.color);
    const dateInput = el('input', { type: 'date', class: 'backlog-date' });
    wrap.appendChild(el('div', { class: 'backlog-row' },
      el('div', { class: 'backlog-main' }, dot, el('span', {}, ev.title || '(untitled)')),
      el('div', { class: 'backlog-actions' },
        dateInput,
        el('button', {
          class: 'cal-action-btn',
          onclick: async () => {
            const d = dateInput.value;
            if (!d) { showToast('Pick a date first'); return; }
            await DB.upsertEvent({ ...ev, date: d, needsScheduling: false });
            showToast('Scheduled for ' + T.formatDateShort(d));
            await renderMetrics();
          },
        }, 'Schedule'),
        el('button', { class: 'cal-action-btn', onclick: () => openEventModal(null, ev, 'single') }, 'Edit'),
        el('button', {
          class: 'cal-action-btn danger-text',
          onclick: async () => {
            await DB.deleteEventAndSync(ev.id);
            showToast('Removed from backlog', async () => { await DB.upsertEvent(ev); await renderMetrics(); });
            await renderMetrics();
          },
        }, 'Delete'),
      ),
    ));
  }
  root.appendChild(wrap);
}

// --- Discover: sources manager + add/edit form ------------------------------
// The form IS the filter schema: a source = fetch config + field-map + filters
// (see CLAUDE.md "Filter model"). Progressive disclosure hides what a type/mode
// doesn't use. The (optional) LLM is a later alternate front door to the same form.

function openSourcesModal() { $('sourcesModal').hidden = false; renderSourcesList(); }
function closeSourcesModal() { $('sourcesModal').hidden = true; }

async function renderSourcesList() {
  const list = $('sourcesList');
  list.innerHTML = '';
  let sources = [];
  try { sources = await DB.getSources(); } catch {}
  if (!sources.length) {
    list.appendChild(el('div', { class: 'backlog-empty' }, 'No sources yet — add one to start getting invites.'));
    return;
  }
  for (const s of sources) {
    const toggle = el('input', { type: 'checkbox' });
    toggle.checked = s.enabled !== false;
    toggle.addEventListener('change', async () => {
      await DB.setSourceEnabled(s.id, toggle.checked);
      state._invitesFetchedAt = 0;
    });
    list.appendChild(el('div', { class: 'source-row' },
      el('label', { class: 'toggle-row compact source-toggle' }, toggle, el('span', { class: 'toggle-slider' })),
      el('div', { class: 'source-info' },
        el('div', { class: 'source-label' }, s.label || s.id),
        el('div', { class: 'source-sub' }, describeSource(s))),
      el('div', { class: 'source-actions' },
        el('button', { class: 'cal-action-btn', onclick: () => openSourceForm(s) }, 'Edit'),
        el('button', {
          class: 'cal-action-btn danger-text',
          onclick: async () => {
            await DB.deleteSource(s.id);
            showToast('Source removed', async () => { await DB.upsertSource(s); renderSourcesList(); });
            renderSourcesList();
          },
        }, 'Delete')),
    ));
  }
}

function describeSource(s) {
  const f = s.filters || {}, bits = [s.type];
  const g = f.geo || {};
  if (g.mode === 'radius' && g.radiusFt) bits.push(g.radiusFt >= 5280 ? `≤${(g.radiusFt / 5280).toFixed(g.radiusFt % 5280 ? 1 : 0)} mi` : `≤${g.radiusFt} ft`);
  if (g.mode === 'places' && g.places) bits.push(`${g.places.length} places`);
  if (f.age) bits.push(`ages ${f.age.min}–${f.age.max}`);
  return bits.filter(Boolean).join(' · ');
}

// Form rendering — fields register into sfRefs for readback.
let sfRefs = {};
const splitList = (s) => String(s || '').split(',').map(t => t.trim()).filter(Boolean);
const numOr = (v, d) => { const n = Number(v); return (v !== '' && v != null && isFinite(n)) ? n : d; };

function sfField(key, label, inputEl, vis) {
  sfRefs[key] = inputEl;
  const row = el('div', { class: 'field sf-field' }, el('label', {}, label), inputEl);
  if (vis && vis.types) row.dataset.types = vis.types;
  if (vis && vis.show) row.dataset.show = vis.show;
  return row;
}
function sfText(key, label, val, ph, vis) {
  return sfField(key, label, el('input', { type: 'text', value: val == null ? '' : val, placeholder: ph || '', autocomplete: 'off' }), vis);
}
function sfNum(key, label, val, ph, vis) {
  return sfField(key, label, el('input', { type: 'number', value: val == null ? '' : val, placeholder: ph || '', inputmode: 'numeric' }), vis);
}
function sfSelect(key, label, options, val, vis) {
  const sel = el('select', {});
  for (const o of options) { const op = el('option', { value: o.v }, o.t); if (o.v === val) op.selected = true; sel.appendChild(op); }
  return sfField(key, label, sel, vis);
}
function sfCheck(key, label, checked, vis) {
  const c = el('input', { type: 'checkbox' }); c.checked = !!checked; sfRefs[key] = c;
  const row = el('label', { class: 'toggle-row compact sf-field' }, el('span', {}, label), c, el('span', { class: 'toggle-slider' }));
  if (vis && vis.types) row.dataset.types = vis.types;
  return row;
}
function sfDays(selected) {
  const wrap = el('div', { class: 'byday-picker' });
  for (const d of ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']) {
    const b = el('button', { type: 'button', class: 'byday-day' + ((selected || []).includes(d) ? ' selected' : ''),
      onclick: () => b.classList.toggle('selected') }, d[0]);
    b.dataset.dow = d; wrap.appendChild(b);
  }
  sfRefs._days = wrap;
  return el('div', { class: 'field sf-field' }, el('label', {}, 'Only on days'), wrap);
}
const sfReadDays = () => sfRefs._days ? Array.from(sfRefs._days.querySelectorAll('.byday-day.selected')).map(b => b.dataset.dow) : [];

function sfSection(title, ...rows) {
  return el('div', { class: 'sf-section' }, el('div', { class: 'sf-section-title' }, title), ...rows.filter(Boolean));
}

function openSourceForm(src) {
  state._editingSource = src || null;
  $('sourceFormTitle').textContent = src ? 'Edit source' : 'Add source';
  $('sfDelete').hidden = !src;
  renderSourceForm(src || { type: 'socrata', color: 'personal', map: {}, filters: { geo: { mode: 'anywhere' } } });
  $('sourcesModal').hidden = true;
  $('sourceFormModal').hidden = false;
}
function closeSourceForm() { $('sourceFormModal').hidden = true; state._editingSource = null; }

function renderSourceForm(s) {
  sfRefs = {};
  const map = s.map || {}, F = s.filters || {}, geo = F.geo || { mode: 'anywhere' }, when = F.when || {};
  const colors = [{ v: 'personal', t: 'Personal' }, { v: 'work', t: 'Work' }, { v: 'ritza', t: 'Ritza' }, { v: 'amelia', t: 'Amelia' }];
  const body = $('sourceFormBody');
  body.innerHTML = '';
  body.appendChild(sfSection('Basics',
    sfText('label', 'Name', s.label, 'e.g. Library events near me'),
    sfSelect('type', 'Type', [
      { v: 'socrata', t: 'Socrata dataset (Chicago Data Portal)' },
      { v: 'json', t: 'Generic JSON API' },
      { v: 'ics', t: 'Calendar feed (.ics URL)' },
      { v: 'activenet', t: 'ActiveNet programs (Park District)' },
    ], s.type),
    sfSelect('color', 'Color', colors, s.color || 'personal'),
  ));
  body.appendChild(sfSection('Source',
    sfText('domain', 'Domain', s.domain || 'data.cityofchicago.org', 'data.cityofchicago.org', { types: 'socrata' }),
    sfText('dataset', 'Dataset ID', s.dataset, 'e.g. pk66-w54g', { types: 'socrata' }),
    sfText('url', 'Feed / API URL', s.url, 'https://…', { types: 'json,ics' }),
    sfSelect('method', 'Method', [{ v: 'GET', t: 'GET' }, { v: 'POST', t: 'POST' }], s.method || 'GET', { types: 'json' }),
    sfText('recordPath', 'Records path', s.recordPath, 'e.g. results.items (blank = top level)', { types: 'json' }),
    sfText('host', 'Host', s.host || 'anc.apm.activecommunities.com', '', { types: 'activenet' }),
    sfText('org', 'Org', s.org || 'chicagoparkdistrict', '', { types: 'activenet' }),
    sfText('centerIds', 'Center IDs', (s.search && s.search.center_ids || []).join(', '), 'e.g. 4, 8, 521', { types: 'activenet' }),
  ));
  body.appendChild(sfSection('Map fields → event (which source field is…)',
    sfText('map_title', 'Title', map.title, 'e.g. event_description', { types: 'socrata,json,activenet' }),
    sfText('map_startDate', 'Start date', map.startDate, 'e.g. start_date', { types: 'socrata,json,activenet' }),
    sfText('map_location', 'Location', map.location, 'e.g. park_name', { types: 'socrata,json,activenet' }),
    sfText('map_lat', 'Latitude', map.lat, 'e.g. latitude', { types: 'socrata,json' }),
    sfText('map_lng', 'Longitude', map.lng, 'e.g. longitude', { types: 'socrata,json' }),
    sfText('map_url', 'Detail URL', map.url, '', { types: 'socrata,json,activenet' }),
    sfText('map_category', 'Category', map.category, '', { types: 'socrata,json,activenet' }),
    sfText('map_ageMin', 'Age-min field', map.ageMin, 'e.g. age_min_year', { types: 'activenet,json' }),
    sfText('map_ageMax', 'Age-max field', map.ageMax, 'e.g. age_max_year', { types: 'activenet,json' }),
    sfText('map_fee', 'Fee field', map.fee, '', { types: 'activenet,json' }),
  ));
  body.appendChild(sfSection('Where',
    sfSelect('geoMode', 'Match by', [
      { v: 'anywhere', t: 'Anywhere' }, { v: 'radius', t: 'Within a radius of home' },
      { v: 'places', t: 'Named places' }, { v: 'neighborhoods', t: 'Neighborhoods' },
    ], geo.mode || 'anywhere'),
    sfNum('radiusFt', 'Radius (feet)', geo.radiusFt, 'e.g. 1000', { show: 'geo:radius' }),
    sfText('places', 'Places / neighborhoods', (geo.places || geo.neighborhoods || []).join(', '), 'comma-separated', { show: 'geo:places|neighborhoods' }),
  ));
  body.appendChild(sfSection('When',
    sfNum('horizon', 'Within next N days', when.horizonDays, 'blank = no limit'),
    sfDays(when.daysOfWeek),
    sfSelect('timeOfDay', 'Time of day', [
      { v: 'any', t: 'Any' }, { v: 'morning', t: 'Morning' }, { v: 'afternoon', t: 'Afternoon' }, { v: 'evening', t: 'Evening' }],
      when.timeOfDay || 'any'),
  ));
  body.appendChild(sfSection('Who & cost',
    sfNum('ageMin', 'Age min', F.age && F.age.min),
    sfNum('ageMax', 'Age max', F.age && F.age.max),
    sfCheck('freeOnly', 'Free only', F.cost && F.cost.freeOnly),
    sfNum('maxPrice', 'Max price ($)', F.cost && F.cost.maxPrice),
  ));
  body.appendChild(sfSection('What',
    sfText('include', 'Categories include', (F.category && F.category.include || []).join(', '), 'comma-separated'),
    sfText('exclude', 'Exclude keywords', (F.category && F.category.excludeKeywords || []).join(', '), 'e.g. birthday, camp'),
    sfText('keyword', 'Keyword', F.keyword, ''),
    sfNum('maxResults', 'Max results', F.maxResults, 'e.g. 40'),
  ));
  sfRefs.type.addEventListener('change', sfSyncForm);
  sfRefs.geoMode.addEventListener('change', sfSyncForm);
  sfSyncForm();
}

// Progressive disclosure: show rows whose data-types include the current type,
// and whose data-show geo-mode condition is met.
function sfSyncForm() {
  const type = sfRefs.type.value;
  const geoMode = sfRefs.geoMode ? sfRefs.geoMode.value : 'anywhere';
  for (const row of $('sourceFormBody').querySelectorAll('[data-types]')) {
    row.style.display = row.dataset.types.split(',').includes(type) ? '' : 'none';
  }
  for (const row of $('sourceFormBody').querySelectorAll('[data-show]')) {
    const [dim, vals] = row.dataset.show.split(':');
    let ok = true;
    if (dim === 'geo') ok = vals.split('|').includes(geoMode);
    row.style.display = ok ? '' : 'none';
  }
  // Whole sections with no visible field collapse.
  for (const sec of $('sourceFormBody').querySelectorAll('.sf-section')) {
    const anyVisible = Array.from(sec.querySelectorAll('.sf-field')).some(f => f.style.display !== 'none');
    sec.style.display = anyVisible ? '' : 'none';
  }
}

function readSourceForm() {
  const r = sfRefs, type = r.type.value;
  const id = (state._editingSource && state._editingSource.id) || ('user-' + Date.now().toString(36));
  const src = { id, type, label: r.label.value.trim() || 'My source', color: r.color.value,
    enabled: state._editingSource ? state._editingSource.enabled !== false : true };
  if (type === 'socrata') { src.domain = r.domain.value.trim() || 'data.cityofchicago.org'; src.dataset = r.dataset.value.trim(); }
  else if (type === 'activenet') {
    src.host = r.host.value.trim(); src.org = r.org.value.trim(); src.recordPath = 'body.activity_items'; src.pageSize = 100;
    const ids = splitList(r.centerIds.value); src.search = ids.length ? { center_ids: ids } : {};
  } else if (type === 'ics') { src.url = r.url.value.trim(); }
  else { src.url = r.url.value.trim(); src.method = r.method.value; const rp = r.recordPath.value.trim(); if (rp) src.recordPath = rp; }

  const map = {};
  for (const k of ['title', 'startDate', 'location', 'lat', 'lng', 'url', 'category', 'ageMin', 'ageMax', 'fee']) {
    const v = r['map_' + k] && r['map_' + k].value.trim(); if (v) map[k] = v;
  }
  if (Object.keys(map).length) src.map = map;

  const filters = {}, geoMode = r.geoMode.value, geo = { mode: geoMode };
  if (geoMode === 'radius') { geo.anchor = 'home'; geo.radiusFt = numOr(r.radiusFt.value, 5280); }
  if (geoMode === 'places' || geoMode === 'neighborhoods') {
    const p = splitList(r.places.value); geo[geoMode === 'places' ? 'places' : 'neighborhoods'] = p;
  }
  filters.geo = geo;
  const when = {};
  const hz = numOr(r.horizon.value, null); if (hz) when.horizonDays = hz;
  const days = sfReadDays(); if (days.length) when.daysOfWeek = days;
  if (r.timeOfDay.value !== 'any') when.timeOfDay = r.timeOfDay.value;
  if (Object.keys(when).length) filters.when = when;
  const aMin = numOr(r.ageMin.value, null), aMax = numOr(r.ageMax.value, null);
  if (aMin != null && aMax != null) filters.age = { min: aMin, max: aMax };
  const cost = {}; if (r.freeOnly.checked) cost.freeOnly = true;
  const mp = numOr(r.maxPrice.value, null); if (mp != null) cost.maxPrice = mp;
  if (Object.keys(cost).length) filters.cost = cost;
  const cat = {}; const inc = splitList(r.include.value); if (inc.length) cat.include = inc;
  const exc = splitList(r.exclude.value); if (exc.length) cat.excludeKeywords = exc;
  if (Object.keys(cat).length) filters.category = cat;
  if (r.keyword.value.trim()) filters.keyword = r.keyword.value.trim();
  const max = numOr(r.maxResults.value, null); if (max != null) filters.maxResults = max;
  src.filters = filters;
  return src;
}

async function saveSourceFromForm() {
  let src;
  try { src = readSourceForm(); } catch { showToast('Check the fields'); return; }
  if (!src.label) { showToast('Give it a name'); return; }
  if (src.type === 'socrata' && !src.dataset) { showToast('Dataset ID required'); return; }
  if ((src.type === 'json' || src.type === 'ics') && !src.url) { showToast('URL required'); return; }
  if (src.type === 'activenet' && (!src.host || !src.org)) { showToast('Host + org required'); return; }
  if ((src.type === 'socrata' || src.type === 'json') && (!src.map || !src.map.title || !src.map.startDate)) {
    showToast('Map at least Title + Start date'); return;
  }
  try { await DB.upsertSource(src); } catch (e) { showToast('Save failed: ' + e.message); return; }
  closeSourceForm();
  showToast('Source saved');
  openSourcesModal();
  state._invitesFetchedAt = 0;
  maybeRefreshInvites(true).then(() => { if (document.body.dataset.view === 'metrics') renderMetrics(); });
}

async function deleteSourceFromForm() {
  const s = state._editingSource;
  if (s) { await DB.deleteSource(s.id); showToast('Source removed'); }
  closeSourceForm();
  openSourcesModal();
}

function buildStatCard(label, value) {
  return el('div', { class: 'stat' },
    el('div', { class: 'stat-label' }, label),
    el('div', { class: 'stat-value' }, value),
  );
}

function buildChartSection(title, chartEl, accessoryEl) {
  const wrap = el('div', { class: 'metric-chart' });
  const head = el('div', { class: 'metric-chart-head' },
    el('div', { class: 'metric-chart-title' }, title));
  if (accessoryEl) head.appendChild(accessoryEl);
  wrap.appendChild(head);
  wrap.appendChild(chartEl);
  return wrap;
}

// Range chips for the recent-OT chart. Tap → re-render metrics with the new
// range and persist it to settings.
function buildRangeSelector() {
  const wrap = el('div', { class: 'range-selector' });
  const ranges = [
    { id: '8pp',  label: '8 PP' },
    { id: 'ytd',  label: 'YTD'  },
    { id: '6mo',  label: '6 mo' },
    { id: '1yr',  label: '1 yr' },
  ];
  for (const r of ranges) {
    const chip = el('button', {
      class: 'range-chip' + (state.metricsRange === r.id ? ' active' : ''),
      onclick: async () => {
        if (state.metricsRange === r.id) return;
        state.metricsRange = r.id;
        try { await DB.setSetting('metricsRange', r.id); } catch {}
        renderMetrics();
      },
    }, r.label);
    wrap.appendChild(chip);
  }
  return wrap;
}

function buildDailyLegend(showOT) {
  const wrap = el('div', { class: 'chart-legend' });
  wrap.appendChild(legendSwatch('regular', 'Regular'));
  if (showOT) wrap.appendChild(legendSwatch('ot', 'OT'));
  wrap.appendChild(legendSwatch('leave', 'Leave'));
  return wrap;
}
function legendSwatch(cls, label) {
  return el('span', { class: 'legend-item' },
    el('span', { class: 'legend-swatch ' + cls }),
    label);
}

// Daily hours bar chart — 14 bars, stacked regular/OT/leave, 8h reference
// line when in 8h mode. Today's bar gets a highlight. SVG with viewBox so it
// scales to the container width.
function buildDailyHoursChart(period, totals, mode, todayStr) {
  const W = 320, H = 140;
  const padL = 20, padR = 8, padT = 8, padB = 22;
  const innerW = W - padL - padR;
  const innerH = H - padT - padB;
  // Y axis max: ceil of max daily total or 10, whichever is larger.
  let maxVal = 10;
  for (const d of period.days) {
    const v = (totals.byDate[d] || 0) + (totals.leaveMap[d] || 0);
    if (v > maxVal) maxVal = v;
  }
  maxVal = Math.ceil(maxVal / 2) * 2;
  const yFor = (v) => padT + innerH - (v / maxVal) * innerH;
  const barW = innerW / 14 * 0.78;
  const slotW = innerW / 14;

  const svg = svgEl('svg', {
    class: 'chart-svg',
    viewBox: `0 0 ${W} ${H}`,
    preserveAspectRatio: 'none',
  });

  // Y gridlines + labels at 0, max/2, max
  for (const v of [0, maxVal / 2, maxVal]) {
    const y = yFor(v);
    svg.appendChild(svgEl('line', {
      x1: padL, x2: W - padR, y1: y, y2: y,
      class: 'chart-grid',
    }));
    svg.appendChild(svgEl('text', {
      x: padL - 4, y: y + 3, class: 'chart-axis-text', 'text-anchor': 'end',
    }, String(Math.round(v))));
  }

  // 8h reference line in 8h mode
  if (mode && 8 <= maxVal) {
    svg.appendChild(svgEl('line', {
      x1: padL, x2: W - padR, y1: yFor(8), y2: yFor(8),
      class: 'chart-ref-8h',
    }));
  }

  // 14 bars
  for (let i = 0; i < period.days.length; i++) {
    const d = period.days[i];
    const worked = totals.byDate[d] || 0;
    const leave = totals.leaveMap[d] || 0;
    const overtime = Math.min(worked, (totals.otByDate && totals.otByDate[d]) || 0);
    const split = { regular: Math.max(0, worked - overtime), overtime };
    const x = padL + i * slotW + (slotW - barW) / 2;
    let yCursor = yFor(0); // baseline (bottom)
    // Stack order from bottom: regular → OT → leave
    if (split.regular > 0) {
      const h = (split.regular / maxVal) * innerH;
      yCursor -= h;
      svg.appendChild(svgEl('rect', {
        x, y: yCursor, width: barW, height: h, class: 'bar-regular',
      }));
    }
    if (split.overtime > 0) {
      const h = (split.overtime / maxVal) * innerH;
      yCursor -= h;
      svg.appendChild(svgEl('rect', {
        x, y: yCursor, width: barW, height: h, class: 'bar-ot',
      }));
    }
    if (leave > 0) {
      const h = (leave / maxVal) * innerH;
      yCursor -= h;
      svg.appendChild(svgEl('rect', {
        x, y: yCursor, width: barW, height: h, class: 'bar-leave',
      }));
    }
    // Today marker: outline + dot below
    if (d === todayStr) {
      svg.appendChild(svgEl('rect', {
        x: x - 1, y: padT, width: barW + 2, height: innerH,
        class: 'bar-today-frame',
      }));
    }
    // X label: weekday initial
    const dow = T.parseLocalDate(d).getDay();
    const initial = ['S','M','T','W','T','F','S'][dow];
    svg.appendChild(svgEl('text', {
      x: x + barW / 2, y: H - 8,
      class: 'chart-axis-text' + (d === todayStr ? ' today' : ''),
      'text-anchor': 'middle',
    }, initial));
  }

  return svg;
}

// Pace cumulative line chart (Maxiflex / non-8h mode). Shows actual cumulative
// hours, the ideal-pace dashed line (80 × N/14), and the 80h target line.
function buildPaceChart(period, totals) {
  const W = 320, H = 140;
  const padL = 24, padR = 8, padT = 8, padB = 22;
  const innerW = W - padL - padR;
  const innerH = H - padT - padB;
  const maxVal = Math.max(80, totals.total + 4);
  const yFor = (v) => padT + innerH - (v / maxVal) * innerH;
  const xFor = (i) => padL + (i / 13) * innerW;

  const svg = svgEl('svg', { class: 'chart-svg', viewBox: `0 0 ${W} ${H}` });

  // Gridlines at 0/40/80
  for (const v of [0, 40, 80]) {
    const y = yFor(v);
    svg.appendChild(svgEl('line', {
      x1: padL, x2: W - padR, y1: y, y2: y,
      class: 'chart-grid' + (v === 80 ? ' chart-grid-target' : ''),
    }));
    svg.appendChild(svgEl('text', {
      x: padL - 4, y: y + 3, class: 'chart-axis-text', 'text-anchor': 'end',
    }, String(v)));
  }

  // Ideal pace dashed line
  const idealPts = [];
  for (let i = 0; i < 14; i++) idealPts.push(`${xFor(i)},${yFor(80 * (i + 1) / 14)}`);
  svg.appendChild(svgEl('polyline', {
    points: idealPts.join(' '),
    class: 'pace-ideal',
  }));

  // Actual cumulative — sum up to and including today's index
  const actualPts = [];
  let cum = 0;
  for (let i = 0; i <= period.dayIndex && i < 14; i++) {
    const d = period.days[i];
    cum += (totals.byDate[d] || 0) + (totals.leaveMap[d] || 0);
    actualPts.push(`${xFor(i)},${yFor(cum)}`);
  }
  if (actualPts.length > 0) {
    svg.appendChild(svgEl('polyline', {
      points: actualPts.join(' '),
      class: 'pace-actual',
    }));
    // End point dot
    const last = actualPts[actualPts.length - 1].split(',');
    svg.appendChild(svgEl('circle', {
      cx: last[0], cy: last[1], r: 3, class: 'pace-actual-dot',
    }));
  }

  // X labels (every 2 days)
  for (let i = 0; i < 14; i += 2) {
    svg.appendChild(svgEl('text', {
      x: xFor(i), y: H - 8, class: 'chart-axis-text', 'text-anchor': 'middle',
    }, String(i + 1)));
  }

  return svg;
}

// Recent-overtime bar chart — driven by `range` ('8pp' | 'ytd' | '6mo' | '1yr').
// Each bar = that period's OT hours under THAT period's resolved mode.
// Tap a bar → switch to Week view at that period.
async function buildRecentOTChart(range) {
  const all = await allPeriodsWithData();
  // Sort by start date ascending then pick the slice for the chosen range.
  all.sort((a, b) => a.start - b.start);
  const today = new Date(); today.setHours(0, 0, 0, 0);

  let chosen;
  if (range === 'ytd') {
    const year = today.getFullYear();
    chosen = all.filter(p => T.paydateYear(p) === year);
  } else if (range === '6mo') {
    const cutoff = new Date(today); cutoff.setMonth(cutoff.getMonth() - 6);
    chosen = all.filter(p => p.start >= cutoff);
  } else if (range === '1yr') {
    const cutoff = new Date(today); cutoff.setFullYear(cutoff.getFullYear() - 1);
    chosen = all.filter(p => p.start >= cutoff);
  } else {
    chosen = all.slice(-8);
  }

  // Compute OT per chosen period under its own mode. Maxiflex periods can now
  // carry OT too, so they are no longer forced to zero.
  const data = [];
  for (const p of chosen) {
    const mode = otModeForPeriod(p);
    const t = await periodTotals(p, mode);
    data.push({ period: p, ot: t.ot, mode });
  }

  const W = 320, H = 140;
  const padL = 24, padR = 8, padT = 8, padB = 22;
  const innerW = W - padL - padR;
  const innerH = H - padT - padB;
  let maxVal = 4;
  for (const r of data) if (r.ot > maxVal) maxVal = r.ot;
  maxVal = Math.max(2, Math.ceil(maxVal));
  const yFor = (v) => padT + innerH - (v / maxVal) * innerH;
  const slotW = innerW / Math.max(1, data.length);
  const barW = Math.max(2, slotW * 0.72);

  const svg = svgEl('svg', { class: 'chart-svg', viewBox: `0 0 ${W} ${H}` });

  // Gridlines at 0, half, max
  for (const v of [0, maxVal / 2, maxVal]) {
    const y = yFor(v);
    svg.appendChild(svgEl('line', {
      x1: padL, x2: W - padR, y1: y, y2: y, class: 'chart-grid',
    }));
    svg.appendChild(svgEl('text', {
      x: padL - 4, y: y + 3, class: 'chart-axis-text', 'text-anchor': 'end',
    }, String(Math.round(v))));
  }

  if (data.length === 0) {
    svg.appendChild(svgEl('text', {
      x: W / 2, y: H / 2, class: 'chart-empty', 'text-anchor': 'middle',
    }, 'No data in range'));
    return svg;
  }

  // Bars + labels (label only every Nth bar so we don't crowd).
  const labelStride = data.length > 14 ? Math.ceil(data.length / 8)
    : (data.length > 8 ? 2 : 1);
  for (let i = 0; i < data.length; i++) {
    const r = data[i];
    const x = padL + i * slotW + (slotW - barW) / 2;
    const h = (r.ot / maxVal) * innerH;
    const y = yFor(r.ot);
    // Hit target for tap (larger than the visible bar so easier to tap)
    const hit = svgEl('rect', {
      x: padL + i * slotW, y: padT,
      width: slotW, height: innerH,
      class: 'bar-ot-hit',
    });
    const offset = Math.round((r.period.start - T.payPeriodFor(today, state.anchor).start)
      / (T.PAY_PERIOD_DAYS * 24 * 60 * 60 * 1000));
    hit.addEventListener('click', () => {
      // Land on the right offset and switch to Week 1 of that period.
      state.viewedPeriodOffset = offset;
      state.viewedPage = 0;
      setView('main');
      renderPeriodPages();
      requestAnimationFrame(() => scrollCarouselTo(0, true));
    });
    svg.appendChild(hit);
    if (h > 0) {
      svg.appendChild(svgEl('rect', {
        x, y, width: barW, height: h,
        class: 'bar-ot',
      }));
    }
    if (i % labelStride === 0 || i === data.length - 1) {
      // Use just the PPNN suffix to keep labels short
      const nm = T.payPeriodName(r.period, state.anchor);
      const short = nm.replace(/^\d{4}-/, '');
      svg.appendChild(svgEl('text', {
        x: x + barW / 2, y: H - 8,
        class: 'chart-axis-text', 'text-anchor': 'middle',
      }, short));
    }
  }

  return svg;
}

// SVG element helper (createElementNS so attributes hold on inline SVG).
function svgEl(tag, attrs = {}, text) {
  const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === false || v == null) continue;
    el.setAttribute(k, v);
  }
  if (text != null) el.textContent = text;
  return el;
}

// Render BOTH week pages (Week 1 and Week 2 of the current period offset).
// Each page in the carousel gets its own period nav + meta + day list.
async function renderPeriodPages() {
  if (!state.anchor) return;
  const viewed = T.payPeriodOffset(new Date(), state.anchor, state.viewedPeriodOffset);
  const periodMode = otModeForPeriod(viewed);
  const totals = await periodTotals(viewed, periodMode);
  // Per-period flex default (Maxiflex only): new entries bank beyond-schedule
  // hours as credit (true) instead of overtime (false). LOGIC-FREEZE §4.3.
  const creditDefault = await DB.getCreditDefaultForPeriodStart(viewed.days[0]);
  const dShort = (d) => T.parseLocalDate(d).toLocaleDateString(undefined,
    { month: 'short', day: 'numeric' });
  const startStr = dShort(viewed.days[0]);
  const endStr = dShort(viewed.days[13]);
  const name = T.payPeriodName(viewed, state.anchor);
  const paydate = T.paydateFor(viewed);
  const paydateStr = paydate.toLocaleDateString(undefined,
    { month: 'short', day: 'numeric' });

  for (const wk of [1, 2]) {
    $('periodName' + 'W' + wk).textContent = name;

    // Subline: date range · paydate (quiet gray).
    $('periodSublineW' + wk).textContent =
      `${startStr} – ${endStr}  ·  Paydate ${paydateStr}`;

    // Stats line: hrs / 80, OT hrs, OT pay — each its own span.
    const statsEl = $('periodStatsW' + wk);
    statsEl.innerHTML = '';
    statsEl.appendChild(el('span', { class: 'ps-hrs' },
      `${T.formatHours(totals.total)} / 80 hrs`));
    if (totals.ot > 0) {
      statsEl.appendChild(el('span', { class: 'ps-ot' },
        `+${T.formatHours(totals.ot)} OT`));
      if (state.hourlyRate > 0) {
        statsEl.appendChild(el('span', { class: 'ps-pay' },
          T.formatMoney(totals.otDollars)));
      }
    }
    if (totals.credit > 0) {
      statsEl.appendChild(el('span', { class: 'ps-credit' },
        `+${T.formatHours(totals.credit)} credit`));
    }

    // Per-period OT/Maxiflex segmented control: highlight the active mode.
    const modeCtrl = $('periodModeW' + wk);
    if (modeCtrl) {
      for (const btn of modeCtrl.querySelectorAll('.seg-btn')) {
        const btnIsOt = btn.dataset.mode === 'ot';
        btn.classList.toggle('active', btnIsOt === !!periodMode);
      }
    }

    // Per-period flex default ("Overtime | Credit") — shown only in Maxiflex
    // mode (8-hour mode ignores payKind). Sets the default for NEW entries only.
    const creditWrap = $('creditDefaultWrapW' + wk);
    if (creditWrap) {
      // Hidden in 8-hour mode AND whenever the credit-hours feature is off.
      creditWrap.hidden = !!periodMode || !state.creditHoursEnabled;
      if (!periodMode && state.creditHoursEnabled) {
        const creditCtrl = $('creditModeW' + wk);
        for (const btn of creditCtrl.querySelectorAll('.seg-btn')) {
          const btnIsCredit = btn.dataset.credit === 'credit';
          btn.classList.toggle('active', btnIsCredit === creditDefault);
        }
        $('creditDefaultHintW' + wk).textContent = creditDefault
          ? 'New entries bank beyond-schedule hours as credit (1:1, no premium). Existing entries are unchanged.'
          : 'New entries pay beyond-schedule hours over 80 as overtime (1.5×). Existing entries are unchanged.';
      }
    }
  }

  const todayStr = T.formatLocalDate(new Date());
  const allEntries = await DB.entriesForPeriod(viewed);
  const entriesByDate = {};
  for (const d of viewed.days) entriesByDate[d] = [];
  for (const e of allEntries) {
    if (entriesByDate[e.date]) entriesByDate[e.date].push(e);
  }

  // Calendar mode: fetch this period's events (incl. expanded recurrences),
  // bucketed by day, for the lanes.
  const eventsByDate = state.calendarMode
    ? await resolveEventsForPeriod(viewed)
    : {};
  state._eventsByDate = eventsByDate;

  for (const wk of [1, 2]) {
    const list = $('dayListW' + wk);
    list.innerHTML = '';
    const weekStart = wk === 1 ? 0 : 7;
    const sundayIdx = weekStart;
    const saturdayIdx = weekStart + 6;

    // Sunday: always shown in calendar mode; otherwise per-period reveal with
    // a hide footer (revealed) or an add button (hidden).
    if (state.calendarMode || isWeekendShown(viewed, sundayIdx)) {
      list.appendChild(buildDayCard(viewed.days[sundayIdx], totals, todayStr, entriesByDate[viewed.days[sundayIdx]], periodMode));
      if (!state.calendarMode) list.appendChild(buildHideDayBtn('× Hide Sunday', viewed, sundayIdx));
    } else {
      list.appendChild(buildAddDayBtn('+ Add Sunday', viewed, sundayIdx));
    }

    // Mon-Fri always
    for (let i = weekStart + 1; i < weekStart + 6; i++) {
      const d = viewed.days[i];
      list.appendChild(buildDayCard(d, totals, todayStr, entriesByDate[d], periodMode));
    }

    // Saturday: same pattern
    if (state.calendarMode || isWeekendShown(viewed, saturdayIdx)) {
      list.appendChild(buildDayCard(viewed.days[saturdayIdx], totals, todayStr, entriesByDate[viewed.days[saturdayIdx]], periodMode));
      if (!state.calendarMode) list.appendChild(buildHideDayBtn('× Hide Saturday', viewed, saturdayIdx));
    } else {
      list.appendChild(buildAddDayBtn('+ Add Saturday', viewed, saturdayIdx));
    }
    requestAnimationFrame(() => reflowList(list));
  }
}

// Per-period OT-mode toggle (Maxiflex <-> 8-hour), driven by the visible
// segmented control (or the legacy long-press). Both modes can carry OT now,
// so we confirm only when the switch would REDUCE this period's overtime —
// comparing OT under the current vs. the next mode.
async function onTogglePeriodMode(period, currentMode) {
  const nextMode = !currentMode;
  const curT = await periodTotals(period, currentMode);
  const nextT = await periodTotals(period, nextMode);
  if (nextT.ot < curT.ot - 0.001) {
    pendingModeChange = { period, nextMode };
    const nm = T.payPeriodName(period, state.anchor);
    const lost = curT.ot - nextT.ot;
    $('modeConfirmTitle').textContent =
      `Switch ${nm} to ${nextMode ? '8-hour OT' : 'Maxiflex'}?`;
    const dollars = state.hourlyRate > 0
      ? ` (${T.formatMoney(curT.otDollars - nextT.otDollars)})`
      : '';
    $('modeConfirmText').textContent =
      `Overtime for this period drops by ${T.formatHours(lost)} hrs${dollars} ` +
      `(${T.formatHours(curT.ot)} → ${T.formatHours(nextT.ot)}). ` +
      `Entries are untouched. You can switch back any time.`;
    $('modeConfirmModal').hidden = false;
    return;
  }
  await applyPeriodMode(period, nextMode);
  const nm = T.payPeriodName(period, state.anchor);
  showToast(`${nm} → ${nextMode ? '8-hour' : 'Maxiflex'} mode`);
}

// Apply a per-period mode override (and persist), then re-render.
async function applyPeriodMode(period, nextMode) {
  const key = T.formatLocalDate(period.start);
  // If next matches the default, clear the override; otherwise set it.
  if (nextMode === state.otModeDefault) {
    delete state.otModeOverrides[key];
    await DB.setOvertimeModeOverride(key, null);
  } else {
    state.otModeOverrides[key] = nextMode;
    await DB.setOvertimeModeOverride(key, nextMode);
  }
  vibrate(8);
  await renderAll();
}

// Set by onTogglePeriodMode when an OT-erasure confirm is required.
let pendingModeChange = null;

// Back-compat alias: anywhere that previously called renderPeriodView now
// re-renders both week pages.
function renderPeriodView() { return renderPeriodPages(); }

// Smoothly (or instantly) scroll the carousel to the given page index.
function scrollCarouselTo(idx, instant) {
  const carousel = $('mainCarousel');
  if (!carousel) return;
  const target = (carousel.clientWidth || 0) * idx;
  state.viewedPage = idx;
  carousel.scrollTo({ left: target, behavior: instant ? 'instant' : 'smooth' });
  updatePageDots();
}

function updatePageDots() {
  for (const dot of $('pageDots').children) {
    dot.classList.toggle('active', Number(dot.dataset.pageIdx) === state.viewedPage);
  }
}

// Expand/collapse a day card in place (calendar mode). Only one day is ever
// expanded at a time; tapping the open day collapses it.
function toggleDayExpand(d) {
  state.expandedDay = state.expandedDay === d ? null : d;
  vibrate(6);
  renderPeriodView();
}

// Resolve all events visible in a period: plain/override events whose date falls
// in the window, PLUS occurrences expanded from every recurring series (which
// may be anchored outside the window). Recurring series rows are NOT rendered
// directly — only their expansion is. Returns { [date]: events[] }.
async function resolveEventsForPeriod(period) {
  const map = {};
  for (const d of period.days) map[d] = [];
  const direct = await DB.eventsForPeriod(period);
  for (const ev of direct) {
    if (ev.rrule) continue;              // series: rendered via expansion below
    if (map[ev.date]) map[ev.date].push(ev);
  }
  const series = await DB.recurringSeries();
  const winStart = period.days[0], winEnd = period.days[period.days.length - 1];
  for (const s of series) {
    for (const occ of Calendar.expandSeries(s, winStart, winEnd)) {
      if (map[occ.date]) map[occ.date].push(occ);
    }
  }
  return map;
}

// Same idea for a single day: direct events + any series occurrences that day.
async function resolveEventsForDay(dateStr) {
  const out = [];
  for (const ev of await DB.eventsForDate(dateStr)) if (!ev.rrule) out.push(ev);
  for (const s of await DB.recurringSeries()) {
    for (const occ of Calendar.expandSeries(s, dateStr, dateStr)) out.push(occ);
  }
  return out;
}

// Mirror events from a shared/external calendar (Ritza's) are read-only — they
// reflect someone else's calendar and must not be edited or dragged here.
function isReadOnlyEvent(ev) { return !!(ev && ev.source === 'ritza'); }

// Format minutes-since-midnight as a wall-clock time honoring the 24h setting.
function fmtMinOfDay(min) {
  const h = Math.floor(min / 60) % 24, m = ((min % 60) + 60) % 60;
  return T.formatTime(new Date(2000, 0, 1, h, m), state.use24h);
}

// Small read-only summary for a mirrored event (tapped in the lane).
function showReadOnlyEventInfo(ev) {
  const parts = [ev.title || '(untitled)'];
  if (!ev.allDay && isFinite(ev.startMin)) {
    parts.push(fmtMinOfDay(ev.startMin) + (isFinite(ev.endMin) ? '–' + fmtMinOfDay(ev.endMin) : ''));
  } else {
    parts.push('All day');
  }
  if (ev.location) parts.push(ev.location);
  showToast(parts.join(' · ') + ' · read-only');
}

// Build the event-lane strip that sits above the "Me line" in calendar mode.
// Timed events stack into lanes (Me-line work/personal first, person lanes
// above); all-day events ride a thin band at the very top. Positioned by
// dataset.leftMin/widthMin so reflowList aligns them to the timeline's scale.
function buildCalLanes(dateStr, events) {
  const lanes = el('div', { class: 'cal-lanes' });
  const expanded = state.calendarMode && state.expandedDay === dateStr;

  const allDay = [];
  const timed = [];
  for (const ev of events) {
    if (ev.allDay || !isFinite(ev.startMin) || !isFinite(ev.endMin)) allDay.push(ev);
    else timed.push(ev);
  }

  // Quick-add surface (expanded only): a drag on empty lane space sketches a new
  // event's time range, then opens the editor pre-filled. Sits behind events.
  if (expanded) {
    const surface = el('div', { class: 'cal-add-surface' });
    attachQuickAddDrag(lanes, surface, dateStr);
    lanes.appendChild(surface);
  }

  // One tooltip per strip, shown by the drag handlers.
  const tooltip = el('div', { class: 'cal-tip' });
  lanes.appendChild(tooltip);

  // "Me" events (work + personal) ALL ride the main bar's band — that's "my
  // time" — so they overlap the work bar; their lane index is ignored
  // vertically. Person events (Ritza/Amelia) stack just above, touching and
  // partially overlapping the bar, by their own lane index.
  const meEvents = timed.filter(e => Calendar.laneForColor(e.color) === 'me');
  const personEvents = timed.filter(e => Calendar.laneForColor(e.color) === 'person');
  const personStack = Calendar.stackEvents(personEvents);

  const addBar = (ev, laneIndex, kind) => {
    const startMin = Math.max(0, ev.startMin | 0);
    const endMin = Math.max(startMin + 15, ev.endMin | 0);
    const bar = el('div', {
      class: 'cal-ev ' + kind,
      title: ev.title || '(untitled)',
    }, el('span', { class: 'cal-ev-label' }, ev.title || '(untitled)'));
    bar.style.setProperty('--lane', String(laneIndex));
    bar.style.background = Calendar.colorVar(ev.color);
    bar.dataset.leftMin = String(startMin);
    bar.dataset.widthMin = String(endMin - startMin);
    if (isReadOnlyEvent(ev)) bar.classList.add('ro');
    lanes.appendChild(bar);

    // Read-only mirror events (e.g. Ritza's shared calendar) and recurring
    // occurrences (virtual; their id is the series id) are not drag-mutable.
    // Only concrete, owned, non-recurring events are draggable.
    if (expanded && !ev._occurrenceOf && !isReadOnlyEvent(ev)) {
      // Drag the body to move; drag the edge handles to resize. A tap that
      // doesn't move opens the editor.
      attachEventDrag(lanes, bar, bar, ev, dateStr, 'move', tooltip, laneIndex);
      const startH = el('div', { class: 'cal-ev-handle ' + kind + ' start' });
      const endH = el('div', { class: 'cal-ev-handle ' + kind + ' end' });
      for (const h of [startH, endH]) h.style.setProperty('--lane', String(laneIndex));
      startH.dataset.leftMin = String(startMin);
      endH.dataset.leftMin = String(endMin);
      attachEventDrag(lanes, startH, bar, ev, dateStr, 'start', tooltip, laneIndex, startH, endH);
      attachEventDrag(lanes, endH, bar, ev, dateStr, 'end', tooltip, laneIndex, startH, endH);
      lanes.appendChild(startH);
      lanes.appendChild(endH);
    } else {
      if (ev._occurrenceOf) bar.classList.add('recurs');
      bar.addEventListener('click', (e) => {
        e.stopPropagation();
        if (isReadOnlyEvent(ev)) showReadOnlyEventInfo(ev);
        else editCalEvent(ev, dateStr);
      });
    }
  };

  for (const ev of meEvents) addBar(ev, 0, 'me');
  for (const ev of personEvents) addBar(ev, personStack.laneOf.get(ev), 'person');

  // All-day events: full-width bands stacked from the top.
  allDay.forEach((ev, i) => {
    const band = el('div', {
      class: 'cal-ev allday' + (isReadOnlyEvent(ev) ? ' ro' : ''),
      title: ev.title || '(untitled)',
      onclick: (e) => {
        e.stopPropagation();
        if (isReadOnlyEvent(ev)) showReadOnlyEventInfo(ev);
        else editCalEvent(ev, dateStr);
      },
    }, el('span', { class: 'cal-ev-label' }, ev.title || '(untitled)'));
    band.style.setProperty('--alllane', String(i));
    band.style.background = Calendar.colorVar(ev.color);
    lanes.appendChild(band);
  });

  if (events.length === 0 && !expanded) lanes.classList.add('empty');
  // Position bars with the default scale up front; the list-level reflowList()
  // refines them to the shared scale on the next frame.
  lanes._scale = defaultScale();
  reflowTimeline(lanes);
  return lanes;
}

// Convert a clientX to minutes-since-midnight using a lanes strip's scale.
function lanesPointerToMin(lanes, clientX) {
  const rect = lanes.getBoundingClientRect();
  const pct = rect.width ? ((clientX - rect.left) / rect.width) * 100 : 0;
  return pctToMin(pct, lanes._scale || defaultScale());
}

const CAL_DAY_MAX = 24 * 60;

// Drag a calendar event on the expanded lanes: 'move' shifts the whole event,
// 'start'/'end' resize one edge. Mirrors the timecard handle-drag (live reflow,
// snap to 15 min, persist on release). A move drag that never crosses the slop
// threshold is treated as a tap and opens the editor instead.
function attachEventDrag(lanes, target, bar, ev, dateStr, which, tooltip, laneIndex, startH, endH) {
  let dragging = false, moved = false;
  let downX = 0, grabMin = 0, s0 = 0, e0 = 0, sMin = 0, eMin = 0;

  const apply = () => {
    bar.dataset.leftMin = String(sMin);
    bar.dataset.widthMin = String(eMin - sMin);
    if (startH) startH.dataset.leftMin = String(sMin);
    if (endH) endH.dataset.leftMin = String(eMin);
    reflowList(lanes.closest('.day-list'), /*allowContract*/ false);
    const tipMin = which === 'start' ? sMin : (which === 'end' ? eMin : sMin);
    tooltip.style.left = Math.max(8, Math.min(92, minToPct(tipMin, lanes._scale))) + '%';
    tooltip.style.setProperty('--lane', String(laneIndex));
    tooltip.textContent = which === 'move'
      ? `${T.formatMinutes(sMin, state.use24h)}–${T.formatMinutes(eMin, state.use24h)}`
      : T.formatMinutes(tipMin, state.use24h);
    tooltip.classList.add('visible');
  };

  const onMove = (mv) => {
    if (!dragging) return;
    mv.preventDefault();
    if (Math.abs(mv.clientX - downX) > 4) moved = true;
    let m = Math.round((lanesPointerToMin(lanes, mv.clientX) - grabMin) / SNAP_MIN) * SNAP_MIN;
    if (which === 'move') {
      const dur = e0 - s0;
      let ns = Math.max(0, Math.min(CAL_DAY_MAX - dur, s0 + m));
      sMin = ns; eMin = ns + dur;
    } else if (which === 'start') {
      sMin = Math.max(0, Math.min(e0 - SNAP_MIN, s0 + m));
      eMin = e0;
    } else {
      eMin = Math.min(CAL_DAY_MAX, Math.max(s0 + SNAP_MIN, e0 + m));
      sMin = s0;
    }
    apply();
  };

  const onUp = async (up) => {
    if (!dragging) return;
    dragging = false;
    target.classList.remove('dragging');
    tooltip.classList.remove('visible');
    try { target.releasePointerCapture(up.pointerId); } catch {}
    if (!moved) {
      // A tap (no real drag) opens the editor.
      if (which === 'move') editCalEvent(ev, dateStr);
      return;
    }
    ev.startMin = sMin;
    ev.endMin = eMin;
    try {
      await DB.upsertEvent(ev);
      renderPeriodView();
    } catch (err) {
      console.error(err);
      showToast('Save failed: ' + err.message);
    }
  };

  target.addEventListener('pointerdown', (dn) => {
    dn.preventDefault();
    dn.stopPropagation();
    dragging = true; moved = false;
    downX = dn.clientX;
    s0 = sMin = Math.max(0, ev.startMin | 0);
    e0 = eMin = Math.max(s0 + SNAP_MIN, ev.endMin | 0);
    grabMin = lanesPointerToMin(lanes, dn.clientX);
    target.classList.add('dragging');
    try { target.setPointerCapture(dn.pointerId); } catch {}
  });
  target.addEventListener('pointermove', onMove);
  target.addEventListener('pointerup', onUp);
  target.addEventListener('pointercancel', onUp);
}

// Quick-add: drag across empty lane space to sketch a new event's time span,
// then open the editor pre-filled. A negligible drag is ignored.
function attachQuickAddDrag(lanes, surface, dateStr) {
  let dragging = false, downMin = 0, curMin = 0;
  let ghost = null;

  const ensureGhost = () => {
    if (ghost) return;
    ghost = el('div', { class: 'cal-ev me ghost' });
    ghost.style.setProperty('--lane', '0');
    lanes.appendChild(ghost);
  };
  const draw = () => {
    ensureGhost();
    const a = Math.min(downMin, curMin), b = Math.max(downMin, curMin);
    ghost.dataset.leftMin = String(a);
    ghost.dataset.widthMin = String(Math.max(SNAP_MIN, b - a));
    lanes._scale = lanes._scale || defaultScale();
    reflowTimeline(lanes);
  };

  const onMove = (mv) => {
    if (!dragging) return;
    mv.preventDefault();
    curMin = Math.round(lanesPointerToMin(lanes, mv.clientX) / SNAP_MIN) * SNAP_MIN;
    draw();
  };
  const onUp = (up) => {
    if (!dragging) return;
    dragging = false;
    try { surface.releasePointerCapture(up.pointerId); } catch {}
    if (ghost) { ghost.remove(); ghost = null; }
    const a = Math.min(downMin, curMin), b = Math.max(downMin, curMin);
    if (b - a >= SNAP_MIN) {
      openEventModal(dateStr, { date: dateStr, startMin: a, endMin: b, color: DEFAULT_EVENT_COLOR });
    }
  };

  surface.addEventListener('pointerdown', (dn) => {
    dn.preventDefault();
    dn.stopPropagation();
    dragging = true;
    downMin = curMin = Math.round(lanesPointerToMin(lanes, dn.clientX) / SNAP_MIN) * SNAP_MIN;
    try { surface.setPointerCapture(dn.pointerId); } catch {}
  });
  surface.addEventListener('pointermove', onMove);
  surface.addEventListener('pointerup', onUp);
  surface.addEventListener('pointercancel', onUp);
}

function buildDayCard(d, totals, todayStr, dayEntries, periodMode) {
  if (periodMode == null) periodMode = otModeForDate(d);
  const dayWorked = totals.byDate[d] || 0;
  const dayLeave = totals.leaveMap[d] || 0;
  const overtime = Math.min(dayWorked, (totals.otByDate && totals.otByDate[d]) || 0);
  const total = dayWorked + dayLeave;
  const date = T.parseLocalDate(d);
  const dow = date.getDay();
  const isToday = d === todayStr;
  const isWeekend = dow === 0 || dow === 6;

  const isValidation = state.validationDay != null
    && Number(state.validationDay) === viewedPeriodDayIndex(d);
  const holiday = holidayInfoFor(d);

  const calMode = state.calendarMode;
  const isExpanded = calMode && state.expandedDay === d;

  const card = el('div', {
    class: 'day-card'
      + (isToday ? ' today' : '')
      + (isWeekend ? ' weekend' : '')
      + (isValidation ? ' validation' : '')
      + (holiday ? ' holiday' : '')
      + (calMode ? ' cal' : '')
      + (isExpanded ? ' expanded' : ''),
  });

  // In calendar mode, tapping the day toggles expand-in-place (one day at a
  // time); a dedicated Edit button opens the full-screen editor. In timecard
  // mode the day-main / totals tap opens the editor exactly as before.
  const onDayTap = calMode ? () => toggleDayExpand(d) : () => openDayEditor(d);

  // Leave stepper: − and + so the user can remove leave too. Steps a whole hour,
  // or 15 minutes when the granular setting is on. Disable − at 0.
  const leaveStepMin = state.leaveGranularMinutes ? 15 : 60;
  const dayLeaveMin = Math.round((dayLeave || 0) * 60);
  const leaveDec = el('button', {
    class: 'leave-btn',
    title: 'Remove leave',
    onclick: async (ev) => {
      ev.stopPropagation();
      if (dayLeaveMin <= 0) return;
      await DB.setLeaveMinutes(d, dayLeaveMin - leaveStepMin);
      vibrate(8);
      renderPeriodView();
    },
  }, '−');
  if (dayLeaveMin <= 0) leaveDec.disabled = true;

  const leaveInc = el('button', {
    class: 'leave-btn',
    title: 'Add leave',
    onclick: async (ev) => {
      ev.stopPropagation();
      await DB.addLeaveMinutes(d, leaveStepMin);
      vibrate(8);
      renderPeriodView();
    },
  }, '+');

  const header = el('div', { class: 'day-header' },
    el('div', { class: 'day-main', onclick: onDayTap },
      el('div', { class: 'day-name' },
        date.toLocaleDateString(undefined, { weekday: 'short' }) + (isToday ? ' · Today' : '')),
      el('div', { class: 'day-date' }, date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })),
      holiday
        ? el('div', { class: 'day-holiday-tag', title: holiday.name },
            (holiday.doubleTime ? '★ 2× ' : '★ ') + holiday.name)
        : null,
    ),
    el('div', { class: 'day-totals', onclick: onDayTap },
      el('span', { class: 'day-hours' }, T.formatHours(total)),
      el('span', { class: 'unit' }, ' hr'),
      overtime > 0
        ? el('span', { class: 'day-ot' }, ` +${T.formatHours(overtime)}`)
        : null,
    ),
    el('div', { class: 'leave-mini', title: 'Leave hours' },
      leaveDec,
      el('span', { class: 'leave-mini-label' },
        `Leave ${T.leaveLabelText(dayLeaveMin, state.leaveGranularMinutes)}`),
      leaveInc,
    ),
  );
  card.appendChild(header);
  card.appendChild(buildDayEditorRow(d, dayEntries, dayLeave, overtime));

  // Expanded-state action bar: quick-add an event + jump to the full editor.
  if (calMode) {
    card.appendChild(el('div', { class: 'cal-actions' },
      el('button', {
        class: 'cal-action-btn',
        onclick: (ev) => { ev.stopPropagation(); openEventModal(d, null); },
      }, '+ Event'),
      el('button', {
        class: 'cal-action-btn',
        onclick: (ev) => { ev.stopPropagation(); openDayEditor(d); },
      }, 'Edit day ›'),
    ));
  }
  return card;
}

// Position 0..13 of a YYYY-MM-DD within its pay period (anchored to Sunday).
function viewedPeriodDayIndex(dateStr) {
  if (!state.anchor) return -1;
  const period = T.payPeriodFor(T.parseLocalDate(dateStr), state.anchor);
  return period.dayIndex;
}

// Inline editor row under each day card.
// Renders an SVG timeline strip for every day with entries (any number).
// Drag handles on each end of each entry snap to 15-min increments. Empty days
// show an "+ Add work hours" button. Leave-only / incomplete-only days fall
// back to a text summary + tap-to-open the full day editor.
function buildDayEditorRow(d, dayEntries, dayLeave, dayOt = 0) {
  const drawable = dayEntries.filter(e => !e.incomplete);

  // Calendar mode always renders the time axis (the work bar = "my time"), and
  // overlays the event lanes ON it: "me" events ride the bar, person lanes hug
  // it from just above. The lanes are an absolute overlay inside the same wrap
  // so they share the timeline's horizontal scale AND vertical coordinate space.
  if (state.calendarMode) {
    const wrap = el('div', { class: 'day-editor timeline-wrap' });
    wrap.appendChild(buildDayTimeline(d, drawable, dayLeave, dayOt));
    const dayEvents = (state._eventsByDate && state._eventsByDate[d]) || [];
    wrap.appendChild(buildCalLanes(d, dayEvents));
    return wrap;
  }

  if (drawable.length === 0 && dayLeave === 0) {
    return el('div', { class: 'day-editor empty' },
      el('button', {
        class: 'inline-add-btn',
        onclick: async (ev) => {
          ev.stopPropagation();
          await createDefaultEntryForDate(d);
          renderPeriodView();
        },
      }, '+ Add work hours'),
    );
  }

  if (drawable.length > 0) {
    const wrap = el('div', { class: 'day-editor timeline-wrap' });
    wrap.appendChild(buildDayTimeline(d, drawable, dayLeave, dayOt));
    // Lunch editing moved off the period view to keep all five weekday cards
    // visible on one screen — adjust lunch in the day editor / entry modal.
    return wrap;
  }

  // Leave-only or incomplete-only: summary + tap-to-open
  return el('div', {
    class: 'day-editor summary',
    onclick: () => openDayEditor(d),
  }, summarizeDay(dayEntries, dayLeave));
}

function summarizeDay(dayEntries, dayLeave) {
  const parts = dayEntries.map(e => {
    if (e.incomplete) return 'incomplete';
    if (!e.endTime) return 'in progress';
    return `${T.formatTime(e.startTime, state.use24h)}–${T.formatTime(e.endTime, state.use24h)}`;
  });
  if (dayLeave > 0) parts.push(`${dayLeave} hr leave`);
  return parts.length ? parts.join(' · ') : '—';
}

async function createDefaultEntryForDate(dateStr) {
  // Look up the user's default for THIS day-of-period (0..13).
  const period = T.payPeriodFor(T.parseLocalDate(dateStr), state.anchor);
  const idx = period.dayIndex;
  const slot = state.defaultSchedule[idx] || { startMin: 9 * 60, endMin: 17 * 60 };
  const startTime = T.buildDateTime(dateStr, Math.floor(slot.startMin / 60), slot.startMin % 60);
  const endTime = T.buildDateTime(dateStr, Math.floor(slot.endMin / 60), slot.endMin % 60);
  await DB.upsertEntry({
    date: dateStr,
    startTime: startTime.toISOString(),
    endTime: endTime.toISOString(),
    incomplete: false,
  });
}

// Inline lunch stepper. Bumps lunchMinutes in 15-min steps (0..180) and saves
// immediately. Only shown for single-closed-entry days.
function buildLunchStepper(entry) {
  const cur = entry.lunchMinutes != null ? entry.lunchMinutes : (entry.lunchDeducted ? 30 : 0);
  const adjust = async (delta) => {
    const next = Math.max(0, Math.min(180, cur + delta));
    if (next === cur) return;
    entry.lunchMinutes = next;
    try {
      await DB.upsertEntry(entry);
      renderPeriodView();
    } catch (err) {
      console.error(err);
      showToast('Save failed: ' + err.message);
    }
  };
  return el('div', { class: 'lunch-stepper' },
    el('span', { class: 'lunch-label' }, 'Lunch'),
    el('button', {
      class: 'lunch-btn',
      onclick: (ev) => { ev.stopPropagation(); adjust(-15); },
    }, '−'),
    el('span', { class: 'lunch-value' }, `${cur} min`),
    el('button', {
      class: 'lunch-btn',
      onclick: (ev) => { ev.stopPropagation(); adjust(+15); },
    }, '+'),
  );
}

// --- Timeline component ----------------------------------------------------
// HTML/CSS strip with absolutely-positioned children. Each child tags itself
// with dataset.leftMin (and optionally widthMin) in minutes-since-midnight;
// reflowTimeline walks the children and converts those to %-positions based
// on the timeline's *current* scale. Drag handlers can extend the scale on
// the fly and call reflow without re-rendering, which keeps pointer capture
// alive on the dragged handle.

const ABSOLUTE_START_MIN = 4 * 60 + 30;    // 4:30 AM (hard left bound)
const ABSOLUTE_END_MIN = 24 * 60;          // midnight (hard right bound)
const DEFAULT_SCALE_START = 5 * 60 + 45;   // 5:45 AM — padded so the 6 AM
const DEFAULT_SCALE_END = 18 * 60 + 15;    // edge tick label isn't clipped
                                           // (6 PM tick stays inside the strip)
const SCALE_PAD_MIN = 30;                  // padding when auto-extending
const SNAP_MIN = 15;
// Non-linear scale: COMPRESS the core workday (9 AM – 2:30 PM) since those
// hours are routine and rarely tweaked, and EXPAND the edges where the user
// actually adjusts start/end times. CORE_WEIGHT is the fraction of strip
// width allocated to the core zone (less than 0.5 makes the core compressed).
const CORE_START_MIN = 9 * 60;             // 9 AM
const CORE_END_MIN = 14 * 60 + 30;         // 2:30 PM
const CORE_WEIGHT = 0.30;                  // core gets 30% of width (compressed)

// Calendar mode uses a plain LINEAR minute scale (evening events read
// correctly); timecard mode keeps the non-linear core-compression below.
const CAL_SCALE_START = 7 * 60 + 30;       // 7:30 AM
const CAL_SCALE_END = 22 * 60;             // 10:00 PM

// The default (unexpanded) scale window for a fresh list of timelines.
function defaultScale() {
  return state.calendarMode
    ? { startMin: CAL_SCALE_START, endMin: CAL_SCALE_END }
    : { startMin: DEFAULT_SCALE_START, endMin: DEFAULT_SCALE_END };
}

function minToPct(m, scale) {
  const { startMin, endMin } = scale;
  if (endMin <= startMin) return 0;
  if (m <= startMin) return 0;
  if (m >= endMin) return 100;
  if (state.calendarMode) return (m - startMin) / (endMin - startMin) * 100;
  const cs = Math.max(CORE_START_MIN, startMin);
  const ce = Math.min(CORE_END_MIN, endMin);
  if (ce <= cs) {
    return (m - startMin) / (endMin - startMin) * 100;
  }
  const preMin = cs - startMin;
  const coreMin = ce - cs;
  const postMin = endMin - ce;
  const nonCore = preMin + postMin;
  const coreW = CORE_WEIGHT * 100;
  const edgesW = 100 - coreW;
  const preW = nonCore > 0 ? (preMin / nonCore) * edgesW : 0;
  const postW = nonCore > 0 ? (postMin / nonCore) * edgesW : 0;
  if (m < cs) return (m - startMin) / preMin * preW;
  if (m < ce) return preW + (m - cs) / coreMin * coreW;
  return preW + coreW + (m - ce) / postMin * postW;
}
function pctToMin(pct, scale) {
  const { startMin, endMin } = scale;
  if (endMin <= startMin) return startMin;
  if (pct <= 0) return startMin;
  if (pct >= 100) return endMin;
  if (state.calendarMode) return startMin + (pct / 100) * (endMin - startMin);
  const cs = Math.max(CORE_START_MIN, startMin);
  const ce = Math.min(CORE_END_MIN, endMin);
  if (ce <= cs) {
    return startMin + (pct / 100) * (endMin - startMin);
  }
  const preMin = cs - startMin;
  const coreMin = ce - cs;
  const postMin = endMin - ce;
  const nonCore = preMin + postMin;
  const coreW = CORE_WEIGHT * 100;
  const edgesW = 100 - coreW;
  const preW = nonCore > 0 ? (preMin / nonCore) * edgesW : 0;
  const postW = nonCore > 0 ? (postMin / nonCore) * edgesW : 0;
  if (pct < preW) return startMin + (pct / preW) * preMin;
  if (pct < preW + coreW) return cs + ((pct - preW) / coreW) * coreMin;
  return ce + ((pct - preW - coreW) / postW) * postMin;
}

function minutesOfDate(iso) {
  const d = new Date(iso);
  return d.getHours() * 60 + d.getMinutes();
}
// Minutes-since-midnight of an entry's end, with next-day rollover treated as
// 24:00 (so a slider that ends "next day at 00:00" displays as ending at the
// far right edge of the strip, not at 4:30 AM after a clamp).
function endMinutesForEntry(entry) {
  if (!entry.endTime) return null;
  const endDt = new Date(entry.endTime);
  const startDate = entry.date ? T.parseLocalDate(entry.date) : null;
  if (startDate) {
    const endLocal = T.formatLocalDate(endDt);
    const startLocal = T.formatLocalDate(startDate);
    if (endLocal !== startLocal) return 24 * 60;
  }
  return endDt.getHours() * 60 + endDt.getMinutes();
}
function clampToAbsolute(m) {
  return Math.max(ABSOLUTE_START_MIN, Math.min(ABSOLUTE_END_MIN, m));
}

function autoFitScale(entries) {
  const ds = defaultScale();
  let startMin = ds.startMin;
  let endMin = ds.endMin;
  for (const e of entries) {
    const sm = clampToAbsolute(minutesOfDate(e.startTime));
    const rawEnd = e.endTime ? endMinutesForEntry(e) : minutesOfDate(new Date());
    const em = clampToAbsolute(rawEnd);
    startMin = Math.min(startMin, Math.max(ABSOLUTE_START_MIN, sm - SCALE_PAD_MIN));
    endMin = Math.max(endMin, Math.min(ABSOLUTE_END_MIN, em + SCALE_PAD_MIN));
  }
  return { startMin, endMin };
}

// Walk every child of wrap and recompute its left/width from its dataset
// position in minutes, given the current wrap._scale. Uses the non-linear
// minToPct mapping so the core hours stretch visually. Time-pill labels are
// clamped into the strip so they don't fall off the screen at the edges.
function reflowTimeline(wrap) {
  const scale = wrap._scale;
  for (const child of wrap.children) {
    const lm = parseFloat(child.dataset.leftMin);
    if (!isFinite(lm)) continue;
    const wm = parseFloat(child.dataset.widthMin);
    if (isFinite(wm)) {
      const leftPct = minToPct(lm, scale);
      const rightPct = minToPct(lm + wm, scale);
      child.style.left = leftPct + '%';
      child.style.width = Math.max(0, rightPct - leftPct) + '%';
      continue;
    }
    let pos = minToPct(lm, scale);
    if (child.classList.contains('tl-time-label')) {
      // The pill is ~50px wide; on a ~330px strip that's ~15% of width.
      // Clamp so the pill stays fully on-screen at the extremes.
      pos = Math.max(8, Math.min(92, pos));
    }
    child.style.left = pos + '%';
  }
}

// Recompute the shared scale for every timeline in a list-container by scanning
// all bars currently in the DOM, then apply that scale to each wrap and reflow.
// `allowContract`: during a drag we pass false so the scale only ever expands
// (otherwise the page would shift around under the user's finger). On
// drag-release we pass true so the scale settles to the tightest fit.
function reflowList(list, allowContract = true) {
  if (!list) return;
  const ds = defaultScale();
  let startMin = ds.startMin;
  let endMin = ds.endMin;
  const wraps = list.querySelectorAll('.day-timeline');
  // Calendar-mode event lanes share the timeline's horizontal scale, so their
  // extents must widen the window too (e.g. a 9 PM event pulls the right edge).
  const laneWraps = list.querySelectorAll('.cal-lanes');
  const fit = (child) => {
    const lm = parseFloat(child.dataset.leftMin);
    const wm = parseFloat(child.dataset.widthMin);
    if (!isFinite(lm) || !isFinite(wm)) return;
    startMin = Math.min(startMin, Math.max(ABSOLUTE_START_MIN, lm - SCALE_PAD_MIN));
    endMin = Math.max(endMin, Math.min(ABSOLUTE_END_MIN, lm + wm + SCALE_PAD_MIN));
  };
  for (const w of wraps) {
    for (const child of w.children) {
      // Leave bars extend the work bar to the right; include them so a day's
      // recurring/entered leave is never clipped off the right edge.
      if (child.classList.contains('tl-bar') || child.classList.contains('tl-leave')) fit(child);
    }
  }
  for (const w of laneWraps) {
    for (const child of w.children) {
      if (child.classList.contains('cal-ev') && !child.classList.contains('allday')) fit(child);
    }
  }
  // During an active drag, never shrink — keep the last applied scale or wider.
  if (!allowContract && list._scale) {
    startMin = Math.min(startMin, list._scale.startMin);
    endMin = Math.max(endMin, list._scale.endMin);
  }
  const scale = { startMin, endMin };
  list._scale = scale;
  for (const w of wraps) {
    w._scale = scale;
    reflowTimeline(w);
  }
  for (const w of laneWraps) {
    w._scale = scale;
    reflowTimeline(w);
  }
}

// Given a day's entries (sorted ascending) and its total OT hours, return the
// clock-minute spans covering the rightmost `dayOt` worked-minutes — the part
// of the day that reads as overtime. Walks from the last clock-out backward,
// splitting across multiple entries if needed. Uses clock span (a close visual
// proxy; lunch within the OT tail is a negligible cosmetic difference).
function otSegments(sorted, dayOt) {
  let remaining = Math.round((dayOt || 0) * 60);
  if (remaining <= 0) return [];
  const segs = [];
  for (let i = sorted.length - 1; i >= 0 && remaining > 0; i--) {
    const e = sorted[i];
    const startMin = clampToAbsolute(minutesOfDate(e.startTime));
    const rawEnd = e.endTime ? endMinutesForEntry(e) : minutesOfDate(new Date());
    const endMin = clampToAbsolute(rawEnd);
    const span = endMin - startMin;
    if (span <= 0) continue;
    const take = Math.min(span, remaining);
    segs.push({ startMin: endMin - take, widthMin: take });
    remaining -= take;
  }
  return segs;
}

function buildDayTimeline(dateStr, entries, dayLeave = 0, dayOt = 0) {
  const wrap = el('div', { class: 'day-timeline' });
  wrap._scale = autoFitScale(entries);

  // Leave segment: a colored bar extending past the last work entry, length
  // = leave hours. So 8:00–3:30 worked + 1h leave reads as a leave-colored
  // strip from 3:30 to 4:30. Purely visual — no drag handles. Computed up
  // front so the scale can be widened to keep it on-screen.
  let leaveSeg = null;
  if (dayLeave > 0 && entries.length > 0) {
    let lastEnd = ABSOLUTE_START_MIN;
    for (const e of entries) {
      const em = clampToAbsolute(e.endTime ? endMinutesForEntry(e) : minutesOfDate(new Date()));
      if (em > lastEnd) lastEnd = em;
    }
    const leaveStart = lastEnd;
    const leaveEnd = Math.min(ABSOLUTE_END_MIN, leaveStart + dayLeave * 60);
    if (leaveEnd > leaveStart) {
      leaveSeg = { startMin: leaveStart, widthMin: leaveEnd - leaveStart };
      wrap._scale.endMin = Math.min(ABSOLUTE_END_MIN,
        Math.max(wrap._scale.endMin, leaveEnd + SCALE_PAD_MIN));
    }
  }

  // Render ALL hour ticks across the absolute range — out-of-scale ones get
  // clipped by overflow:hidden until the scale extends to cover them.
  const firstWholeHour = Math.ceil(ABSOLUTE_START_MIN / 60) * 60;
  for (let m = firstWholeHour; m <= ABSOLUTE_END_MIN; m += 60) {
    const isMajor = (m % 180 === 0);
    const tick = el('div', { class: 'tl-tick' + (isMajor ? ' major' : '') });
    tick.dataset.leftMin = String(m);
    wrap.appendChild(tick);
    if (isMajor) {
      const h = Math.floor(m / 60) % 24;
      const text = state.use24h
        ? String(h).padStart(2, '0')
        : (h === 0 ? '12' : h === 12 ? '12' : h < 12 ? String(h) : String(h - 12));
      const label = el('div', { class: 'tl-label' }, text);
      label.dataset.leftMin = String(m);
      wrap.appendChild(label);
    }
  }

  if (dateStr === T.formatLocalDate(new Date())) {
    const nowMin = clampToAbsolute(minutesOfDate(new Date()));
    const nowLine = el('div', { class: 'tl-now' });
    nowLine.dataset.leftMin = String(nowMin);
    wrap.appendChild(nowLine);
  }

  // Single tooltip per timeline; positioned/shown by drag handlers.
  const tooltip = el('div', { class: 'tl-tooltip' });
  wrap.appendChild(tooltip);

  const sorted = entries.slice().sort((a, b) =>
    new Date(a.startTime) - new Date(b.startTime));
  for (const entry of sorted) {
    drawEntryOnTimeline(wrap, dateStr, entry, tooltip);
  }

  // Overtime segment(s): paint the rightmost `dayOt` worked-minutes of the work
  // bar(s) in the intense OT color, inline on the same line as regular work.
  // OT is a per-day computed amount (the day's whole OT, from periodTotals) —
  // not a per-entry flag — so we walk the day's worked time from the last
  // clock-out backward and recolor that tail. Purely visual overlay
  // (pointer-events:none) so it never blocks bar clicks or drag handles.
  for (const seg of otSegments(sorted, dayOt)) {
    const otBar = el('div', { class: 'tl-bar ot tl-ot-seg' });
    otBar.dataset.leftMin = String(seg.startMin);
    otBar.dataset.widthMin = String(seg.widthMin);
    wrap.appendChild(otBar);
  }

  // Leave segment — drawn last so it sits to the right of the work bar.
  if (leaveSeg) {
    const leaveBar = el('div', {
      class: 'tl-leave',
      title: `${T.formatHours(dayLeave)} hr leave`,
      onclick: (ev) => { ev.stopPropagation(); openDayEditor(dateStr); },
    });
    leaveBar.dataset.leftMin = String(leaveSeg.startMin);
    leaveBar.dataset.widthMin = String(leaveSeg.widthMin);
    wrap.appendChild(leaveBar);
  }

  reflowTimeline(wrap);
  return wrap;
}

function drawEntryOnTimeline(wrap, dateStr, entry, tooltip) {
  const startMin = clampToAbsolute(minutesOfDate(entry.startTime));
  const rawEnd = entry.endTime ? endMinutesForEntry(entry) : minutesOfDate(new Date());
  const endMin = clampToAbsolute(rawEnd);
  const inProgress = !entry.endTime;

  const bar = el('div', {
    // OT coloring is now a per-day computed overlay (see otSegments) rather than
    // a per-entry flag, so the base entry bar always renders as regular work.
    class: 'tl-bar' + (inProgress ? ' in-progress' : ''),
    onclick: (ev) => {
      ev.stopPropagation();
      openDayEditor(dateStr);
    },
  });
  bar.dataset.leftMin = String(startMin);
  bar.dataset.widthMin = String(endMin - startMin);
  wrap.appendChild(bar);

  const lm = entry.lunchMinutes != null ? entry.lunchMinutes : (entry.lunchDeducted ? 30 : 0);
  let lunchEl = null;
  if (lm > 0 && endMin > startMin) {
    const lunchStart = (startMin + endMin) / 2 - lm / 2;
    lunchEl = el('div', {
      class: 'tl-lunch',
      title: `${lm}-min lunch`,
      onclick: (ev) => { ev.stopPropagation(); openDayEditor(dateStr); },
    });
    lunchEl.dataset.leftMin = String(lunchStart);
    lunchEl.dataset.widthMin = String(lm);
    wrap.appendChild(lunchEl);
  }

  const refs = { bar, lunchEl, tooltip, entry, dateStr, lunchMinutes: lm };

  // Persistent time labels at each bar edge — always visible (not just during
  // drag) so the user can read the start/end of the slider at a glance.
  const startLabel = el('div', { class: 'tl-time-label tl-time-start' },
    T.formatMinutes(startMin, state.use24h));
  startLabel.dataset.leftMin = String(startMin);
  wrap.appendChild(startLabel);
  refs.startLabel = startLabel;

  if (!inProgress) {
    const endLabel = el('div', { class: 'tl-time-label tl-time-end' },
      T.formatMinutes(endMin, state.use24h));
    endLabel.dataset.leftMin = String(endMin);
    wrap.appendChild(endLabel);
    refs.endLabel = endLabel;
  }

  if (!inProgress) addHandle(wrap, 'start', startMin, refs);
  addHandle(wrap, 'end', endMin, refs);
}

function addHandle(wrap, which, atMin, refs) {
  const knob = el('div', { class: 'tl-handle tl-handle-' + which });
  knob.dataset.leftMin = String(atMin);
  const hit = el('div', { class: 'tl-hit' });
  hit.dataset.leftMin = String(atMin);
  attachHandleDrag(wrap, hit, knob, which, refs);
  wrap.appendChild(knob);
  wrap.appendChild(hit);
}

// Auto-expand tuning: while a handle is held within EDGE_ZONE_PX of the strip
// edge, the scale keeps growing on its own (one SNAP_MIN tick every
// EDGE_STEP_MS) so the user can reach off-scale times by *holding* at the edge
// instead of having to jiggle back and forth to fire fresh pointermove events.
const EDGE_ZONE_PX = 30;
const EDGE_STEP_MS = 90;

function attachHandleDrag(wrap, hit, knob, which, refs) {
  let dragging = false;
  let oppMin = 0;
  let curMin = 0;
  // Offset between pointer and the handle's centerline at drag-start, in
  // minutes. Lets the user grab the handle without it jumping to under the
  // finger; pointer drift translates 1:1 into time movement.
  let grabOffsetMin = 0;
  // Auto-expand loop state: the last pointer X (so the rAF loop knows where the
  // finger is without a move event) and the running rAF handle + tick clock.
  let lastClientX = 0;
  let autoRaf = null;
  let lastAutoTs = 0;

  const pointerToMin = (clientX) => {
    const rect = wrap.getBoundingClientRect();
    const pct = ((clientX - rect.left) / rect.width) * 100;
    return pctToMin(pct, wrap._scale);
  };

  // Clamp a candidate minute to the legal range for this handle (snap + bounds
  // + don't cross the opposite handle).
  const constrain = (m) => {
    m = Math.round(m / SNAP_MIN) * SNAP_MIN;
    m = clampToAbsolute(m);
    if (which === 'start') {
      return Math.min(oppMin - SNAP_MIN, m);
    }
    // Cap end one snap-tick short of midnight so we never write a next-day
    // endTime via the slider (which previously broke the bar display).
    return Math.max(oppMin + SNAP_MIN, Math.min(ABSOLUTE_END_MIN - SNAP_MIN, m));
  };

  // Apply a (already-constrained) minute value to the bar/handle/labels and
  // re-fit the shared scale. Shared by pointer-driven moves and the auto loop.
  const applyMin = (m) => {
    curMin = m;
    knob.dataset.leftMin = String(m);
    hit.dataset.leftMin = String(m);
    const sMin = which === 'start' ? m : oppMin;
    const eMin = which === 'end' ? m : oppMin;
    refs.bar.dataset.leftMin = String(sMin);
    refs.bar.dataset.widthMin = String(eMin - sMin);
    if (refs.lunchEl) {
      const lunchStart = (sMin + eMin) / 2 - refs.lunchMinutes / 2;
      refs.lunchEl.dataset.leftMin = String(lunchStart);
    }
    // Update the side-specific time label.
    const labelEl = which === 'start' ? refs.startLabel : refs.endLabel;
    if (labelEl) {
      labelEl.dataset.leftMin = String(m);
      labelEl.textContent = T.formatMinutes(m, state.use24h);
    }

    // During the drag we only ever expand; settling happens on release.
    reflowList(wrap.closest('.day-list'), /*allowContract*/ false);

    refs.tooltip.style.left = Math.max(8, Math.min(92, minToPct(m, wrap._scale))) + '%';
    refs.tooltip.textContent = T.formatMinutes(m, state.use24h);
    refs.tooltip.classList.add('visible');
  };

  // +1 (push the right/end edge later), -1 (push the left/start edge earlier),
  // or 0 when the finger isn't parked in an edge zone.
  const edgeDir = (clientX) => {
    const rect = wrap.getBoundingClientRect();
    if (which === 'end' && clientX > rect.right - EDGE_ZONE_PX) return 1;
    if (which === 'start' && clientX < rect.left + EDGE_ZONE_PX) return -1;
    return 0;
  };

  const autoTick = (ts) => {
    if (!dragging) { autoRaf = null; return; }
    const dir = edgeDir(lastClientX);
    if (dir === 0) { autoRaf = null; return; }
    if (!lastAutoTs || ts - lastAutoTs >= EDGE_STEP_MS) {
      lastAutoTs = ts;
      const next = constrain(curMin + dir * SNAP_MIN);
      if (next !== curMin) applyMin(next);
    }
    autoRaf = requestAnimationFrame(autoTick);
  };

  const maybeStartAuto = () => {
    if (autoRaf == null && edgeDir(lastClientX) !== 0) {
      lastAutoTs = 0;
      autoRaf = requestAnimationFrame(autoTick);
    }
  };

  const stopAuto = () => {
    if (autoRaf != null) cancelAnimationFrame(autoRaf);
    autoRaf = null;
  };

  const onMove = (ev) => {
    if (!dragging) return;
    ev.preventDefault();
    lastClientX = ev.clientX;
    applyMin(constrain(pointerToMin(ev.clientX) - grabOffsetMin));
    // If the finger has reached an edge, hand off to the auto-expand loop so
    // the scale keeps growing even while the pointer is held still.
    maybeStartAuto();
  };

  const onUp = async (ev) => {
    if (!dragging) return;
    dragging = false;
    stopAuto();
    knob.classList.remove('dragging');
    refs.tooltip.classList.remove('visible');
    try { hit.releasePointerCapture(ev.pointerId); } catch {}
    const iso = T.buildDateTime(refs.dateStr, Math.floor(curMin / 60), curMin % 60).toISOString();
    if (which === 'start') refs.entry.startTime = iso;
    else refs.entry.endTime = iso;
    try {
      await DB.upsertEntry(refs.entry);
      if (state.openEntry && state.openEntry.id === refs.entry.id) state.openEntry = null;
      renderPeriodView();
    } catch (err) {
      console.error(err);
      showToast('Save failed: ' + err.message);
    }
  };

  hit.addEventListener('pointerdown', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    dragging = true;
    lastClientX = ev.clientX;
    const handleMin = which === 'start'
      ? minutesOfDate(refs.entry.startTime)
      : (refs.entry.endTime ? minutesOfDate(refs.entry.endTime) : minutesOfDate(new Date()));
    oppMin = which === 'start'
      ? minutesOfDate(refs.entry.endTime || new Date())
      : minutesOfDate(refs.entry.startTime);
    grabOffsetMin = pointerToMin(ev.clientX) - handleMin;
    curMin = handleMin;
    knob.classList.add('dragging');
    try { hit.setPointerCapture(ev.pointerId); } catch {}
  });
  hit.addEventListener('pointermove', onMove);
  hit.addEventListener('pointerup', onUp);
  hit.addEventListener('pointercancel', onUp);
}

async function openDayEditor(yyyymmdd) {
  state.editingDate = yyyymmdd;
  setView('day');
  await renderDayView();
}

// Holiday controls in the day editor: badge + name when recorded, a
// "Holiday worked (double time)" toggle, and an add/remove button. Federal
// holiday days that aren't recorded yet offer a one-tap "Add" with the right
// name; any other day can still be marked a generic holiday.
function renderHolidaySection(d) {
  const section = $('holidaySection');
  const recorded = holidayInfoFor(d);
  const fedName = federalHolidayNameFor(d);
  section.hidden = false;

  const head = $('holidayHead');
  const nameEl = $('holidayName');
  const workedRow = $('holidayWorkedRow');
  const btn = $('holidayToggleBtn');

  if (recorded) {
    head.hidden = false;
    nameEl.textContent = recorded.name;
    section.classList.add('is-holiday');
    workedRow.hidden = false;
    $('holidayWorkedToggle').checked = !!recorded.doubleTime;
    btn.textContent = 'Remove holiday';
    btn.classList.add('danger');
    btn.classList.remove('secondary');
  } else {
    section.classList.remove('is-holiday');
    workedRow.hidden = true;
    btn.classList.add('secondary');
    btn.classList.remove('danger');
    if (fedName) {
      head.hidden = false;
      nameEl.textContent = fedName;
      btn.textContent = 'Add this holiday';
    } else {
      head.hidden = true;
      btn.textContent = 'Mark as holiday';
    }
  }
}

// A small OT/Credit pill for an entry row, by its resolved payKind. Forced/auto
// overtime → gold "OT"; credit/autoCredit → purple "Credit"; auto/regular → none
// (auto's OT, if any, is computed at the period level). Mirrors iOS payKindTag.
function entryPayKindTag(e) {
  // effectivePayKind collapses credit→OT when the feature is off, so no Credit
  // tag ever shows in that mode.
  const k = effectivePayKind(DB.entryPayKind(e));
  if (k === 'overtime') return el('span', { class: 'entry-ot-tag' }, 'OT');
  if (k === 'credit' || k === 'autoCredit') return el('span', { class: 'entry-credit-tag' }, 'Credit');
  return null;
}

async function renderDayView() {
  const d = state.editingDate;
  if (!d) return;
  $('dayTitle').textContent = T.formatDateShort(d);

  // Show the validation-deadline banner when this day's day-of-period
  // index matches the user's chosen validation day.
  const dayIdx = viewedPeriodDayIndex(d);
  $('validationBanner').hidden = !(state.validationDay != null
    && state.validationDay === dayIdx);

  renderHolidaySection(d);
  await renderEventSection(d);

  const dayMode = otModeForDate(d);
  const totals = state.openEntry && state.openEntry.date === d
    ? await todayTotalsLive(d, dayMode)
    : await dayTotals(d, dayMode);

  // Clock In/Out lives in the day editor and only applies to today (a
  // timestamp stamps the current time). Hidden on any other day.
  const isToday = d === T.formatLocalDate(new Date());
  const clockSection = $('clockSection');
  clockSection.hidden = !isToday;
  if (isToday) {
    const btn = $('clockBtn');
    const statusEl = $('clockStatus');
    if (state.openEntry) {
      btn.textContent = 'Clock Out';
      btn.classList.add('clocked-in');
      const start = T.formatTime(state.openEntry.startTime, state.use24h);
      const live = T.hoursForEntry(state.openEntry.startTime, T.roundToQuarter(new Date()));
      statusEl.textContent = `Clocked in at ${start} · ${T.formatHours(live.hours)} hrs`;
    } else {
      btn.textContent = 'Clock In';
      btn.classList.remove('clocked-in');
      statusEl.textContent = '';
    }
  }

  const summary = $('daySummary');
  summary.innerHTML = '';
  summary.appendChild(el('div', { class: 'stat' },
    el('div', { class: 'stat-label' }, 'Worked'),
    el('div', { class: 'stat-value' }, T.formatHours(totals.worked))));
  summary.appendChild(el('div', { class: 'stat' },
    el('div', { class: 'stat-label' }, 'Leave'),
    el('div', { class: 'stat-value' }, T.formatHours(totals.leave))));
  summary.appendChild(el('div', { class: 'stat' },
    el('div', { class: 'stat-label' }, 'Total'),
    el('div', { class: 'stat-value' }, T.formatHours(totals.total))));
  if (dayMode || totals.overtime > 0) {
    summary.appendChild(el('div', { class: 'stat' },
      el('div', { class: 'stat-label' }, 'OT'),
      el('div', { class: 'stat-value' }, T.formatHours(totals.overtime))));
  }

  const list = $('entryList');
  list.innerHTML = '';
  if (totals.entries.length === 0) {
    list.appendChild(el('div', { class: 'entry-card' },
      el('div', { class: 'entry-meta' }, 'No entries for this day.')));
  }
  for (const e of totals.entries) {
    let times, meta;
    if (e.incomplete) {
      times = el('span', { class: 'entry-incomplete' }, 'Incomplete');
      meta = `Started ${T.formatTime(e.startTime, state.use24h)} · tap to fix`;
    } else if (!e.endTime) {
      times = `${T.formatTime(e.startTime, state.use24h)} – (in progress)`;
      const now = T.roundToQuarter(new Date());
      meta = `${T.formatHours(T.hoursForEntry(e.startTime, now).hours)} hrs so far`;
    } else {
      const sameDay = T.formatLocalDate(e.startTime) === T.formatLocalDate(e.endTime);
      times = `${T.formatTime(e.startTime, state.use24h)} – ${T.formatTime(e.endTime, state.use24h)}${sameDay ? '' : ' (+1d)'}`;
      const h = T.hoursForEntry(e.startTime, e.endTime, e.lunchMinutes).hours;
      const lm = e.lunchMinutes != null ? e.lunchMinutes : (e.lunchDeducted ? 30 : 0);
      meta = `${T.formatHours(h)} hrs` + (lm > 0 ? ` (−${lm} min lunch)` : '');
    }
    list.appendChild(el('div', { class: 'entry-card' },
      el('div', {},
        el('div', { class: 'entry-times' }, times, entryPayKindTag(e)),
        el('div', { class: 'entry-meta' }, meta),
      ),
      el('div', { class: 'entry-actions' },
        el('button', { onclick: () => openEntryModal(e) }, 'Edit'),
        el('button', {
          class: 'danger',
          onclick: async () => {
            await DB.deleteEntry(e.id);
            if (state.openEntry && state.openEntry.id === e.id) {
              state.openEntry = null;
            }
            showToast('Entry deleted', async () => {
              await DB.upsertEntry(e);
              if (!e.endTime) state.openEntry = e;
              renderDayView();
            });
            renderDayView();
          },
        }, 'Delete'),
      ),
    ));
  }

  const leaveMin = Math.round((totals.leave || 0) * 60);
  $('leaveCount').textContent = T.leaveLabelText(leaveMin, state.leaveGranularMinutes);
  $('leaveUnit').textContent = state.leaveGranularMinutes ? '' : 'hrs';
  $('leaveGranularToggle').checked = state.leaveGranularMinutes;

  // Credit-hours spend stepper — only when the feature is on.
  const creditUsedSection = $('creditUsedSection');
  if (creditUsedSection) {
    creditUsedSection.hidden = !state.creditHoursEnabled;
    if (state.creditHoursEnabled) {
      $('creditUsedCount').textContent = T.formatHours(await DB.getCreditUsed(d));
    }
  }
}

// Build the theme-picker cards (Settings → Appearance). Each card previews its
// own palette via inline swatch hexes and marks the active one.
function renderThemePicker() {
  const wrap = $('themePicker');
  if (!wrap) return;
  wrap.innerHTML = '';
  const active = THEME_IDS.has(state.theme) ? state.theme : 'classic';
  for (const t of THEMES) {
    const card = el('button', {
      type: 'button',
      class: 'theme-option' + (t.id === active ? ' selected' : ''),
      'data-theme-id': t.id,
      'aria-pressed': String(t.id === active),
    });
    const head = el('div', { class: 'theme-head' });
    head.appendChild(el('span', { class: 'theme-name' }, t.name));
    head.appendChild(el('span', { class: 'theme-check' }, '✓'));
    card.appendChild(head);
    const sw = el('div', { class: 'theme-swatches' });
    for (const hex of t.swatches) sw.appendChild(el('i', { style: `background:${hex}` }));
    card.appendChild(sw);
    card.appendChild(el('div', { class: 'theme-mood' }, t.mood));
    wrap.appendChild(card);
  }
}

async function renderSettings() {
  if (state.anchor) $('anchorInput').value = state.anchor;
  renderThemePicker();
  $('otToggle').checked = state.otModeDefault;
  $('creditHoursToggle').checked = state.creditHoursEnabled;
  $('hourlyRateInput').value = state.hourlyRate > 0 ? String(state.hourlyRate) : '';
  $('use24hToggle').checked = state.use24h;
  $('autoHolidaysToggle').checked = state.autoHolidays;
  $('calendarModeToggle').checked = state.calendarMode;
  $('eventsIcsRow').hidden = !state.calendarMode;
  $('googleRow').hidden = !state.calendarMode;
  renderGoogleControls();
  if (isGoogleConnected()) {
    setGoogleStatus(state._googleSyncedAt ? 'Connected · last synced ' + T.formatTime(new Date(state._googleSyncedAt), state.use24h) : 'Connected');
    // Refresh the calendar list lazily so the Ritza picker is populated.
    if (!state._googleCalendars) loadGoogleCalendars().then(renderGoogleControls).catch(() => {});
  } else if (state.googleClientIdEmbedded || state.googleClientId) {
    setGoogleStatus('Tap “Sign in with Google” to connect your calendar.');
  } else {
    setGoogleStatus('No Google client ID configured — add one under Advanced.');
  }
  $('anchorError').textContent = '';

  // Populate the validation-day select with all 14 pay-period days labelled
  // by weekday and week number, plus a "None" option.
  const sel = $('validationDaySelect');
  sel.innerHTML = '';
  sel.appendChild(el('option', { value: '' }, 'None'));
  for (let i = 0; i < 14; i++) {
    const wk = i < 7 ? 1 : 2;
    const dayName = DAY_NAMES[i % 7];
    sel.appendChild(el('option', { value: i }, `${dayName}, week ${wk} (day ${i + 1})`));
  }
  sel.value = state.validationDay == null ? '' : String(state.validationDay);
}

// 7 day-rows. Each row has an enable toggle, day label, and a draggable
// timeline strip. Slot times persist even when the day is toggled off, so
// re-enabling restores the user's last values. Changes are buffered in
// state.defaultSchedule until the user hits "Save & apply".
// Render the dedicated Default Schedule view (14-day pay-period layout, one
// week at a time, Sat/Sun hidden by default, per-row "copy to all" button).
function renderScheduleView() {
  // Highlight the active week tab.
  for (const tab of $('schedWeekTabs').querySelectorAll('.week-tab')) {
    tab.classList.toggle('active', Number(tab.dataset.week) === state.viewedWeek);
  }

  const list = $('schedDayList');
  list.innerHTML = '';

  // All 7 days of the selected week are always shown — the user toggles
  // each day on/off via the row's enable switch instead.
  const weekStart = state.viewedWeek === 1 ? 0 : 7;
  for (let i = weekStart; i < weekStart + 7; i++) {
    list.appendChild(buildScheduleRow(i));
  }
  requestAnimationFrame(() => reflowList(list));

  renderScheduleRecurring();   // calendar-mode recurring events (async, fire-and-forget)
}

// Recurring events that ride the pay-period schedule — biweekly series
// (FREQ=WEEKLY;INTERVAL=2) anchored to a day-of-period in the current period.
// Mirrors the iOS schedule editor's "Recurring events" section. Calendar mode
// only; reuses the event modal + DB so they're ordinary biweekly events
// everywhere else (calendar/day views, Google sync).
async function renderScheduleRecurring() {
  const box = $('schedRecurring');
  if (!box) return;
  if (!state.calendarMode) { box.hidden = true; box.innerHTML = ''; return; }
  box.hidden = false;
  box.innerHTML = '';

  box.appendChild(el('h2', { class: 'sched-recurring-title' }, 'Recurring events'));
  box.appendChild(el('div', { class: 'period-meta' },
    'Repeating events that ride your pay-period schedule — each repeats every 2 weeks on its day. They also show on the calendar and day views.'));

  // No anchor → no current period → can't map a day-of-period to a date.
  if (!state.anchor) {
    box.appendChild(el('div', { class: 'hint' }, 'Set a pay-period anchor first (Settings → Pay period).'));
    return;
  }

  const days = T.payPeriodFor(new Date(), state.anchor).days;   // 14 YYYY-MM-DD

  // Existing local recurring series.
  let series = [];
  try { series = (await DB.recurringSeries()).filter((s) => (s.source || 'local') === 'local'); }
  catch { series = []; }
  series.sort((a, b) => (a.date || '').localeCompare(b.date || '') || (a.startMin - b.startMin));

  if (!series.length) {
    box.appendChild(el('div', { class: 'hint' }, 'No recurring events yet.'));
  } else {
    const listEl = el('div', { class: 'sched-recurring-list' });
    for (const s of series) {
      const dot = el('span', { class: 'ev-dot' });
      dot.style.background = Calendar.colorVar(s.color || DEFAULT_EVENT_COLOR);
      const when = s.allDay
        ? 'all-day'
        : `${T.formatMinutes(s.startMin, state.use24h)}–${T.formatMinutes(s.endMin, state.use24h)}`;
      const wd = s.date ? DAY_NAMES[T.parseLocalDate(s.date).getDay()] : '';
      listEl.appendChild(el('div', { class: 'sched-recurring-row' },
        dot,
        el('div', { class: 'sched-recurring-info' },
          el('div', { class: 'sched-recurring-name' }, s.title || '(untitled)'),
          el('div', { class: 'sched-recurring-meta' }, `Every 2 weeks · ${wd} · ${when}`)),
        el('button', { class: 'cal-action-btn', onclick: () => openEventModal(s.date, s, 'all') }, 'Edit'),
        el('button', {
          class: 'cal-action-btn danger-text',
          onclick: async () => {
            if (!window.confirm(`Delete "${s.title || 'this event'}" and all its occurrences?`)) return;
            await DB.deleteEventAndSync(s.id);
            renderScheduleRecurring();
          },
        }, 'Delete'),
      ));
    }
    box.appendChild(listEl);
  }

  // Add control: pick a day-of-period, then open the event modal pre-set to a
  // biweekly series anchored to that date.
  const daySelect = el('select', { class: 'sched-recurring-day' });
  for (let i = 0; i < days.length; i++) {
    const wd = DAY_NAMES[T.parseLocalDate(days[i]).getDay()];
    const wk = i < 7 ? '' : ' ·2';
    daySelect.appendChild(el('option', { value: String(i) }, `${wd}${wk} — ${T.formatDateShort(days[i])}`));
  }
  const addBtn = el('button', {
    class: 'big-btn',
    onclick: () => {
      const i = Math.max(0, Math.min(days.length - 1, Number(daySelect.value) || 0));
      openEventModal(days[i], {
        date: days[i],
        startMin: 9 * 60,
        endMin: 10 * 60,
        color: DEFAULT_EVENT_COLOR,
        rrule: 'FREQ=WEEKLY;INTERVAL=2',
      }, 'new');
    },
  }, '+ Add recurring event');
  box.appendChild(el('div', { class: 'sched-recurring-add' }, daySelect, addBtn));
}

// One row for the 14-day schedule. dayIndex is 0..13.
function buildScheduleRow(dayIndex) {
  // Resolve a slot to render. Fall back to 9–5 for display purposes only —
  // the slot stays null in state until the user toggles it on, drags it, or
  // adds recurring leave.
  const saved = state.defaultSchedule[dayIndex];
  const slot = saved
    ? {
        enabled: saved.enabled !== false,
        startMin: saved.startMin,
        endMin: saved.endMin,
        leaveHours: Math.max(0, Math.round(Number(saved.leaveHours) || 0)),
      }
    : { enabled: false, startMin: 9 * 60, endMin: 17 * 60, leaveHours: 0 };

  // Merge a patch into this day's slot, preserving the other fields (so toggling
  // work, dragging the strip, or stepping leave never clobber each other).
  const writeSlot = (patch) => {
    const cur = state.defaultSchedule[dayIndex] || {
      enabled: slot.enabled, startMin: slot.startMin, endMin: slot.endMin, leaveHours: slot.leaveHours,
    };
    state.defaultSchedule[dayIndex] = {
      enabled: cur.enabled !== false,
      startMin: cur.startMin,
      endMin: cur.endMin,
      leaveHours: Math.max(0, Math.round(Number(cur.leaveHours) || 0)),
      ...patch,
    };
  };

  const weekday = dayIndex % 7;
  const row = el('div', { class: 'schedule-row' + (slot.enabled ? '' : ' off') });

  const toggleWrap = el('label', { class: 'schedule-toggle' });
  const toggle = el('input', {
    type: 'checkbox',
    onchange: (ev) => {
      writeSlot({ enabled: ev.target.checked });
      renderScheduleView();
    },
  });
  if (slot.enabled) toggle.checked = true;
  const tSlider = el('span', { class: 'toggle-slider sm' });
  toggleWrap.appendChild(toggle);
  toggleWrap.appendChild(tSlider);

  const weekLabel = state.viewedWeek === 1 ? '' : '·2';
  const label = el('span', { class: 'schedule-day' }, DAY_NAMES[weekday] + weekLabel);

  const strip = buildScheduleStrip(slot, (newStart, newEnd) => {
    writeSlot({ startMin: newStart, endMin: newEnd });
    timeText.textContent = `${T.formatMinutes(newStart, state.use24h)} – ${T.formatMinutes(newEnd, state.use24h)}`;
  });

  const timeText = el('span', { class: 'schedule-time-text' },
    `${T.formatMinutes(slot.startMin, state.use24h)} – ${T.formatMinutes(slot.endMin, state.use24h)}`);

  // Recurring-leave stepper (0–24 h, whole hours). Independent of the work
  // toggle — applying the schedule seeds these leave hours on this day-of-period
  // in every upcoming period.
  const leaveDec = el('button', {
    class: 'leave-btn',
    title: 'Remove 1 leave hour',
    onclick: (ev) => {
      ev.stopPropagation();
      if (slot.leaveHours <= 0) return;
      writeSlot({ leaveHours: slot.leaveHours - 1 });
      renderScheduleView();
    },
  }, '−');
  if (slot.leaveHours <= 0) leaveDec.disabled = true;
  const leaveInc = el('button', {
    class: 'leave-btn',
    title: 'Add 1 leave hour',
    onclick: (ev) => {
      ev.stopPropagation();
      if (slot.leaveHours >= 24) return;
      writeSlot({ leaveHours: slot.leaveHours + 1 });
      renderScheduleView();
    },
  }, '+');
  const leaveCtrl = el('div', { class: 'leave-mini schedule-leave', title: 'Recurring leave hours' },
    leaveDec,
    el('span', { class: 'leave-mini-label' }, `Leave ${slot.leaveHours}h`),
    leaveInc,
  );

  // Copy this row's hours AND recurring leave to all 10 weekday slots
  // (Mon-Fri × both weeks), turning them on. Weekend rows are untouched.
  const copyBtn = el('button', {
    class: 'schedule-copy',
    title: 'Copy these hours to all weekdays',
    onclick: (ev) => {
      ev.stopPropagation();
      if (!window.confirm(
        `Copy ${DAY_NAMES[weekday]}'s hours and leave to every weekday in both weeks?`
      )) return;
      const src = state.defaultSchedule[dayIndex] || slot;
      const weekdayIdx = [1, 2, 3, 4, 5, 8, 9, 10, 11, 12];
      for (const i of weekdayIdx) {
        state.defaultSchedule[i] = {
          enabled: true,
          startMin: src.startMin,
          endMin: src.endMin,
          leaveHours: Math.max(0, Math.round(Number(src.leaveHours) || 0)),
        };
      }
      renderScheduleView();
    },
  }, '⧉');

  row.appendChild(toggleWrap);
  row.appendChild(label);
  row.appendChild(strip);
  row.appendChild(timeText);
  row.appendChild(leaveCtrl);
  row.appendChild(copyBtn);
  return row;
}

// A mini timeline strip with one bar + two drag handles. Standalone — not tied
// to entries / DB. onChange(newStart, newEnd) fires after drag-release.
function buildScheduleStrip(slot, onChange) {
  const wrap = el('div', { class: 'day-timeline schedule-strip' + (slot.enabled ? '' : ' off') });
  wrap._scale = autoFitScale([{
    startTime: T.buildDateTime('2000-01-01', Math.floor(slot.startMin / 60), slot.startMin % 60).toISOString(),
    endTime:   T.buildDateTime('2000-01-01', Math.floor(slot.endMin / 60),   slot.endMin % 60).toISOString(),
  }]);

  // Hour ticks (no labels — strip is too small)
  const firstWholeHour = Math.ceil(ABSOLUTE_START_MIN / 60) * 60;
  for (let m = firstWholeHour; m <= ABSOLUTE_END_MIN; m += 60) {
    const isMajor = (m % 180 === 0);
    const tick = el('div', { class: 'tl-tick' + (isMajor ? ' major' : '') });
    tick.dataset.leftMin = String(m);
    wrap.appendChild(tick);
  }

  const tooltip = el('div', { class: 'tl-tooltip' });
  wrap.appendChild(tooltip);

  const bar = el('div', { class: 'tl-bar' });
  bar.dataset.leftMin = String(slot.startMin);
  bar.dataset.widthMin = String(slot.endMin - slot.startMin);
  wrap.appendChild(bar);

  // Persistent edge time labels (same as the period view).
  const startLabel = el('div', { class: 'tl-time-label tl-time-start' },
    T.formatMinutes(slot.startMin, state.use24h));
  startLabel.dataset.leftMin = String(slot.startMin);
  wrap.appendChild(startLabel);
  const endLabel = el('div', { class: 'tl-time-label tl-time-end' },
    T.formatMinutes(slot.endMin, state.use24h));
  endLabel.dataset.leftMin = String(slot.endMin);
  wrap.appendChild(endLabel);

  // Recurring-leave segment: a teal bar drawn ON this day's strip (the same
  // band as the work bar) so it's obvious WHICH day the leave belongs to and
  // how much it is. On an enabled workday it reads as a continuation to the
  // right of the worked hours (mirrors the day timeline); on a pure-leave
  // off day (no real work) it anchors at the left edge so the whole strip
  // reads as "this day is leave."
  let leaveBar = null;
  const leaveAnchorsEnd = slot.enabled && slot.leaveHours > 0;
  if (slot.leaveHours > 0) {
    const leaveStart = leaveAnchorsEnd ? slot.endMin : ABSOLUTE_START_MIN;
    const leaveWidth = slot.leaveHours * 60;
    leaveBar = el('div', {
      class: 'tl-leave',
      title: `${slot.leaveHours}h recurring leave`,
    });
    leaveBar.dataset.leftMin = String(leaveStart);
    leaveBar.dataset.widthMin = String(leaveWidth);
    // Widen the strip's scale so the leave bar stays on-screen.
    wrap._scale.endMin = Math.min(ABSOLUTE_END_MIN,
      Math.max(wrap._scale.endMin, leaveStart + leaveWidth + SCALE_PAD_MIN));
    wrap.appendChild(leaveBar);
  }

  // Local entry-shaped object so we can reuse attachHandleDrag
  const localEntry = {
    _slot: slot,
    startTime: null, // unused; we override the save path below
    endTime: null,
  };
  const refs = { bar, lunchEl: null, tooltip, entry: localEntry, dateStr: null, lunchMinutes: 0 };

  // Custom mini drag handler (mirrors attachHandleDrag but saves via onChange)
  function addScheduleHandle(which, atMin) {
    const knob = el('div', { class: 'tl-handle tl-handle-' + which });
    knob.dataset.leftMin = String(atMin);
    const hit = el('div', { class: 'tl-hit' });
    hit.dataset.leftMin = String(atMin);
    let dragging = false, oppMin = 0, curMin = 0, grabOffsetMin = 0;
    // Last minute we fired a haptic snap-tick for, so each 15-min step buzzes
    // exactly once (a native-feeling click as the handle crosses each notch).
    let lastBuzzMin = null;

    const pointerToMin = (clientX) => {
      const rect = wrap.getBoundingClientRect();
      const pct = ((clientX - rect.left) / rect.width) * 100;
      return pctToMin(pct, wrap._scale);
    };

    const onMove = (ev) => {
      if (!dragging) return;
      ev.preventDefault();
      let m = pointerToMin(ev.clientX) - grabOffsetMin;
      m = Math.round(m / SNAP_MIN) * SNAP_MIN;
      m = clampToAbsolute(m);
      if (which === 'start') {
        m = Math.min(oppMin - SNAP_MIN, m);
      } else {
        m = Math.max(oppMin + SNAP_MIN, Math.min(ABSOLUTE_END_MIN - SNAP_MIN, m));
      }
      // Haptic snap-tick on each new quarter-hour notch.
      if (m !== lastBuzzMin) { vibrate(4); lastBuzzMin = m; }
      curMin = m;
      knob.dataset.leftMin = String(m);
      hit.dataset.leftMin = String(m);
      const sm = which === 'start' ? m : oppMin;
      const em = which === 'end' ? m : oppMin;
      bar.dataset.leftMin = String(sm);
      bar.dataset.widthMin = String(em - sm);
      // Keep the leave bar pinned to the right of the work hours as the end
      // handle moves, so it reads as a live continuation.
      if (which === 'end' && leaveBar && leaveAnchorsEnd) {
        leaveBar.dataset.leftMin = String(em);
      }
      // Update the side-specific label.
      const labelEl = which === 'start' ? startLabel : endLabel;
      if (labelEl) {
        labelEl.dataset.leftMin = String(m);
        labelEl.textContent = T.formatMinutes(m, state.use24h);
      }
      // During drag, only expand (never contract under the user's finger).
      reflowList(wrap.closest('.day-list'), /*allowContract*/ false);
      tooltip.style.left = Math.max(8, Math.min(92, minToPct(m, wrap._scale))) + '%';
      tooltip.textContent = T.formatMinutes(m, state.use24h);
      tooltip.classList.add('visible');
    };
    const onUp = (ev) => {
      if (!dragging) return;
      dragging = false;
      knob.classList.remove('dragging');
      tooltip.classList.remove('visible');
      try { hit.releasePointerCapture(ev.pointerId); } catch {}
      const sm = which === 'start' ? curMin : parseFloat(bar.dataset.leftMin);
      const em = which === 'end'   ? curMin : sm + parseFloat(bar.dataset.widthMin);
      vibrate(8);   // confirm-buzz on release
      onChange(sm, em);
    };
    hit.addEventListener('pointerdown', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      dragging = true;
      const curStart = parseFloat(bar.dataset.leftMin);
      const curEnd = curStart + parseFloat(bar.dataset.widthMin);
      const handleMin = which === 'start' ? curStart : curEnd;
      oppMin = which === 'start' ? curEnd : curStart;
      grabOffsetMin = pointerToMin(ev.clientX) - handleMin;
      curMin = handleMin;
      lastBuzzMin = handleMin;
      knob.classList.add('dragging');
      vibrate(8);   // grab-buzz so the drag registers immediately
      try { hit.setPointerCapture(ev.pointerId); } catch {}
    });
    hit.addEventListener('pointermove', onMove);
    hit.addEventListener('pointerup', onUp);
    hit.addEventListener('pointercancel', onUp);
    wrap.appendChild(knob);
    wrap.appendChild(hit);
  }
  addScheduleHandle('start', slot.startMin);
  addScheduleHandle('end', slot.endMin);

  reflowTimeline(wrap);
  return wrap;
}

async function onClearAll() {
  if (!window.confirm(
    'Permanently delete ALL data?\n\n' +
    'Every entry, leave hour, default schedule, and setting on this device will be wiped. ' +
    'There is no undo. Export a CSV backup first if you might want it back.'
  )) return;
  if (!window.confirm('Are you absolutely sure? Last chance to back out.')) return;
  try {
    await DB.db.transaction('rw', DB.db.entries, DB.db.leave, DB.db.settings, async () => {
      await DB.db.entries.clear();
      await DB.db.leave.clear();
      await DB.db.settings.clear();
    });
    state.anchor = await DB.getAnchor();   // falls back to DEFAULT_ANCHOR
    state.otModeDefault = true;
    state.otModeOverrides = {};
    state.creditHoursEnabled = false;
    state.hourlyRate = 0;
    state.use24h = false;
    state.defaultSchedule = await DB.getDefaultSchedule();
    state.autoHolidays = true;
    state.holidays = {};
    state.openEntry = null;
    // Re-seed federal holidays for the fresh slate.
    await ensureHolidaysSeeded();
    showToast('All data cleared');
    await renderAll();
    renderSettings();
  } catch (err) {
    console.error(err);
    showToast('Clear failed: ' + err.message);
  }
}

// Copy the currently-edited day's entries + leave to every OTHER weekday in
// its pay period (Mon-Fri, both weeks). Destructive: target days have their
// existing entries wiped first.
async function onCopyDayToWeekdays() {
  const src = state.editingDate;
  if (!src || !state.anchor) return;
  const srcDow = T.parseLocalDate(src).getDay();
  const period = T.payPeriodFor(T.parseLocalDate(src), state.anchor);
  const weekdayIdx = [1, 2, 3, 4, 5, 8, 9, 10, 11, 12];
  const targets = weekdayIdx
    .map(i => period.days[i])
    .filter(d => d !== src);
  if (!targets.length) return;
  if (!window.confirm(
    `Copy ${T.formatDateShort(src)}'s entries and leave to ${targets.length} other weekdays in this period?\n\n` +
    'Existing entries on those days will be overwritten.'
  )) return;
  try {
    const srcEntries = await DB.entriesForDate(src);
    const srcLeave = await DB.getLeave(src);
    for (const tgt of targets) {
      // Wipe existing work entries on the target day
      const existing = await DB.entriesForDate(tgt);
      for (const e of existing) await DB.deleteEntry(e.id);
      // Recreate each source entry on the target date with the same clock
      // times and lunch (the entry's date moves but the time-of-day stays).
      for (const e of srcEntries) {
        if (e.incomplete || !e.endTime) continue;
        const sd = new Date(e.startTime);
        const ed = new Date(e.endTime);
        const startIso = T.buildDateTime(tgt, sd.getHours(), sd.getMinutes()).toISOString();
        const endIso = T.buildDateTime(tgt, ed.getHours(), ed.getMinutes()).toISOString();
        await DB.upsertEntry({
          date: tgt,
          startTime: startIso,
          endTime: endIso,
          lunchMinutes: e.lunchMinutes != null ? e.lunchMinutes : (e.lunchDeducted ? 30 : 0),
          incomplete: false,
        });
      }
      await DB.setLeaveHours(tgt, srcLeave);
    }
    showToast(`Copied to ${targets.length} weekday${targets.length === 1 ? '' : 's'}`);
    await renderAll();
  } catch (err) {
    console.error(err);
    showToast('Copy failed: ' + err.message);
  }
}

async function onExport() {
  try {
    const csv = await DB.exportToCsv();
    const today = T.formatLocalDate(new Date());
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `timecard-export-${today}.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    showToast('Exported');
  } catch (err) {
    console.error(err);
    showToast('Export failed: ' + err.message);
  }
}

async function onExportCalendar() {
  try {
    if (!state.anchor) {
      showToast('Set an anchor date first.');
      return;
    }
    const schedule = await DB.getDefaultSchedule();
    const period = T.payPeriodFor(new Date(), state.anchor);
    const ics = T.buildScheduleIcs(schedule, period.start);
    const today = T.formatLocalDate(new Date());
    const blob = new Blob([ics], { type: 'text/calendar;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `maxiflex-schedule-${today}.ics`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    showToast('Calendar exported');
  } catch (err) {
    console.error(err);
    showToast('Calendar export failed: ' + err.message);
  }
}

// Export ALL calendar events as a single .ics (single + recurring + overrides;
// backlog items, which have no date, are skipped). Recurrence rides along as the
// stored RRULE so it round-trips through any calendar app.
async function onExportEventsIcs() {
  try {
    const events = await DB.db.events.toArray();
    if (!events.length) { showToast('No calendar events to export'); return; }
    const ics = Calendar.buildEventsIcs(events, { calName: 'Home Calendar' });
    const today = T.formatLocalDate(new Date());
    const blob = new Blob([ics], { type: 'text/calendar;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `home-calendar-${today}.ics`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    showToast('Events exported');
  } catch (err) {
    console.error(err);
    showToast('Events export failed: ' + err.message);
  }
}

// Import events from an .ics file. Additive (merges into existing events); each
// VEVENT becomes an event row (keyed by its UID when it's one of ours).
async function onImportEventsIcs(ev) {
  const file = ev.target.files && ev.target.files[0];
  ev.target.value = '';
  if (!file) return;
  try {
    const text = await file.text();
    const parsed = Calendar.parseEventsIcs(text);
    if (!parsed.length) { showToast('No events found in that file'); return; }
    let n = 0;
    for (const e of parsed) { await DB.upsertEvent(e); n++; }
    showToast(`Imported ${n} event${n === 1 ? '' : 's'}`);
    await renderAll();
  } catch (err) {
    console.error(err);
    showToast('Events import failed: ' + err.message);
  }
}

async function onImport(ev) {
  const file = ev.target.files && ev.target.files[0];
  ev.target.value = ''; // reset so re-picking the same file fires change again
  if (!file) return;
  const ok = window.confirm(
    `Import "${file.name}"?\n\n` +
    'This REPLACES all current data: settings, default schedule, entries, leave. ' +
    'Consider exporting your current data first as a backup.'
  );
  if (!ok) return;
  try {
    const text = await file.text();
    await DB.importFromCsv(text);
    // Reload all in-memory state from the freshly imported DB.
    state.anchor = await DB.getAnchor();
    state.otModeDefault = await DB.getOvertimeModeDefault();
    state.otModeOverrides = await DB.getOvertimeModeOverrides();
    state.creditHoursEnabled = await DB.getCreditHoursEnabled();
    state.leaveGranularMinutes = await DB.getLeaveGranular();
    state.hourlyRate = await DB.getHourlyRate();
    state.use24h = await DB.getUse24h();
    state.defaultSchedule = await DB.getDefaultSchedule();
    state.autoHolidays = await DB.getAutoHolidays();
    state.holidays = await DB.getHolidays();
    state.calendarMode = await DB.getCalendarMode();
    applyCalendarMode();
    state.theme = await DB.getTheme();
    applyTheme();
    await ensureHolidaysSeeded();
    state.openEntry = await DB.getOpenEntry();
    await renderAll();
    renderSettings(); // re-paint the schedule grid + toggle states
    showToast('Import complete');
  } catch (err) {
    console.error(err);
    showToast('Import failed: ' + err.message);
  }
}

async function onApplyDefaultSchedule() {
  if (!state.anchor) {
    showToast('Set an anchor date first.');
    return;
  }
  await DB.setDefaultSchedule(state.defaultSchedule);
  const includeCurrent = $('includeCurrentToggle').checked;
  const today = new Date();
  const currentPeriod = T.payPeriodFor(today, state.anchor);
  let startPeriod = currentPeriod;
  if (!includeCurrent) {
    startPeriod = T.payPeriodOffset(today, state.anchor, 1);
  }
  $('scheduleStatus').textContent = 'Applying…';
  try {
    const holidaySet = new Set(activeHolidayDates());
    const { written, leaveDays } = await DB.applyDefaultSchedule(
      state.defaultSchedule, startPeriod, state.anchor, 26, holidaySet);
    // Clocked-in entry may have been wiped; refresh.
    state.openEntry = await DB.getOpenEntry();
    const workMsg = `Filled ${written} work day${written === 1 ? '' : 's'}`;
    const leaveMsg = leaveDays > 0
      ? ` and seeded leave on ${leaveDays} day${leaveDays === 1 ? '' : 's'}`
      : '';
    $('scheduleStatus').textContent = `${workMsg}${leaveMsg} across the next year.`;
    showToast('Default schedule applied');
    await renderAll();
  } catch (err) {
    console.error(err);
    $('scheduleStatus').textContent = 'Error: ' + err.message;
  }
}

// --- Actions ----------------------------------------------------------------

async function onClockToggle() {
  if (!state.anchor) {
    setView('settings');
    showToast('Set an anchor date first.');
    return;
  }
  if (state.openEntry) {
    await DB.clockOut();
    state.openEntry = null;
    vibrate(15);
    showToast('Clocked out');
  } else {
    // Double-check no stale open entry
    const existing = await DB.getOpenEntry();
    if (existing) {
      state.openEntry = existing;
      $('confirmModal').hidden = false;
      return;
    }
    state.openEntry = await DB.clockIn();
    vibrate(10);
    showToast('Clocked in');
  }
  await renderAll();
}

async function onAnchorChange(ev) {
  const val = ev.target.value;
  if (!val) return;
  if (!T.isSunday(val)) {
    $('anchorError').textContent = 'That date is not a Sunday. Please pick a Sunday.';
    return;
  }
  $('anchorError').textContent = '';
  await DB.setAnchor(val);
  state.anchor = val;
  showToast('Anchor saved');
  await renderAll();
}

// Per-payKind explainer shown under the classification select (Maxiflex only).
const PAY_KIND_HINTS = {
  auto: 'Hours beyond your schedule (once the period passes 80, leave included) pay overtime. In 8-hour mode classification is ignored.',
  autoCredit: 'Like Auto, but those beyond-schedule hours bank as credit hours (1:1, no premium).',
  overtime: 'Force the whole entry to overtime (1.5×) — for ordered/approved OT.',
  credit: 'Force the whole entry to credit hours — banked 1:1, no premium.',
  regular: 'Force regular — never overtime or credit, even beyond schedule.',
};
function updatePayKindHint() {
  $('entryPayKindHint').textContent = PAY_KIND_HINTS[$('entryPayKind').value] || '';
}

async function openEntryModal(entry) {
  state.editingEntry = entry;
  $('entryModalTitle').textContent = entry ? 'Edit Entry' : 'Add Entry';
  const d = state.editingDate;
  const defaultStart = entry ? new Date(entry.startTime) : T.buildDateTime(d, 9, 0);
  const defaultEnd = entry && entry.endTime
    ? new Date(entry.endTime)
    : T.buildDateTime(d, 17, 0);
  populateTimeSelects();
  setTimeSelect('start', defaultStart);
  setTimeSelect('end', defaultEnd);
  // Next-day flag
  const startDate = T.formatLocalDate(defaultStart);
  const endDate = T.formatLocalDate(defaultEnd);
  $('endNextDay').checked = startDate !== endDate;
  // Lunch — falls back to 30 if the legacy lunchDeducted flag is true and
  // lunchMinutes hasn't been set yet.
  const lm = entry && entry.lunchMinutes != null
    ? entry.lunchMinutes
    : (entry && entry.lunchDeducted ? 30 : 30);
  $('lunchMinutesSelect').value = String(lm);
  // Pay classification: an existing entry keeps its stored kind (legacy
  // isOvertime migrates); a NEW entry defaults to the period's credit-default
  // (autoCredit when the flex toggle is on, else auto). LOGIC-FREEZE §4.3.
  let kind;
  if (entry) {
    kind = DB.entryPayKind(entry);
  } else {
    const periodStart = T.payPeriodFor(T.parseLocalDate(d), state.anchor).days[0];
    kind = (await DB.getCreditDefaultForPeriodStart(periodStart)) ? 'autoCredit' : 'auto';
  }
  $('entryPayKind').value = kind;
  // The OT checkbox mirrors the same value (overtime ↔ checked) for the
  // credit-OFF view. Show one control or the other per the feature switch.
  $('entryOvertime').checked = kind === 'overtime';
  $('entryPayKindRow').hidden = !state.creditHoursEnabled;
  $('entryOvertimeRow').hidden = !!state.creditHoursEnabled;
  updatePayKindHint();
  $('entryModal').hidden = false;
}

// Resolve the payKind to save from whichever entry-modal control is active.
// `base` is the entry being edited (or { id:null }) — used to preserve a stored
// credit classification when the credit feature is off (non-destructive).
function readEntryPayKind(base) {
  if (state.creditHoursEnabled) return $('entryPayKind').value;
  if ($('entryOvertime').checked) return 'overtime';
  const prior = base ? DB.entryPayKind(base) : 'auto';
  // Unchecked: a forced OT drops back to auto; any other stored kind (incl.
  // credit) survives untouched so flipping the feature on/off loses nothing.
  return prior === 'overtime' ? 'auto' : prior;
}

function closeEntryModal() {
  $('entryModal').hidden = true;
  state.editingEntry = null;
}

// Build hour / min / am-pm <option>s for both start and end based on use24h.
function populateTimeSelects() {
  for (const prefix of ['start', 'end']) {
    const hourSel = $(prefix + 'Hour');
    const minSel = $(prefix + 'Min');
    const ampmSel = $(prefix + 'AmPm');
    hourSel.innerHTML = '';
    minSel.innerHTML = '';
    ampmSel.innerHTML = '';
    if (state.use24h) {
      for (let h = 0; h < 24; h++) {
        hourSel.appendChild(el('option', { value: h }, String(h).padStart(2, '0')));
      }
      ampmSel.style.display = 'none';
    } else {
      for (let h = 1; h <= 12; h++) {
        hourSel.appendChild(el('option', { value: h }, String(h)));
      }
      ampmSel.appendChild(el('option', { value: 'AM' }, 'AM'));
      ampmSel.appendChild(el('option', { value: 'PM' }, 'PM'));
      ampmSel.style.display = '';
    }
    for (const m of [0, 15, 30, 45]) {
      minSel.appendChild(el('option', { value: m }, ':' + String(m).padStart(2, '0')));
    }
  }
}

function setTimeSelect(prefix, date) {
  const h24 = date.getHours();
  const m = date.getMinutes();
  const snap = Math.round(m / 15) * 15 % 60;
  $(prefix + 'Min').value = String(snap);
  if (state.use24h) {
    $(prefix + 'Hour').value = String(h24);
  } else {
    const ampm = h24 >= 12 ? 'PM' : 'AM';
    let h12 = h24 % 12; if (h12 === 0) h12 = 12;
    $(prefix + 'Hour').value = String(h12);
    $(prefix + 'AmPm').value = ampm;
  }
}

function readTimeSelect(prefix, dateStr) {
  let h = parseInt($(prefix + 'Hour').value, 10);
  const m = parseInt($(prefix + 'Min').value, 10);
  if (!state.use24h) {
    const ampm = $(prefix + 'AmPm').value;
    if (ampm === 'PM' && h !== 12) h += 12;
    if (ampm === 'AM' && h === 12) h = 0;
  }
  return T.buildDateTime(dateStr, h, m);
}

async function saveEntryFromModal() {
  const d = state.editingDate;
  const start = readTimeSelect('start', d);
  let end = readTimeSelect('end', d);
  if ($('endNextDay').checked) {
    end = new Date(end.getTime() + 24 * 60 * 60 * 1000);
  }
  if (end <= start) {
    showToast('End must be after start');
    return;
  }
  const base = state.editingEntry || { id: null };
  const entry = {
    ...base,
    date: d,
    startTime: start.toISOString(),
    endTime: end.toISOString(),
    lunchMinutes: Number($('lunchMinutesSelect').value) || 0,
    payKind: readEntryPayKind(base),
    incomplete: false,
  };
  // Drop the legacy boolean so it can't shadow the stored payKind on re-read.
  delete entry.isOvertime;
  await DB.upsertEntry(entry);
  // If the edited entry was the open one, the edit implicitly closes it.
  if (state.openEntry && state.openEntry.id === entry.id) {
    state.openEntry = null;
  }
  closeEntryModal();
  showToast('Entry saved');
  await renderAll();
}

// --- Calendar event editor (modal) -----------------------------------------

const DEFAULT_EVENT_COLOR = 'work';

// Map a friendly repeat preset <-> an RRULE string. `opts` carries the preset
// plus the optional BYDAY day list (weekly/biweekly) and the end condition
// (`never` | `until` <date> | `count` <N>). The recurrence engine
// (calendar.js) supports BYDAY/COUNT/UNTIL; these helpers just translate the
// modal controls to/from the stored RRULE string.
function repeatPresetToRRule(opts) {
  const preset = opts.preset;
  let o = null;
  if (preset === 'daily') o = { freq: 'DAILY', interval: 1 };
  else if (preset === 'weekly') o = { freq: 'WEEKLY', interval: 1 };
  else if (preset === 'biweekly') o = { freq: 'WEEKLY', interval: 2 };
  else if (preset === 'monthly') o = { freq: 'MONTHLY', interval: 1 };
  else if (preset === 'yearly') o = { freq: 'YEARLY', interval: 1 };
  if (!o) return null;
  if ((preset === 'weekly' || preset === 'biweekly') && opts.bydays && opts.bydays.length) {
    o.byday = opts.bydays;
  }
  if (opts.endMode === 'count' && opts.count > 0) o.count = Math.max(1, opts.count | 0);
  else if (opts.endMode === 'until' && opts.until) o.until = opts.until.replace(/-/g, '');
  return Calendar.formatRRule(o);
}
function rruleToRepeat(rrule) {
  const o = Calendar.parseRRule(rrule);
  if (!o) return { preset: 'none', byday: [], endMode: 'never', until: '', count: '' };
  let preset = 'none';
  if (o.freq === 'DAILY') preset = 'daily';
  else if (o.freq === 'WEEKLY') preset = o.interval === 2 ? 'biweekly' : 'weekly';
  else if (o.freq === 'MONTHLY') preset = 'monthly';
  else if (o.freq === 'YEARLY') preset = 'yearly';
  let endMode = 'never', until = '', count = '';
  if (o.count) { endMode = 'count'; count = o.count; }
  else if (o.until) {
    endMode = 'until';
    until = `${o.until.slice(0, 4)}-${o.until.slice(4, 6)}-${o.until.slice(6, 8)}`;
  }
  return { preset, byday: o.byday || [], endMode, until, count };
}

// Read the repeat controls in the event modal into an RRULE string (or null).
function readRepeatControls() {
  return repeatPresetToRRule({
    preset: $('eventRepeat').value,
    bydays: Array.from($('eventByday').querySelectorAll('.byday-day.selected'))
      .map(b => b.dataset.dow),
    endMode: $('eventEnds').value,
    until: $('eventUntil').value || '',
    count: parseInt($('eventCount').value, 10) || 0,
  });
}

// Show/hide the dependent repeat sub-rows (day picker, end condition) based on
// the current preset + end mode. `anchorYmd` seeds the BYDAY picker with the
// anchor's weekday when weekly turns on with nothing selected yet.
const RRULE_DOW_CODES = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
function syncRepeatUi(anchorYmd) {
  const preset = $('eventRepeat').value;
  const repeats = preset !== 'none';
  const weekly = preset === 'weekly' || preset === 'biweekly';
  $('eventBydayRow').hidden = !weekly;
  $('eventEndsRow').hidden = !repeats;
  const ends = $('eventEnds').value;
  $('eventUntilRow').hidden = !repeats || ends !== 'until';
  $('eventCountRow').hidden = !repeats || ends !== 'count';
  if (weekly && anchorYmd && !$('eventByday').querySelector('.byday-day.selected')) {
    const dow = RRULE_DOW_CODES[T.parseLocalDate(anchorYmd).getDay()];
    const btn = $('eventByday').querySelector(`.byday-day[data-dow="${dow}"]`);
    if (btn) btn.classList.add('selected');
  }
}

function setBydaySelection(days) {
  const set = new Set(days || []);
  for (const b of $('eventByday').querySelectorAll('.byday-day')) {
    b.classList.toggle('selected', set.has(b.dataset.dow));
  }
}

// YYYY-MM-DD one day before the given date.
function ymdMinusOneDay(ymd) {
  const dt = T.parseLocalDate(ymd);
  dt.setDate(dt.getDate() - 1);
  return T.formatLocalDate(dt);
}

// Truncate a series' RRULE so it stops the day before `beforeYmd`. Drops COUNT
// (ambiguous once a series is split) in favor of an explicit UNTIL cutoff.
function truncateRRuleBefore(rruleStr, beforeYmd) {
  const o = Calendar.parseRRule(rruleStr);
  if (!o) return rruleStr;
  o.count = null;
  o.until = ymdMinusOneDay(beforeYmd).replace(/-/g, '');
  return Calendar.formatRRule(o);
}

// Entry points from the Events list / lane taps: route edits & deletes of a
// recurring occurrence through the this/all choice; plain events go direct.
function editCalEvent(ev, dateStr) {
  if (ev && ev._occurrenceOf) {
    openRecurringChoice('edit', ev, dateStr);
  } else {
    openEventModal(dateStr, ev, ev && ev.id ? 'single' : 'new');
  }
}
async function deleteCalEvent(ev, dateStr, afterRender) {
  if (ev && ev._occurrenceOf) {
    openRecurringChoice('delete', ev, dateStr, afterRender);
    return;
  }
  await DB.deleteEventAndSync(ev.id);
  showToast('Event deleted', async () => { await DB.upsertEvent(ev); if (afterRender) afterRender(); });
  if (afterRender) afterRender();
}

// scope: 'new' (create) | 'single' (edit non-recurring) | 'this' (edit one
// occurrence -> becomes an override) | 'all' (edit the whole series).
function openEventModal(dateStr, ev, scope) {
  state.editingDate = dateStr;
  state.editingEvent = ev;
  state.editScope = scope || (ev && ev.id ? 'single' : 'new');
  const isEdit = state.editScope !== 'new';
  $('eventModalTitle').textContent = state.editScope === 'following'
    ? 'Edit this & following'
    : (isEdit ? 'Edit Event' : 'Add Event');
  $('eventTitle').value = ev ? (ev.title || '') : '';
  $('eventLocation').value = ev ? (ev.location || '') : '';
  $('eventNotes').value = ev ? (ev.notes || '') : '';
  renderEventColorSwatches(ev && ev.color ? ev.color : DEFAULT_EVENT_COLOR);
  renderEventSuggestions('');
  $('eventSuggest').hidden = true;

  const allDay = !!(ev && ev.allDay);
  $('eventAllDay').checked = allDay;
  $('eventTimeFields').hidden = allDay;

  populateEventTimeSelects();
  setEventTimeSelect('evStart', ev && isFinite(ev.startMin) ? ev.startMin : 9 * 60);
  setEventTimeSelect('evEnd', ev && isFinite(ev.endMin) ? ev.endMin : 10 * 60);

  // Repeat controls show for new events, whole-series edits, and "this &
  // following" (which creates a new series). An override ('this') is a single
  // event, so they're hidden there.
  const showRepeat = state.editScope === 'new' || state.editScope === 'all'
    || state.editScope === 'single' || state.editScope === 'following';
  $('eventRepeatFields').hidden = !showRepeat;
  const rep = rruleToRepeat(ev && ev.rrule);
  $('eventRepeat').value = rep.preset;
  $('eventEnds').value = rep.endMode;
  $('eventUntil').value = rep.until;
  $('eventCount').value = rep.count || 10;
  setBydaySelection(rep.byday);
  syncRepeatUi(state.editingDate);

  // Backlog toggle only when creating or editing a plain single event.
  const showBacklog = state.editScope === 'new' || state.editScope === 'single';
  $('eventBacklogRow').hidden = !showBacklog;
  $('eventBacklog').checked = !!(ev && ev.needsScheduling);
  syncBacklogUi();

  // 'following' is an edit-into-new-series flow; Delete there would be ambiguous
  // (delete-following is reachable from the recurring delete choice instead).
  $('eventDelete').hidden = !isEdit || state.editScope === 'following';
  $('eventModal').hidden = false;
}

// When "add to backlog" is on, the event has no date/time/recurrence.
function syncBacklogUi() {
  const backlog = $('eventBacklog').checked;
  $('eventAllDay').closest('.toggle-row').style.display = backlog ? 'none' : '';
  $('eventTimeFields').hidden = backlog || $('eventAllDay').checked;
  $('eventRepeatFields').hidden = backlog ||
    !(state.editScope === 'new' || state.editScope === 'all'
      || state.editScope === 'single' || state.editScope === 'following');
}

function closeEventModal() {
  $('eventModal').hidden = true;
  state.editingEvent = null;
  state.editScope = null;
}

// Type-ahead suggestions under the title field (§8): prefix match, newest-first,
// each deletable; picking one fills title + remembered color.
async function renderEventSuggestions(query) {
  const box = $('eventSuggest');
  let rows;
  try { rows = await DB.searchEventHistory(query, 8); }
  catch { rows = []; }
  box.innerHTML = '';
  if (!rows.length) { box.hidden = true; return; }
  for (const r of rows) {
    const dot = el('span', { class: 'ev-dot' });
    dot.style.background = Calendar.colorVar(r.defaultColor);
    const row = el('div', { class: 'ev-suggest-row' },
      el('div', {
        class: 'ev-suggest-pick',
        onclick: () => {
          $('eventTitle').value = r.displayTitle;
          renderEventColorSwatches(r.defaultColor || DEFAULT_EVENT_COLOR);
          box.hidden = true;
        },
      }, dot, el('span', {}, r.displayTitle)),
      el('button', {
        class: 'ev-suggest-del',
        title: 'Forget this',
        onclick: async (e) => {
          e.stopPropagation();
          await DB.deleteEventHistory(r.title);
          renderEventSuggestions($('eventTitle').value);
        },
      }, '×'),
    );
    box.appendChild(row);
  }
  box.hidden = false;
}

// Color/category swatches. The selected token is stashed on the container's
// dataset so save can read it without re-querying the DOM classes.
function renderEventColorSwatches(selected) {
  const wrap = $('eventColorSwatches');
  wrap.innerHTML = '';
  wrap.dataset.selected = selected;
  for (const token of Calendar.COLOR_ORDER) {
    const meta = Calendar.COLORS[token];
    const sw = el('button', {
      type: 'button',
      class: 'color-swatch' + (token === selected ? ' selected' : ''),
      title: meta.label,
      onclick: () => {
        wrap.dataset.selected = token;
        for (const b of wrap.children) b.classList.toggle('selected', b === sw);
      },
    }, el('span', { class: 'color-dot' }), el('span', { class: 'color-name' }, meta.label));
    sw.firstChild.style.background = Calendar.colorVar(token);
    wrap.appendChild(sw);
  }
}

// Quarter-hour selects for the event modal (mirrors the entry modal's pattern;
// kept separate so the two modals can be open-independent and 24h-aware).
function populateEventTimeSelects() {
  for (const prefix of ['evStart', 'evEnd']) {
    const hourSel = $(prefix + 'Hour');
    const minSel = $(prefix + 'Min');
    const ampmSel = $(prefix + 'AmPm');
    hourSel.innerHTML = '';
    minSel.innerHTML = '';
    ampmSel.innerHTML = '';
    if (state.use24h) {
      for (let h = 0; h < 24; h++) {
        hourSel.appendChild(el('option', { value: h }, String(h).padStart(2, '0')));
      }
      ampmSel.style.display = 'none';
    } else {
      for (let h = 1; h <= 12; h++) {
        hourSel.appendChild(el('option', { value: h }, String(h)));
      }
      ampmSel.appendChild(el('option', { value: 'AM' }, 'AM'));
      ampmSel.appendChild(el('option', { value: 'PM' }, 'PM'));
      ampmSel.style.display = '';
    }
    for (const m of [0, 15, 30, 45]) {
      minSel.appendChild(el('option', { value: m }, ':' + String(m).padStart(2, '0')));
    }
  }
}

function setEventTimeSelect(prefix, minutes) {
  const h24 = Math.floor(minutes / 60) % 24;
  const snap = Math.round((minutes % 60) / 15) * 15 % 60;
  $(prefix + 'Min').value = String(snap);
  if (state.use24h) {
    $(prefix + 'Hour').value = String(h24);
  } else {
    const ampm = h24 >= 12 ? 'PM' : 'AM';
    let h12 = h24 % 12; if (h12 === 0) h12 = 12;
    $(prefix + 'Hour').value = String(h12);
    $(prefix + 'AmPm').value = ampm;
  }
}

function readEventTimeSelect(prefix) {
  let h = parseInt($(prefix + 'Hour').value, 10);
  const m = parseInt($(prefix + 'Min').value, 10);
  if (!state.use24h) {
    const ampm = $(prefix + 'AmPm').value;
    if (ampm === 'PM' && h !== 12) h += 12;
    if (ampm === 'AM' && h === 12) h = 0;
  }
  return h * 60 + m;
}

async function saveEventFromModal() {
  const scope = state.editScope || 'new';
  const d = state.editingDate;
  const title = $('eventTitle').value.trim();
  if (!title) { showToast('Give the event a title'); return; }

  const backlog = $('eventBacklog').checked && !$('eventBacklogRow').hidden;
  const allDay = $('eventAllDay').checked;
  let startMin = null, endMin = null;
  if (!backlog && !allDay) {
    startMin = readEventTimeSelect('evStart');
    endMin = readEventTimeSelect('evEnd');
    if (endMin <= startMin) { showToast('End must be after start'); return; }
  }
  const color = $('eventColorSwatches').dataset.selected || DEFAULT_EVENT_COLOR;
  const location = $('eventLocation').value.trim();
  const notes = $('eventNotes').value.trim();

  // Repeat -> rrule (only when the repeat controls are in play).
  let rrule = null;
  if (!$('eventRepeatFields').hidden) {
    rrule = readRepeatControls();
  }

  const fields = { title, allDay, startMin, endMin, color, location, notes };

  try {
    if (scope === 'this') {
      // Edit one occurrence -> exclude it from the series and write a concrete
      // override event on that date.
      const series = await DB.getEvent(state.editingEvent._occurrenceOf);
      if (series) {
        const ex = Array.isArray(series.exdates) ? series.exdates.slice() : [];
        if (!ex.includes(d)) ex.push(d);
        await DB.upsertEvent({ ...series, exdates: ex });
      }
      await DB.upsertEvent({ ...fields, date: d, rrule: null,
        seriesId: state.editingEvent._occurrenceOf, needsScheduling: false });
    } else if (scope === 'all') {
      // Edit the whole series row (keep its anchor date + exdates).
      const base = state.editingEvent || {};
      await DB.upsertEvent({
        ...base, ...fields,
        id: base.id || base._occurrenceOf,
        date: base._seriesDate || base.date,
        rrule,
        needsScheduling: false,
      });
    } else if (scope === 'following') {
      // Split the series at this occurrence: truncate the original to end the
      // day before, then start a NEW series here carrying the edited fields +
      // recurrence. Future exdates move to the new series; past ones stay.
      const series = await DB.getEvent(state.editingEvent._occurrenceOf);
      if (series) {
        const past = (series.exdates || []).filter(x => x < d);
        const future = (series.exdates || []).filter(x => x >= d);
        await DB.upsertEvent({
          ...series, rrule: truncateRRuleBefore(series.rrule, d), exdates: past,
        });
        await DB.upsertEvent({ ...fields, date: d, rrule, exdates: future, needsScheduling: false });
      } else {
        await DB.upsertEvent({ ...fields, date: d, rrule, needsScheduling: false });
      }
    } else {
      // 'new' or 'single'
      const base = (state.editingEvent && state.editingEvent.id) ? state.editingEvent : {};
      await DB.upsertEvent({
        ...base, ...fields,
        date: backlog ? null : d,
        needsScheduling: backlog,
        rrule: backlog ? null : rrule,
      });
    }
    await DB.recordEventHistory(title, color);
  } catch (err) {
    console.error(err);
    showToast('Save failed: ' + err.message);
    return;
  }
  closeEventModal();
  showToast('Event saved');
  await renderAll();
}

async function deleteEventFromModal() {
  const ev = state.editingEvent;
  const scope = state.editScope;
  const d = state.editingDate;
  if (!ev) { closeEventModal(); return; }
  try {
    if (scope === 'this' && ev._occurrenceOf) {
      const series = await DB.getEvent(ev._occurrenceOf);
      if (series) {
        const ex = Array.isArray(series.exdates) ? series.exdates.slice() : [];
        if (!ex.includes(d)) ex.push(d);
        await DB.upsertEvent({ ...series, exdates: ex });
      }
    } else if (scope === 'all' && (ev._occurrenceOf || ev.id)) {
      await DB.deleteEventAndSync(ev._occurrenceOf || ev.id);
    } else if (ev.id) {
      await DB.deleteEventAndSync(ev.id);
    }
  } catch (err) {
    console.error(err);
    showToast('Delete failed: ' + err.message);
    return;
  }
  closeEventModal();
  showToast('Event deleted');
  await renderAll();
}

// "This event / All events" chooser for a recurring occurrence. `action` is
// 'edit' or 'delete'. On choice we set the scope and either open the editor or
// perform the delete.
let pendingRecur = null;
function openRecurringChoice(action, ev, dateStr, afterRender) {
  pendingRecur = { action, ev, dateStr, afterRender };
  $('recurChoiceTitle').textContent = action === 'delete' ? 'Delete repeating event' : 'Edit repeating event';
  $('recurChoiceText').textContent = action === 'delete'
    ? 'This event repeats. Delete:'
    : 'This event repeats. Edit:';
  $('recurChoiceModal').hidden = false;
}
async function resolveRecurChoice(which) {
  const ctx = pendingRecur;
  $('recurChoiceModal').hidden = true;
  pendingRecur = null;
  if (!ctx) return;
  if (ctx.action === 'edit') {
    if (which === 'this') {
      openEventModal(ctx.dateStr, ctx.ev, 'this');
    } else if (which === 'following') {
      // Edit this occurrence onward: open prefilled from the occurrence; the
      // save handler splits the series.
      openEventModal(ctx.dateStr, ctx.ev, 'following');
    } else {
      // Edit the series: rebuild the anchor row from the occurrence clone.
      const series = await DB.getEvent(ctx.ev._occurrenceOf) || ctx.ev;
      openEventModal(series.date, series, 'all');
    }
    return;
  }
  // delete
  if (which === 'this') {
    const series = await DB.getEvent(ctx.ev._occurrenceOf);
    if (series) {
      const ex = Array.isArray(series.exdates) ? series.exdates.slice() : [];
      if (!ex.includes(ctx.dateStr)) ex.push(ctx.dateStr);
      await DB.upsertEvent({ ...series, exdates: ex });
    }
  } else if (which === 'following') {
    // Delete this occurrence onward: truncate the series to end the day before.
    const series = await DB.getEvent(ctx.ev._occurrenceOf);
    if (series) {
      const past = (series.exdates || []).filter(x => x < ctx.dateStr);
      await DB.upsertEvent({
        ...series, rrule: truncateRRuleBefore(series.rrule, ctx.dateStr), exdates: past,
      });
    }
  } else {
    await DB.deleteEventAndSync(ctx.ev._occurrenceOf || ctx.ev.id);
  }
  showToast('Event deleted');
  if (ctx.afterRender) ctx.afterRender(); else await renderAll();
}

// Day-editor Events section (calendar mode only): a list of the day's events
// with edit/delete, plus the "+ Add Event" button (wired globally).
async function renderEventSection(dateStr) {
  const section = $('eventSection');
  if (!state.calendarMode) { section.hidden = true; return; }
  section.hidden = false;
  const list = $('eventList');
  list.innerHTML = '';
  const events = await resolveEventsForDay(dateStr);
  events.sort((a, b) => {
    if (a.allDay !== b.allDay) return a.allDay ? -1 : 1;
    return (a.startMin || 0) - (b.startMin || 0);
  });
  if (events.length === 0) {
    list.appendChild(el('div', { class: 'entry-card' },
      el('div', { class: 'entry-meta' }, 'No events for this day.')));
    return;
  }
  for (const ev of events) {
    const when = ev.allDay
      ? 'All day'
      : `${T.formatMinutes(ev.startMin, state.use24h)} – ${T.formatMinutes(ev.endMin, state.use24h)}`;
    const dot = el('span', { class: 'ev-dot' });
    dot.style.background = Calendar.colorVar(ev.color);
    const recurs = !!(ev._occurrenceOf || ev.rrule);
    list.appendChild(el('div', { class: 'entry-card' },
      el('div', {},
        el('div', { class: 'entry-times' }, dot, ev.title || '(untitled)',
          recurs ? el('span', { class: 'ev-repeat-tag', title: 'Repeating event' }, '↻') : null),
        el('div', { class: 'entry-meta' },
          when + (ev.location ? ` · ${ev.location}` : '')),
      ),
      el('div', { class: 'entry-actions' },
        el('button', { onclick: () => editCalEvent(ev, dateStr) }, 'Edit'),
        el('button', {
          class: 'danger',
          onclick: () => deleteCalEvent(ev, dateStr, () => renderDayView()),
        }, 'Delete'),
      ),
    ));
  }
}

// --- Kick off ---------------------------------------------------------------

// Scripts are at end of <body>, so DOMContentLoaded may have already fired by
// the time we get here. Call init immediately if so, otherwise wait.
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

})(); // end IIFE
