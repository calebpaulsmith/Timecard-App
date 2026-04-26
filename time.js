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

// Round a Date (or timestamp) to the nearest 15 minutes. Returns a new Date.
function roundToQuarter(date) {
  const d = new Date(date);
  const minutes = d.getMinutes();
  const rounded = Math.round(minutes / QUARTER_MIN) * QUARTER_MIN;
  d.setMinutes(rounded, 0, 0);
  return d;
}

// Decimal hours between start and end, with 30-min lunch deduction if span >= 4h.
// Returns { hours, lunchDeducted, rawHours }.
function hoursForEntry(startTime, endTime) {
  if (!startTime || !endTime) return { hours: 0, lunchDeducted: false, rawHours: 0 };
  const start = new Date(startTime);
  const end = new Date(endTime);
  const rawHours = (end - start) / MS_PER_HOUR;
  if (rawHours <= 0) return { hours: 0, lunchDeducted: false, rawHours: 0 };
  const lunchDeducted = rawHours >= LUNCH_THRESHOLD_HOURS;
  const hours = lunchDeducted ? rawHours - LUNCH_DEDUCT_HOURS : rawHours;
  return { hours, lunchDeducted, rawHours };
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
function overtimeSplit(workedHours, otModeEnabled) {
  if (!otModeEnabled) return { regular: workedHours, overtime: 0 };
  if (workedHours <= DAILY_OT_THRESHOLD) return { regular: workedHours, overtime: 0 };
  return { regular: DAILY_OT_THRESHOLD, overtime: workedHours - DAILY_OT_THRESHOLD };
}

// Pretty-print decimal hours to 1 decimal (trim trailing .0).
function formatHours(n) {
  if (n === 0) return '0';
  const rounded = Math.round(n * 10) / 10;
  return rounded.toFixed(1);
}

// Format a Date as "h:mm AM/PM" in local time.
function formatTime(date) {
  const d = new Date(date);
  let h = d.getHours();
  const m = d.getMinutes();
  const ampm = h >= 12 ? 'PM' : 'AM';
  h = h % 12;
  if (h === 0) h = 12;
  return `${h}:${String(m).padStart(2, '0')} ${ampm}`;
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

// Exported as globals (no module system — simple PWA)
window.TimeUtil = {
  roundToQuarter,
  hoursForEntry,
  isForgotten,
  parseLocalDate,
  formatLocalDate,
  payPeriodFor,
  isSunday,
  pace,
  expectedByDay,
  paceStatus,
  projectedClockOut,
  overtimeSplit,
  formatHours,
  formatTime,
  formatDateShort,
  buildDateTime,
  PAY_PERIOD_DAYS,
  PAY_PERIOD_TARGET,
  DAILY_OT_THRESHOLD,
  LUNCH_DEDUCT_HOURS,
  LUNCH_THRESHOLD_HOURS,
  FORGOTTEN_CUTOFF_HOURS,
};
