// time.js — pure time / pay-period / pacing / overtime helpers
// No DOM, no DB. All functions are pure so they can be reasoned about easily.

const MS_PER_MIN = 60 * 1000;
const MS_PER_HOUR = 60 * MS_PER_MIN;
const MS_PER_DAY = 24 * MS_PER_HOUR;
const QUARTER_MIN = 15;
const LUNCH_THRESHOLD_HOURS = 4;
const LUNCH_DEDUCT_HOURS = 0.5;
const FORGOTTEN_CUTOFF_HOURS = 16;
const PAY_PERIOD_DAYS = 14;
const PAY_PERIOD_TARGET = 80;
const DAILY_OT_THRESHOLD = 8;
// FLSA standard: overtime is paid at 1.5× the straight-time rate.
const OT_MULTIPLIER = 1.5;
// Worked federal holidays flagged "holiday worked" pay at 2× (double time).
const HOLIDAY_MULTIPLIER = 2;
// User's example: pay period ending 12/27/2025 had paydate 1/8/2026 (= +12 days).
// This is the lag between period-end and check-date used for YTD bucketing.
const PAYDATE_OFFSET_DAYS = 12;
// Max credit hours a full-time employee may carry into the next pay period under
// a flexible work schedule (OPM credit-hours rule). Anything over this at period
// end is forfeited. See LOGIC-FREEZE §4.6.
const CREDIT_CARRYOVER_CAP = 24;

// Per-entry pay classification for Maxiflex mode (LOGIC-FREEZE §4.3). 8-hour
// mode ignores this — its OT is purely schedule-based.
//   auto       — engine decides; beyond-schedule (over-80) hours pay overtime. Default.
//   autoCredit — like auto, but those hours bank as credit (1:1, no premium).
//   overtime   — force the WHOLE entry to overtime (ordered OT).
//   credit     — force the WHOLE entry to credit hours.
//   regular    — force the WHOLE entry to regular (never premium).
const PAY_KINDS = ['auto', 'autoCredit', 'overtime', 'credit', 'regular'];

// Resolve an entry's payKind, bridging the legacy `isOvertime` boolean: a stored
// payKind wins; otherwise true→overtime, false/absent→auto. Mirrors the iOS
// `EntryRecord.isOvertime` bridge so old rows + CSVs keep classifying correctly.
function payKindForEntry(e) {
  if (e && PAY_KINDS.includes(e.payKind)) return e.payKind;
  return (e && e.isOvertime) ? 'overtime' : 'auto';
}

// Round a Date (or timestamp) to the nearest 15 minutes. Returns a new Date.
function roundToQuarter(date) {
  const d = new Date(date);
  const minutes = d.getMinutes();
  const rounded = Math.round(minutes / QUARTER_MIN) * QUARTER_MIN;
  d.setMinutes(rounded, 0, 0);
  return d;
}

// Decimal hours between start and end, with lunch deduction.
// `lunchMinutes` semantics:
//   - undefined / null → apply default rule: 30 min if span ≥ 4 h, else 0.
//   - explicit number  → use as-is (lets the user override the default).
// Returns { hours, lunchMinutes, lunchDeducted, rawHours }.
function hoursForEntry(startTime, endTime, lunchMinutes) {
  if (!startTime || !endTime) return { hours: 0, lunchMinutes: 0, lunchDeducted: false, rawHours: 0 };
  const start = new Date(startTime);
  const end = new Date(endTime);
  const rawHours = (end - start) / MS_PER_HOUR;
  if (rawHours <= 0) return { hours: 0, lunchMinutes: 0, lunchDeducted: false, rawHours: 0 };
  let lm;
  if (lunchMinutes == null) {
    lm = rawHours >= LUNCH_THRESHOLD_HOURS ? LUNCH_DEDUCT_HOURS * 60 : 0;
  } else {
    lm = Math.max(0, Number(lunchMinutes) || 0);
  }
  const hours = Math.max(0, rawHours - lm / 60);
  return { hours, lunchMinutes: lm, lunchDeducted: lm > 0, rawHours };
}

// True if an in-progress entry has been open > 16 hours.
function isForgotten(startTime, now = new Date()) {
  const start = new Date(startTime);
  return (now - start) / MS_PER_HOUR > FORGOTTEN_CUTOFF_HOURS;
}

// Parse "YYYY-MM-DD" as a local Date at midnight (not UTC!).
function parseLocalDate(yyyymmdd) {
  const [y, m, d] = yyyymmdd.split('-').map(Number);
  return new Date(y, m - 1, d);
}

// Format a Date as "YYYY-MM-DD" in local time.
function formatLocalDate(date) {
  const d = new Date(date);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

// Given an anchor Sunday and today, return the current pay-period window.
// Returns { start: Date, end: Date, dayIndex: 0..13, days: ["YYYY-MM-DD", x14] }.
function payPeriodFor(today, anchorDateStr) {
  const anchor = parseLocalDate(anchorDateStr);
  const t = new Date(today);
  t.setHours(0, 0, 0, 0);
  const diffDays = Math.floor((t - anchor) / MS_PER_DAY);
  const periodIndex = Math.floor(diffDays / PAY_PERIOD_DAYS);
  const start = new Date(anchor);
  start.setDate(anchor.getDate() + periodIndex * PAY_PERIOD_DAYS);
  const end = new Date(start);
  end.setDate(start.getDate() + PAY_PERIOD_DAYS - 1);
  const dayIndex = Math.floor((t - start) / MS_PER_DAY);
  const days = [];
  for (let i = 0; i < PAY_PERIOD_DAYS; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    days.push(formatLocalDate(d));
  }
  return { start, end, dayIndex, days };
}

// Check that a YYYY-MM-DD string is a Sunday.
function isSunday(yyyymmdd) {
  return parseLocalDate(yyyymmdd).getDay() === 0;
}

// Return a pay period offset N periods from the one containing `today`.
// offset 0 = current, -1 = previous, +1 = next, etc.
function payPeriodOffset(today, anchorDateStr, offset) {
  const base = payPeriodFor(today, anchorDateStr);
  const start = new Date(base.start);
  start.setDate(base.start.getDate() + offset * PAY_PERIOD_DAYS);
  return payPeriodFor(start, anchorDateStr);
}

// Pay-period name "YYYY-PPNN".
// YYYY = the year the period starts in.
// NN   = sequential index within that year (PP01 = first anchor-aligned period whose
//        start date is on/after Jan 1 of YYYY).
// E.g. with anchor 2026-04-19 (Sun): that period is 2026-PP08, the 14-day period
// ending 2025-12-27 is 2025-PP25.
function payPeriodName(period, anchorDateStr) {
  const startYear = period.start.getFullYear();
  const anchor = parseLocalDate(anchorDateStr);
  const yearStart = new Date(startYear, 0, 1);
  // Both dates are local-midnight, but a DST transition inside the range makes
  // the raw ms difference off by ±1h. Round to whole days first so ceil/round
  // operate on a clean integer.
  const diffDays = Math.round((yearStart - anchor) / MS_PER_DAY);
  // First anchor-aligned period start that's >= yearStart.
  const periodsFromAnchor = Math.ceil(diffDays / PAY_PERIOD_DAYS);
  const firstOfYear = new Date(anchor);
  firstOfYear.setDate(anchor.getDate() + periodsFromAnchor * PAY_PERIOD_DAYS);
  const ppNum = Math.round((period.start - firstOfYear) / (PAY_PERIOD_DAYS * MS_PER_DAY)) + 1;
  return `${startYear}-PP${String(ppNum).padStart(2, '0')}`;
}

// Paydate for a period: period.end + PAYDATE_OFFSET_DAYS. (Used for YTD bucketing —
// a period that runs late-Dec into early-Jan can have its check fall in the next year.)
function paydateFor(period) {
  const d = new Date(period.end);
  d.setDate(d.getDate() + PAYDATE_OFFSET_DAYS);
  d.setHours(0, 0, 0, 0);
  return d;
}

// Calendar year of the paydate — the year this period's earnings count toward.
function paydateYear(period) {
  return paydateFor(period).getFullYear();
}

// Average hours per remaining day to finish the period on target.
function pace(hoursWorked, daysRemaining, target = PAY_PERIOD_TARGET) {
  const remaining = Math.max(0, target - hoursWorked);
  if (daysRemaining <= 0) return 0;
  return remaining / daysRemaining;
}

// Expected hours by end of dayIndex (0-based, so dayIndex 0 = end of day 1).
function expectedByDay(dayIndex) {
  return PAY_PERIOD_TARGET * (dayIndex + 1) / PAY_PERIOD_DAYS;
}

// Status badge: 'ahead' | 'on-pace' | 'behind' with a 2h deadband.
function paceStatus(hoursWorked, dayIndex) {
  const expected = expectedByDay(dayIndex);
  if (hoursWorked > expected + 2) return 'ahead';
  if (hoursWorked < expected - 2) return 'behind';
  return 'on-pace';
}

// --- Credit-hour bank (Phase 2, LOGIC-FREEZE §4.6) -------------------------
// Fold per-period credit into a running balance, applying the carryover cap at
// each period boundary. Each period contributes `earned` (credit accrued) and
// `used` (credit spent as time off); balance = carryIn + earned − used. Input
// MUST be chronological (oldest first). Pure. Mirrors iOS `creditBankFold`.
// A period with no earn/spend just passes its (already ≤ cap) carry-in through,
// so callers can fold over only credit-relevant periods — inert ones are no-ops.
function creditBankFold(byPeriod, cap = CREDIT_CARRYOVER_CAP) {
  let carryIn = 0;
  const out = [];
  for (const p of byPeriod) {
    const earned = Number(p.earned) || 0;
    const used = Number(p.used) || 0;
    const balance = carryIn + earned - used;
    const carryOut = Math.min(cap, Math.max(0, balance));  // never negative or over cap
    const lost = Math.max(0, balance - cap);
    out.push({ start: p.start, carryIn, earned, used, balance, carryOut, lost });
    carryIn = carryOut;
  }
  return out;
}

// The bank slot for a given period start: the matching folded slot, or a
// synthesized carry-in-only slot for a credit-inert period not in the list.
function creditBankSlot(start, folded, cap = CREDIT_CARRYOVER_CAP) {
  const exact = folded.find(s => s.start === start);
  if (exact) return exact;
  const before = folded.filter(s => s.start < start);
  const carryIn = before.length ? before[before.length - 1].carryOut : 0;
  return { start, carryIn, earned: 0, used: 0, balance: carryIn,
           carryOut: Math.min(cap, carryIn), lost: 0 };
}

// If clocked in at clockInTime, when do we clock out to book targetHours paid?
// Accounts for 30-min lunch deduction if the resulting span would be >= 4h.
function projectedClockOut(clockInTime, targetHours) {
  const start = new Date(clockInTime);
  // Try WITH lunch first: clocked span = targetHours + 0.5
  const withLunchEnd = new Date(start.getTime() + (targetHours + LUNCH_DEDUCT_HOURS) * MS_PER_HOUR);
  const withLunchSpan = (withLunchEnd - start) / MS_PER_HOUR;
  if (withLunchSpan >= LUNCH_THRESHOLD_HOURS) return withLunchEnd;
  // Otherwise the target is short enough that no lunch is deducted: span = targetHours
  return new Date(start.getTime() + targetHours * MS_PER_HOUR);
}

// Split a day's total worked hours into { regular, overtime } if 8h mode is on.
// Leave is not overtime-eligible and is passed separately.
// `isWeekend` true → ALL the day's worked hours are overtime (federal
// maxiflex: Saturday/Sunday work is entirely overtime).
function overtimeSplit(workedHours, otModeEnabled, isWeekend = false) {
  if (!otModeEnabled) return { regular: workedHours, overtime: 0 };
  if (isWeekend) return { regular: 0, overtime: workedHours };
  if (workedHours <= DAILY_OT_THRESHOLD) return { regular: workedHours, overtime: 0 };
  return { regular: DAILY_OT_THRESHOLD, overtime: workedHours - DAILY_OT_THRESHOLD };
}

// Maxiflex per-day overtime: the hours worked beyond that day's *scheduled*
// hours (i.e. time worked outside the default schedule), counted as OT only
// when the period as a whole has more than 80 worked hours. Explicit per-entry
// OT and holiday-worked OT are handled separately by the caller and added on
// top. `dayRegularWorked` should EXCLUDE hours already counted as explicit OT.
function maxiflexDayOvertime(dayRegularWorked, dayScheduledHours, periodOver80) {
  if (!periodOver80) return 0;
  return Math.max(0, dayRegularWorked - (dayScheduledHours || 0));
}

// Pretty-print decimal hours. Quarter-hour values render exactly (0.25/0.5/0.75),
// arbitrary floats (like pace) keep up to 2 decimals with trailing zeros trimmed.
// So: 0.75 → "0.75", 0.5 → "0.5", 8 → "8", 0.8333 → "0.83".
function formatHours(n) {
  if (!isFinite(n) || n === 0) return '0';
  const rounded = Math.round(n * 100) / 100;
  return rounded.toFixed(2).replace(/\.?0+$/, '') || '0';
}

// Leave label from minutes. Whole-hour mode → "1"; granular → "1:15" for
// quarter-hour values, "1" on the hour. Mirrors iOS `leaveLabel`.
function leaveLabelText(minutes, granular) {
  const m = Math.max(0, Math.round(minutes || 0));
  const h = Math.floor(m / 60), rem = m % 60;
  if (granular && rem !== 0) return h + ':' + String(rem).padStart(2, '0');
  return String(h);
}

// Format a number as "$1,234.56".
function formatMoney(n) {
  if (!isFinite(n)) return '$0.00';
  const sign = n < 0 ? '-' : '';
  const abs = Math.abs(n);
  return sign + '$' + abs.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

// Format a Date as "h:mm AM/PM" (12h) or "HH:mm" (24h) in local time.
function formatTime(date, use24h = false) {
  const d = new Date(date);
  const h = d.getHours();
  const m = d.getMinutes();
  if (use24h) {
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
  }
  const ampm = h >= 12 ? 'PM' : 'AM';
  let h12 = h % 12;
  if (h12 === 0) h12 = 12;
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`;
}

// Convert minutes-since-midnight to a display string honoring 24h mode.
function formatMinutes(mins, use24h = false) {
  const h = Math.floor(mins / 60) % 24;
  const m = mins % 60;
  if (use24h) return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
  const ampm = h >= 12 ? 'PM' : 'AM';
  let h12 = h % 12;
  if (h12 === 0) h12 = 12;
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`;
}

// Format a YYYY-MM-DD as a short "Mon, Apr 21" style string.
function formatDateShort(yyyymmdd) {
  const d = parseLocalDate(yyyymmdd);
  return d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
}

// Build a quarter-hour Date on a given YYYY-MM-DD, given hour (0-23) and quarter (0,15,30,45).
function buildDateTime(yyyymmdd, hour24, minute) {
  const d = parseLocalDate(yyyymmdd);
  d.setHours(hour24, minute, 0, 0);
  return d;
}

// --- Federal holidays -------------------------------------------------------
// The 11 U.S. federal holidays, computed for any year (OPM rules). Fixed-date
// holidays shift to the nearest weekday when they fall on a weekend (Saturday →
// Friday, Sunday → Monday) — that's the "observed" date, which is what's
// actually off. Floating Monday/Thursday holidays never shift.

// nth (1-based) `weekday` (0=Sun..6=Sat) of month0 (0=Jan..11=Dec) in `year`.
function nthWeekdayOfMonth(year, month0, weekday, n) {
  const first = new Date(year, month0, 1);
  const shift = (weekday - first.getDay() + 7) % 7;
  return new Date(year, month0, 1 + shift + (n - 1) * 7);
}
// Last `weekday` of the month.
function lastWeekdayOfMonth(year, month0, weekday) {
  const last = new Date(year, month0 + 1, 0);
  const shift = (last.getDay() - weekday + 7) % 7;
  return new Date(year, month0, last.getDate() - shift);
}
// Observed date for a fixed-date holiday (weekend → nearest weekday).
function observedDate(year, month0, day) {
  const d = new Date(year, month0, day);
  const dow = d.getDay();
  if (dow === 6) d.setDate(d.getDate() - 1);        // Saturday → Friday
  else if (dow === 0) d.setDate(d.getDate() + 1);   // Sunday → Monday
  return d;
}

// All federal holidays for `year` → [{ date: 'YYYY-MM-DD', name }], sorted.
// Fixed-date names get " (observed)" appended when the off-day was shifted.
function federalHolidays(year) {
  const list = [];
  const fixed = [
    [0, 1, "New Year's Day"],
    [5, 19, 'Juneteenth National Independence Day'],
    [6, 4, 'Independence Day'],
    [10, 11, 'Veterans Day'],
    [11, 25, 'Christmas Day'],
  ];
  for (const [m, day, name] of fixed) {
    const actual = new Date(year, m, day);
    const obs = observedDate(year, m, day);
    const shifted = obs.getTime() !== actual.getTime();
    list.push({ date: formatLocalDate(obs), name: name + (shifted ? ' (observed)' : '') });
  }
  const floating = [
    [nthWeekdayOfMonth(year, 0, 1, 3), 'Birthday of Martin Luther King, Jr.'],
    [nthWeekdayOfMonth(year, 1, 1, 3), "Washington's Birthday"],
    [lastWeekdayOfMonth(year, 4, 1), 'Memorial Day'],
    [nthWeekdayOfMonth(year, 8, 1, 1), 'Labor Day'],
    [nthWeekdayOfMonth(year, 9, 1, 2), 'Columbus Day'],
    [nthWeekdayOfMonth(year, 10, 4, 4), 'Thanksgiving Day'],
  ];
  for (const [d, name] of floating) list.push({ date: formatLocalDate(d), name });
  list.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  return list;
}

// --- iCalendar (.ics) export ------------------------------------------------
// Escape a value for an ICS text field (RFC 5545): backslash, semicolon, comma,
// and newline are escaped.
function icsEscape(s) {
  return String(s)
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');
}

// Fold a content line to <= 75 octets per RFC 5545 (continuation lines start
// with a single space). We fold on character count, which is a safe upper
// bound for the ASCII content we emit.
function foldIcsLine(line) {
  if (line.length <= 75) return line;
  let out = line.slice(0, 75);
  let rest = line.slice(75);
  while (rest.length > 74) {
    out += '\r\n ' + rest.slice(0, 74);
    rest = rest.slice(74);
  }
  return out + '\r\n ' + rest;
}

// Build an iCalendar (.ics) document from the 14-slot default schedule.
// Each configured day-of-period slot becomes a BIWEEKLY-recurring event,
// anchored to its first occurrence inside `periodStart`'s pay period:
//   - an enabled work slot  → a timed event at the slot's clock in/out times
//   - leaveHours > 0        → an all-day "Leave (Nh)" event
// Because day-of-period i and i+7 fall on the same weekday but in opposite
// weeks, two biweekly events for the same weekday interleave to cover both
// weeks correctly when week 1 and week 2 differ.
//
// Times are emitted as floating local time (no TZ / no "Z"), which matches how
// the schedule is entered and how the user reads the clock — calendar apps
// interpret floating times in the viewer's own time zone.
function buildScheduleIcs(schedule, periodStart, opts = {}) {
  const calName = opts.calName || 'Maxiflex Work Schedule';
  const workSummary = opts.workSummary || 'Work';
  const pad = (n) => String(n).padStart(2, '0');
  const fmtLocal = (d) =>
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}T${pad(d.getHours())}${pad(d.getMinutes())}00`;
  const fmtDate = (d) =>
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
  const now = new Date();
  const dtstamp = `${now.getUTCFullYear()}${pad(now.getUTCMonth() + 1)}${pad(now.getUTCDate())}` +
    `T${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}${pad(now.getUTCSeconds())}Z`;
  // SEQUENCE must strictly increase across revisions so a re-import of the same
  // UID is treated as an UPDATE (not skipped or duplicated) by compliant clients
  // like Google Calendar. Minutes-since-epoch is monotonic and stays well under
  // the 32-bit integer ceiling for centuries.
  const seq = Math.floor(now.getTime() / 60000);

  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Timecard App//Maxiflex Schedule//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:' + icsEscape(calName),
  ];

  const start = new Date(periodStart);
  start.setHours(0, 0, 0, 0);

  for (let i = 0; i < PAY_PERIOD_DAYS; i++) {
    const slot = schedule[i];
    if (!slot) continue;
    const day = new Date(start);
    day.setDate(start.getDate() + i);

    // Timed work event for enabled slots with a valid span.
    if (slot.enabled !== false && isFinite(slot.startMin) && isFinite(slot.endMin) &&
        slot.endMin > slot.startMin) {
      const s = new Date(day);
      s.setHours(Math.floor(slot.startMin / 60), slot.startMin % 60, 0, 0);
      const e = new Date(day);
      e.setHours(Math.floor(slot.endMin / 60), slot.endMin % 60, 0, 0);
      lines.push(
        'BEGIN:VEVENT',
        `UID:tc-sched-work-${i}@timecard-app`,
        'DTSTAMP:' + dtstamp,
        'SEQUENCE:' + seq,
        'DTSTART:' + fmtLocal(s),
        'DTEND:' + fmtLocal(e),
        'RRULE:FREQ=WEEKLY;INTERVAL=2',
        'SUMMARY:' + icsEscape(workSummary),
        'END:VEVENT',
      );
    }

    // All-day recurring leave for slots carrying recurring leave hours.
    const lv = Math.max(0, Math.round(Number(slot.leaveHours) || 0));
    if (lv > 0) {
      const next = new Date(day);
      next.setDate(day.getDate() + 1);
      lines.push(
        'BEGIN:VEVENT',
        `UID:tc-sched-leave-${i}@timecard-app`,
        'DTSTAMP:' + dtstamp,
        'SEQUENCE:' + seq,
        'DTSTART;VALUE=DATE:' + fmtDate(day),
        'DTEND;VALUE=DATE:' + fmtDate(next),
        'RRULE:FREQ=WEEKLY;INTERVAL=2',
        'SUMMARY:' + icsEscape(`Leave (${lv}h)`),
        'END:VEVENT',
      );
    }
  }

  lines.push('END:VCALENDAR');
  return lines.map(foldIcsLine).join('\r\n') + '\r\n';
}

// Materialize the default schedule into concrete, dated events for a LIMITED
// forward window — `periodsAhead` whole pay periods starting at `periodStartStr`
// (the current period's start). Used by the optional work-schedule → calendar
// sync: unlike `buildScheduleIcs` (which emits infinite biweekly RRULE series),
// this produces one plain, non-recurring item per scheduled day so the calendar
// never carries the schedule beyond the window. The caller re-runs this each
// sync and reconciles (insert/patch/delete) against the previous result, so the
// window rolls forward and prunes days that fall out of it.
//
// Returns [{ key, date, allDay, startMin, endMin, title }]:
//   - enabled work slot → a timed "Work" item (`w:<date>`)
//   - slot leaveHours>0 → an all-day "Leave (Nh)" item (`l:<date>`)
//   - a recorded holiday → an all-day "Holiday" item and NO work that day
//     (mirrors applyDefaultSchedule's holiday override)
// `holidays` is the { [YYYY-MM-DD]: { name, doubleTime } } map.
function buildScheduleSyncEvents(schedule, periodStartStr, periodsAhead, holidays, opts = {}) {
  opts = opts || {};
  const workSummary = opts.workSummary || 'Work';
  holidays = holidays || {};
  const out = [];
  if (!Array.isArray(schedule)) return out;
  const start = parseLocalDate(periodStartStr);
  start.setHours(0, 0, 0, 0);
  const periods = Math.max(1, periodsAhead | 0);
  const totalDays = PAY_PERIOD_DAYS * periods;
  for (let n = 0; n < totalDays; n++) {
    const i = n % PAY_PERIOD_DAYS;        // day-of-period index (0..13)
    const d = new Date(start);
    d.setDate(start.getDate() + n);
    const dateStr = formatLocalDate(d);
    const hol = holidays[dateStr];
    if (hol) {
      out.push({ key: 'h:' + dateStr, date: dateStr, allDay: true, startMin: null, endMin: null,
        title: 'Holiday' + (hol && hol.name ? ' — ' + hol.name : '') });
      continue;                            // no work on a recorded holiday
    }
    const slot = schedule[i];
    if (!slot) continue;
    if (slot.enabled !== false && isFinite(slot.startMin) && isFinite(slot.endMin) &&
        slot.endMin > slot.startMin) {
      out.push({ key: 'w:' + dateStr, date: dateStr, allDay: false,
        startMin: slot.startMin | 0, endMin: slot.endMin | 0, title: workSummary });
    }
    const lv = Math.max(0, Math.round(Number(slot.leaveHours) || 0));
    if (lv > 0) {
      out.push({ key: 'l:' + dateStr, date: dateStr, allDay: true, startMin: null, endMin: null,
        title: `Leave (${lv}h)` });
    }
  }
  return out;
}

// Exported as globals (no module system — simple PWA)
window.TimeUtil = {
  roundToQuarter,
  hoursForEntry,
  leaveLabelText,
  isForgotten,
  parseLocalDate,
  formatLocalDate,
  payPeriodFor,
  payPeriodOffset,
  payPeriodName,
  paydateFor,
  paydateYear,
  isSunday,
  pace,
  expectedByDay,
  paceStatus,
  projectedClockOut,
  overtimeSplit,
  maxiflexDayOvertime,
  payKindForEntry,
  formatHours,
  formatMoney,
  formatTime,
  formatMinutes,
  formatDateShort,
  buildDateTime,
  federalHolidays,
  buildScheduleIcs,
  buildScheduleSyncEvents,
  icsEscape,
  foldIcsLine,
  PAY_PERIOD_DAYS,
  PAY_PERIOD_TARGET,
  DAILY_OT_THRESHOLD,
  LUNCH_DEDUCT_HOURS,
  LUNCH_THRESHOLD_HOURS,
  FORGOTTEN_CUTOFF_HOURS,
  OT_MULTIPLIER,
  HOLIDAY_MULTIPLIER,
  PAYDATE_OFFSET_DAYS,
  PAY_KINDS,
  CREDIT_CARRYOVER_CAP,
  creditBankFold,
  creditBankSlot,
};
