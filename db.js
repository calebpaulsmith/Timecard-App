// db.js — Dexie wrapper and data-access helpers.
// Requires Dexie global (loaded via <script> in index.html).

const db = new Dexie('MaxiflexTracker');
db.version(1).stores({
  entries: 'id, date',     // id is uuid; indexed on date for per-day queries
  leave: 'date',           // YYYY-MM-DD primary key
  settings: 'key',         // key/value store
});

// v2 — Home Calendar data foundations (Phase 0). Additive only: the v1 tables
// (entries, leave, settings) are carried forward untouched. Two new tables back
// the calendar layer; nothing in v1 is migrated or rewritten, so existing
// timecard data survives the upgrade intact. See home-calendar-plan.md §3.
db.version(2).stores({
  // Calendar events. `id` is uuid PK; `date` (YYYY-MM-DD) indexed for per-day
  // queries; `needsScheduling` indexed for the backlog list; `googleId` indexed
  // for sync reconciliation. Other fields are stored but not indexed:
  //   title, allDay, startMin, endMin (minutes since midnight, null when allDay),
  //   color (palette token — see §6), notes, location, rrule (iCal RRULE or null),
  //   exdates ([YYYY-MM-DD] cancelled occurrences), seriesId (links an override
  //   instance to its series), source ('local'|'google'), createdAt, updatedAt.
  events: 'id, date, needsScheduling, googleId',
  // Event memory — the "remember what I added" list. `title` is the normalized
  // (lowercased/trimmed) PK; `lastUsed` indexed to drive newest→oldest ordering.
  // Other fields: displayTitle (as typed), defaultColor, count.
  eventHistory: 'title, lastUsed',
});

// v3 — Discover / Invites (connector framework). Additive only. Two new tables;
// nothing in v1/v2 is migrated. See CLAUDE.md "Discover / Invites".
db.version(3).stores({
  // Connector subscriptions (the user's "event ad" sources). `id` PK = the
  // Connectors source-config id; `enabled` indexed. The whole config object is
  // stored (type, dataset/host, whereTemplate, geoRadiusFt, age…) + lastFetched.
  sources: 'id, enabled',
  // Pending/dismissed/accepted invites surfaced by connectors. `externalId` is
  // the stable PK (survives re-fetches → no duplicates / no resurrecting a
  // dismissed item); `status` ('pending'|'dismissed'|'accepted'), `source`, and
  // `date` indexed. The normalized invite shape from Connectors.shape() is stored.
  invites: 'externalId, status, source, date',
});

// v4 — deleted-event tombstones (push local deletions up to Google). Additive
// only. When the user deletes a calendar event that has a googleId, we record a
// tombstone here instead of silently dropping it; the next Google sync deletes
// the remote copy (and the pull skips it), so a deleted event no longer comes
// back. The tombstone is removed once the remote delete succeeds (or the remote
// is already gone), or if the same event is re-created locally (undo). See
// CLAUDE.md "Google Calendar sync".
db.version(4).stores({
  // `googleId` is the PK (the remote event id to delete). Stored: calendarId
  // ('primary' for our events), deletedAt. Local-only bookkeeping — never
  // exported to CSV.
  deletedEvents: 'googleId',
});

const T = window.TimeUtil;

function uuid() {
  // Short UUID-ish id; collision risk is negligible for a single-user local app.
  return 'e_' + Date.now().toString(36) + '_' + Math.random().toString(36).slice(2, 10);
}

// --- Settings ---------------------------------------------------------------

async function getSetting(key, defaultValue = null) {
  const row = await db.settings.get(key);
  return row ? row.value : defaultValue;
}

async function setSetting(key, value) {
  await db.settings.put({ key, value });
}

// Default anchor: Sunday, May 3, 2026 (when the user hasn't picked one yet).
const DEFAULT_ANCHOR = '2026-05-03';

async function getAnchor() {
  return getSetting('anchorDate', DEFAULT_ANCHOR);
}

async function setAnchor(yyyymmdd) {
  if (!T.isSunday(yyyymmdd)) throw new Error('Anchor must be a Sunday');
  await setSetting('anchorDate', yyyymmdd);
}

// OT mode is now PER PAY PERIOD. Storage:
//   - `overtimeModeDefault` (bool): used by any period that lacks an override.
//     Toggled via Settings; only affects periods that haven't been touched.
//   - `overtimeModeOverrides` ({ [periodStartDate]: bool }): explicit per-period
//     choices, keyed by the anchor-aligned period start date "YYYY-MM-DD".
//
// Lazy migration from the old `overtime8hMode` boolean: on first read of the
// default, fall back to that old key. New writes go to `overtimeModeDefault`.
async function getOvertimeModeDefault() {
  let v = await getSetting('overtimeModeDefault', null);
  if (v === null) v = await getSetting('overtime8hMode', null);
  if (v === null) return true;       // brand-new installs default to 8h
  return !!v;
}

async function setOvertimeModeDefault(enabled) {
  await setSetting('overtimeModeDefault', !!enabled);
}

async function getOvertimeModeOverrides() {
  const v = await getSetting('overtimeModeOverrides', null);
  return (v && typeof v === 'object' && !Array.isArray(v)) ? v : {};
}

async function setOvertimeModeOverrides(obj) {
  await setSetting('overtimeModeOverrides', obj || {});
}

// Resolve the OT mode for a given period (uses override if present, else default).
async function getOvertimeModeForPeriodStart(periodStartStr) {
  const overrides = await getOvertimeModeOverrides();
  if (Object.prototype.hasOwnProperty.call(overrides, periodStartStr)) {
    return !!overrides[periodStartStr];
  }
  return await getOvertimeModeDefault();
}

// Set or clear (value === null) an override for one period.
async function setOvertimeModeOverride(periodStartStr, value) {
  const overrides = await getOvertimeModeOverrides();
  if (value === null || value === undefined) {
    delete overrides[periodStartStr];
  } else {
    overrides[periodStartStr] = !!value;
  }
  await setOvertimeModeOverrides(overrides);
}

// Back-compat shims for any callers still using the old global toggle.
async function getOvertimeMode() { return getOvertimeModeDefault(); }
async function setOvertimeMode(enabled) { return setOvertimeModeDefault(enabled); }

// --- Per-entry pay classification (payKind) ---------------------------------
//
// Every worked entry carries a payKind: auto | autoCredit | overtime | credit |
// regular (LOGIC-FREEZE §4.3). It routes that entry's beyond-schedule, over-80
// hours to overtime or banked credit. The legacy `isOvertime` boolean migrates
// on read: true → 'overtime', false/absent → 'auto'. Stored entries are NOT
// rewritten; resolution happens here so old rows keep working.
const PAY_KINDS = ['auto', 'autoCredit', 'overtime', 'credit', 'regular'];
function entryPayKind(e) {
  const k = e && e.payKind;
  if (PAY_KINDS.includes(k)) return k;
  return (e && e.isOvertime) ? 'overtime' : 'auto';
}

// Per-period credit default: { [periodStartDate]: true }. When set, NEW maxiflex
// entries for that period are stamped `autoCredit` (beyond-schedule hours bank as
// credit) instead of `auto` (→ overtime). Stamped at creation only — flipping it
// never reclassifies existing entries. Mirrors iOS `creditDefaultOverrides`.
async function getCreditDefaultOverrides() {
  const v = await getSetting('creditDefaultOverrides', null);
  return (v && typeof v === 'object' && !Array.isArray(v)) ? v : {};
}

async function setCreditDefaultOverrides(obj) {
  await setSetting('creditDefaultOverrides', obj || {});
}

async function getCreditDefaultForPeriodStart(periodStartStr) {
  const overrides = await getCreditDefaultOverrides();
  return !!overrides[periodStartStr];
}

// Set (on=true) or clear the credit default for one period. Cleared rather than
// stored false so the map only ever holds "on" periods.
async function setCreditDefaultOverride(periodStartStr, on) {
  const overrides = await getCreditDefaultOverrides();
  if (on) overrides[periodStartStr] = true;
  else delete overrides[periodStartStr];
  await setCreditDefaultOverrides(overrides);
}

// --- Credit-hours master switch --------------------------------------------
// Global on/off for the whole credit-hours feature. Default OFF: extra
// beyond-schedule hours all pay overtime and every credit-hours surface is
// hidden, so the app reads as a plain OT timecard. ON reveals the per-period
// Overtime|Credit control, the entry classification, credit stats, and the
// credit-hour bank. Mirrors iOS @AppStorage("creditHoursEnabled").
async function getCreditHoursEnabled() {
  return !!(await getSetting('creditHoursEnabled', false));
}

async function setCreditHoursEnabled(enabled) {
  await setSetting('creditHoursEnabled', !!enabled);
}

// When on, leave adjusts in 15-minute steps instead of whole hours (LOGIC-FREEZE
// §3). Default off. Mirrors iOS `store.leaveGranularMinutes`.
async function getLeaveGranular() {
  return !!(await getSetting('leaveGranularMinutes', false));
}

async function setLeaveGranular(on) {
  await setSetting('leaveGranularMinutes', !!on);
}

// --- Credit hours spent (Phase 2) ------------------------------------------
// Credit hours spent as time off, keyed by date: { [YYYY-MM-DD]: hours }. Drawn
// down from the credit bank — the inward mirror of leave, but funded by the
// banked balance. Stored in settings (no Dexie table), so it round-trips via the
// generic CSV SETTINGS section. Mirrors iOS `creditUsed`.
async function getCreditUsedMap() {
  const v = await getSetting('creditUsed', null);
  return (v && typeof v === 'object' && !Array.isArray(v)) ? v : {};
}

async function getCreditUsed(date) {
  const map = await getCreditUsedMap();
  return Number(map[date]) || 0;
}

// Set the credit-used hours for a date (clamped ≥ 0; 0 removes the entry).
async function setCreditUsed(date, hours) {
  const map = await getCreditUsedMap();
  const h = Math.max(0, Number(hours) || 0);
  if (h > 0) map[date] = h;
  else delete map[date];
  await setSetting('creditUsed', map);
}

async function getHourlyRate() {
  const v = await getSetting('hourlyRate', 0);
  const n = Number(v);
  return isFinite(n) && n > 0 ? n : 0;
}

async function setHourlyRate(rate) {
  const n = Number(rate);
  await setSetting('hourlyRate', isFinite(n) && n > 0 ? n : 0);
}

async function getUse24h() {
  return !!(await getSetting('use24h', false));
}

async function setUse24h(enabled) {
  await setSetting('use24h', !!enabled);
}

// calendarMode — the sticky, opt-in Home Calendar toggle (default off). Once on
// it stays on; turning it off is allowed but the toggle is designed to be a
// one-way door in normal use. Phase 0 only flips body[data-mode]; no calendar UI
// renders yet.
async function getCalendarMode() {
  return !!(await getSetting('calendarMode', false));
}

async function setCalendarMode(enabled) {
  await setSetting('calendarMode', !!enabled);
}

// validationDay: 0..13 (day-of-period index) or null. When set, the period
// view marks that day's card with a non-intrusive color cue.
async function getValidationDay() {
  const v = await getSetting('validationDay', null);
  if (v == null) return null;
  const n = Number(v);
  return (isFinite(n) && n >= 0 && n < 14) ? n : null;
}

async function setValidationDay(dayIndex) {
  if (dayIndex == null || dayIndex === '') {
    await setSetting('validationDay', null);
    return;
  }
  const n = Number(dayIndex);
  if (isFinite(n) && n >= 0 && n < 14) {
    await setSetting('validationDay', n);
  }
}

// Default schedule: 14-element array, indexed by day-of-period (0..13).
// Each slot is either null (never configured) or
// { enabled, startMin, endMin, leaveHours }. `enabled` controls whether a WORK
// entry is seeded; `leaveHours` (>= 0) is leave seeded independently, so a day
// can be a pure-leave day (enabled:false + leaveHours>0) or a workday that also
// carries recurring leave. Day 0 corresponds to the period's anchor day
// (always Sunday for our anchor). Legacy 7-element schedules are expanded by
// repeating each weekday for the second week, and slots without leaveHours read
// as 0. Fresh installs (no record yet) get Mon-Fri enabled at 9:00 AM – 5:30 PM
// (an 8-hr paid day with 30-min lunch); weekends off.
async function getDefaultSchedule() {
  const v = await getSetting('defaultSchedule', null);
  if (v == null) {
    const sched = Array.from({ length: 14 }, () => null);
    // Weekdays = Mon..Fri = indices 1-5 (week 1) and 8-12 (week 2).
    for (const idx of [1, 2, 3, 4, 5, 8, 9, 10, 11, 12]) {
      sched[idx] = { enabled: true, startMin: 9 * 60, endMin: 17 * 60 + 30, leaveHours: 0 };
    }
    return sched;
  }
  const empty14 = Array.from({ length: 14 }, () => null);
  if (!Array.isArray(v)) return empty14;
  const normalize = (slot) => {
    if (!slot || !isFinite(slot.startMin) || !isFinite(slot.endMin)) return null;
    return {
      enabled: slot.enabled === false ? false : true,
      startMin: slot.startMin | 0,
      endMin: slot.endMin | 0,
      leaveHours: Math.max(0, Math.round(Number(slot.leaveHours) || 0)),
    };
  };
  if (v.length === 7) {
    return Array.from({ length: 14 }, (_, i) => normalize(v[i % 7]));
  }
  if (v.length === 14) return v.map(normalize);
  return empty14;
}

async function setDefaultSchedule(schedule) {
  await setSetting('defaultSchedule', schedule);
}

// --- Holidays ---------------------------------------------------------------
// Default leave hours credited on a recorded holiday.
const HOLIDAY_LEAVE_HOURS = 8;

// Auto-record federal holidays (8h leave, no auto work entry). Default ON.
async function getAutoHolidays() {
  const v = await getSetting('autoHolidays', null);
  return v === null ? true : !!v;
}
async function setAutoHolidays(on) {
  await setSetting('autoHolidays', !!on);
}

// Recorded holidays: { [YYYY-MM-DD]: { name, doubleTime } }.
async function getHolidays() {
  const v = await getSetting('holidays', null);
  return (v && typeof v === 'object' && !Array.isArray(v)) ? v : {};
}
async function setHolidays(map) {
  await setSetting('holidays', map || {});
}

// Apply the default schedule to N pay periods starting at `startPeriod`.
// Schedule is 14 slots indexed by day-of-period (0..13).
//   - Recorded holidays (in `holidaySet`) override the schedule: any
//     schedule-seeded (fromDefault) work is removed and 8h holiday leave is
//     seeded (never lowering existing leave). No auto work entry is written.
//   - ENABLED days overwrite work entries (delete-then-write).
//   - Off days (null OR enabled===false) are left alone for WORK.
//   - leaveHours > 0 on any non-null slot seeds that many leave hours on the
//     day (overwriting that day's leave). A slot whose leaveHours is 0 never
//     touches leave, so manually-entered leave on routine workdays survives.
async function applyDefaultSchedule(schedule, startPeriod, anchorDateStr, periodCount = 26, holidaySet = null) {
  let written = 0;
  let leaveDays = 0;
  let cursor = new Date(startPeriod.start);
  for (let p = 0; p < periodCount; p++) {
    const period = T.payPeriodFor(cursor, anchorDateStr);
    for (let i = 0; i < period.days.length; i++) {
      const d = period.days[i];
      // Holidays override the default schedule entirely.
      if (holidaySet && holidaySet.has(d)) {
        const existing = await db.entries.where('date').equals(d).toArray();
        for (const e of existing) if (e.fromDefault) await db.entries.delete(e.id);
        if ((await getLeave(d)) < HOLIDAY_LEAVE_HOURS) {
          await setLeaveHours(d, HOLIDAY_LEAVE_HOURS);
          leaveDays++;
        }
        continue;
      }
      const slot = schedule[i];
      if (!slot) continue;
      // Seed recurring leave (independent of the work toggle).
      const lv = Math.max(0, Math.round(Number(slot.leaveHours) || 0));
      if (lv > 0) { await setLeaveHours(d, lv); leaveDays++; }
      if (slot.enabled === false) continue;
      // Delete all existing work entries for this date (overwrite semantics).
      const existing = await db.entries.where('date').equals(d).toArray();
      for (const e of existing) await db.entries.delete(e.id);
      const startTime = T.buildDateTime(d, Math.floor(slot.startMin / 60), slot.startMin % 60);
      const endTime = T.buildDateTime(d, Math.floor(slot.endMin / 60), slot.endMin % 60);
      if (endTime > startTime) {
        const { lunchMinutes, lunchDeducted } = T.hoursForEntry(startTime, endTime);
        await db.entries.add({
          id: uuid(),
          date: d,
          startTime: startTime.toISOString(),
          endTime: endTime.toISOString(),
          lunchMinutes,
          lunchDeducted,
          incomplete: false,
          fromDefault: true,
        });
        written++;
      }
    }
    cursor.setDate(cursor.getDate() + T.PAY_PERIOD_DAYS);
  }
  return { written, leaveDays };
}

// --- Entries ----------------------------------------------------------------

// Returns the currently open entry (no endTime, not incomplete), or null.
// Side effect: if an open entry is > 16h old, marks it incomplete and returns null.
async function getOpenEntry() {
  const open = await db.entries
    .filter(e => !e.endTime && !e.incomplete)
    .first();
  if (!open) return null;
  if (T.isForgotten(open.startTime)) {
    await db.entries.update(open.id, { incomplete: true });
    return null;
  }
  return open;
}

async function clockIn(now = new Date()) {
  // Make sure no other entry is open (caller should have checked, but be safe).
  const open = await getOpenEntry();
  if (open) return open;
  const rounded = T.roundToQuarter(now);
  const entry = {
    id: uuid(),
    date: T.formatLocalDate(rounded),
    startTime: rounded.toISOString(),
    endTime: null,
    lunchDeducted: false,
    incomplete: false,
  };
  await db.entries.add(entry);
  return entry;
}

async function clockOut(now = new Date()) {
  const open = await getOpenEntry();
  if (!open) return null;
  const rounded = T.roundToQuarter(now);
  // Apply the default lunch rule (lunchMinutes undefined → 30 if span ≥ 4h).
  const { lunchMinutes, lunchDeducted } = T.hoursForEntry(open.startTime, rounded);
  await db.entries.update(open.id, {
    endTime: rounded.toISOString(),
    lunchMinutes,
    lunchDeducted,
  });
  return await db.entries.get(open.id);
}

async function upsertEntry(entry) {
  if (entry.startTime && entry.endTime) {
    // If lunchMinutes is explicitly set on the entry, honor it; otherwise
    // re-apply the default rule via hoursForEntry's undefined-arg path.
    const provided = entry.lunchMinutes;
    const { lunchMinutes, lunchDeducted } =
      T.hoursForEntry(entry.startTime, entry.endTime, provided);
    entry.lunchMinutes = lunchMinutes;
    entry.lunchDeducted = lunchDeducted;
    entry.incomplete = false;
  }
  if (!entry.id) entry.id = uuid();
  await db.entries.put(entry);
  return entry;
}

async function deleteEntry(id) {
  await db.entries.delete(id);
}

async function entriesForDate(yyyymmdd) {
  return db.entries.where('date').equals(yyyymmdd).toArray();
}

async function entriesForPeriod(period) {
  // period.days is array of YYYY-MM-DD
  return db.entries.where('date').anyOf(period.days).toArray();
}

// --- Leave ------------------------------------------------------------------

// Leave is stored in MINUTES (15-min granularity) as of LOGIC-FREEZE §3; the
// legacy whole-`hours` field is kept in sync (rounded) for back-compat readers
// and is the fallback when a row predates `minutes`.
function leaveRowMinutes(row) {
  if (!row) return 0;
  return (row.minutes != null && row.minutes > 0) ? row.minutes : Math.round((row.hours || 0) * 60);
}

async function getLeaveMinutes(yyyymmdd) {
  return leaveRowMinutes(await db.leave.get(yyyymmdd));
}

// Hours (fractional) — what the totals/timeline math consume.
async function getLeave(yyyymmdd) {
  return (await getLeaveMinutes(yyyymmdd)) / 60;
}

async function setLeaveMinutes(yyyymmdd, minutes) {
  const m = Math.max(0, Math.round(minutes));
  if (m === 0) {
    await db.leave.delete(yyyymmdd);
  } else {
    // PRESERVE any existing placement — changing the amount shouldn't move it.
    const existing = await db.leave.get(yyyymmdd);
    const startMin = existing && existing.startMin != null ? existing.startMin : -1;
    await db.leave.put({ date: yyyymmdd, hours: Math.round(m / 60), minutes: m, startMin });
  }
  return m;
}

// Optional placement of the day's leave block (minute-of-day), or null = auto.
function leaveRowStart(row) {
  return (row && row.startMin != null && row.startMin >= 0) ? row.startMin : null;
}

async function getLeaveStart(yyyymmdd) {
  return leaveRowStart(await db.leave.get(yyyymmdd));
}

// Place (or clear, with null/<0) the day's leave block. No-op if there's no leave.
async function setLeaveStart(yyyymmdd, startMin) {
  const existing = await db.leave.get(yyyymmdd);
  if (!existing) return;
  existing.startMin = (startMin == null || startMin < 0) ? -1 : Math.round(startMin);
  await db.leave.put(existing);
}

async function leaveStartForPeriod(period) {
  const rows = await db.leave.where('date').anyOf(period.days).toArray();
  const map = {};
  for (const r of rows) { const s = leaveRowStart(r); if (s != null) map[r.date] = s; }
  return map;
}

// Back-compat: hours in, routed through the minutes setter (fractional preserved).
async function setLeaveHours(yyyymmdd, hours) {
  return setLeaveMinutes(yyyymmdd, Math.round(Math.max(0, hours) * 60));
}

async function addLeaveMinutes(yyyymmdd, deltaMin) {
  const cur = await getLeaveMinutes(yyyymmdd);
  return setLeaveMinutes(yyyymmdd, cur + deltaMin);
}

async function addLeave(yyyymmdd, delta) {   // delta in hours (back-compat)
  return addLeaveMinutes(yyyymmdd, Math.round(delta * 60));
}

async function leaveForPeriod(period) {
  const rows = await db.leave.where('date').anyOf(period.days).toArray();
  const map = {};
  for (const r of rows) map[r.date] = leaveRowMinutes(r) / 60;   // fractional hours
  return map;
}

// --- Calendar events (Phase 1) ----------------------------------------------
// Single, local events for calendar mode. Recurrence (rrule/exdates/seriesId)
// and the needsScheduling backlog are stored on the row but not yet authored by
// the UI — those land in Phase 2. All fields normalize to safe defaults so an
// event written here round-trips cleanly through later .ics / Google sync.

function normalizeEvent(ev) {
  const now = new Date().toISOString();
  const e = { ...ev };
  if (!e.id) e.id = uuid();
  e.createdAt = e.createdAt || now;
  e.updatedAt = now;
  e.title = String(e.title || '').trim();
  e.date = e.date || null;
  e.allDay = !!e.allDay;
  // Timed events carry minutes-since-midnight; all-day events null them out.
  e.startMin = e.allDay ? null : (isFinite(e.startMin) ? e.startMin | 0 : null);
  e.endMin = e.allDay ? null : (isFinite(e.endMin) ? e.endMin | 0 : null);
  e.color = e.color || 'work';
  e.notes = e.notes || '';
  e.location = e.location || '';
  e.rrule = e.rrule || null;
  e.exdates = Array.isArray(e.exdates) ? e.exdates : [];
  e.seriesId = e.seriesId || null;
  e.needsScheduling = !!e.needsScheduling;
  e.source = e.source || 'local';
  e.googleId = e.googleId || null;
  return e;
}

async function getEvent(id) {
  return db.events.get(id);
}

async function eventsForDate(yyyymmdd) {
  return db.events.where('date').equals(yyyymmdd).toArray();
}

async function eventsForPeriod(period) {
  return db.events.where('date').anyOf(period.days).toArray();
}

async function upsertEvent(ev) {
  const e = normalizeEvent(ev);
  await db.events.put(e);
  // An event that exists locally with this googleId must NOT also be tombstoned
  // (e.g. delete → undo, or a remote re-add) — clear any stale tombstone so the
  // next sync doesn't delete the remote copy we just restored.
  if (e.googleId) await db.deletedEvents.delete(e.googleId);
  return e;
}

async function deleteEvent(id) {
  await db.events.delete(id);
}

// User-initiated delete of a calendar event. Like deleteEvent, but if the event
// has a googleId (i.e. it lives on Google too) and isn't a read-only mirror, it
// records a tombstone so the next Google sync deletes the remote copy instead of
// re-pulling it. Use this for deletes the user performs; the sync layer's own
// reconciliation deletes (remote-cancelled rows) should keep calling deleteEvent.
async function deleteEventAndSync(id) {
  const ev = await db.events.get(id);
  if (ev && ev.googleId && ev.source !== 'ritza') {
    await addEventTombstone(ev.googleId, 'primary');
  }
  await db.events.delete(id);
}

// --- Deleted-event tombstones (Google sync) ---------------------------------

async function addEventTombstone(googleId, calendarId = 'primary') {
  if (!googleId) return;
  await db.deletedEvents.put({ googleId, calendarId, deletedAt: new Date().toISOString() });
}

async function eventTombstones() {
  return db.deletedEvents.toArray();
}

async function removeEventTombstone(googleId) {
  if (!googleId) return;
  await db.deletedEvents.delete(googleId);
}

// Find a local event by its Google Calendar id (sync reconciliation). Returns
// the event or undefined.
async function eventByGoogleId(googleId) {
  if (!googleId) return undefined;
  return db.events.where('googleId').equals(googleId).first();
}

// All events from a given source ('google' for mine, 'ritza' for the mirrored
// shared calendar). Small data set → full scan.
async function eventsBySource(source) {
  return db.events.filter(e => e.source === source).toArray();
}

// All recurring series (rrule set). A series anchored before the visible window
// can still have occurrences inside it, so the render layer expands these
// separately from the plain date-window query. Small data set → full scan.
async function recurringSeries() {
  return db.events.filter(e => !!e.rrule).toArray();
}

// Backlog: events flagged needsScheduling (typically date-less). Boolean keys
// aren't indexable in IndexedDB, so filter rather than query.
async function backlogEvents() {
  return db.events.filter(e => !!e.needsScheduling).toArray();
}

// --- Event history (type-ahead memory, §8) ----------------------------------
// Keyed by the normalized (lowercased/trimmed) title. Every saved event bumps
// its row's lastUsed/count and remembers a default color so re-adding a known
// title auto-fills color.

function normTitle(title) {
  return String(title || '').trim().toLowerCase();
}

async function recordEventHistory(title, color) {
  const key = normTitle(title);
  if (!key) return;
  const existing = await db.eventHistory.get(key);
  await db.eventHistory.put({
    title: key,
    displayTitle: String(title).trim(),
    defaultColor: color || (existing && existing.defaultColor) || 'work',
    lastUsed: Date.now(),
    count: (existing ? existing.count : 0) + 1,
  });
}

// Suggestions for the title field: prefix match (or most-recent when empty),
// newest-first, capped. Returns the stored history rows.
async function searchEventHistory(prefix, limit = 8) {
  const q = normTitle(prefix);
  let rows;
  if (!q) {
    rows = await db.eventHistory.orderBy('lastUsed').reverse().limit(limit).toArray();
  } else {
    rows = await db.eventHistory.where('title').startsWith(q).toArray();
    rows.sort((a, b) => b.lastUsed - a.lastUsed);
    rows = rows.slice(0, limit);
  }
  return rows;
}

async function deleteEventHistory(titleKey) {
  await db.eventHistory.delete(normTitle(titleKey));
}

// --- Discover / Invites: sources + invites ----------------------------------

async function getSources() {
  return db.sources.toArray();
}

// Persist/upgrade the seed connector configs. Version-stamped so a schema bump
// (e.g. flat config → unified `filters`) re-seeds the DEFAULT sources once,
// preserving each one's enabled toggle and never touching user-ADDED sources.
async function seedSources(defaults, version = 1) {
  if (!Array.isArray(defaults)) return 0;
  const cur = await getSetting('sourcesSeedVersion', 0);
  if (cur >= version) return 0;
  let n = 0;
  await db.transaction('rw', db.sources, async () => {
    for (const d of defaults) {
      const ex = await db.sources.get(d.id);
      await db.sources.put({ ...d, enabled: ex ? ex.enabled : (d.enabled !== false), lastFetched: ex ? ex.lastFetched : null });
      n++;
    }
  });
  await setSetting('sourcesSeedVersion', version);
  return n;
}

async function upsertSource(src) {
  if (!src || !src.id) throw new Error('source needs an id');
  await db.sources.put({ ...src, enabled: src.enabled !== false });
  return src;
}
async function deleteSource(id) { await db.sources.delete(id); }
async function setSourceEnabled(id, on) {
  const s = await db.sources.get(id);
  if (s) await db.sources.put({ ...s, enabled: !!on });
}
async function setSourceFetched(id) {
  const s = await db.sources.get(id);
  if (s) await db.sources.put({ ...s, lastFetched: new Date().toISOString() });
}

// Upsert freshly-fetched invite rows. A row whose externalId already exists as
// dismissed/accepted is left alone (so dismissals stick and accepted items
// don't re-appear); a new externalId is added as `pending`. Returns the count
// of NEW pending invites (drives the PUSH badge's "N new").
async function upsertInvites(rows) {
  if (!Array.isArray(rows) || !rows.length) return 0;
  let added = 0;
  await db.transaction('rw', db.invites, async () => {
    for (const r of rows) {
      if (!r.externalId) continue;
      const ex = await db.invites.get(r.externalId);
      if (ex && ex.status !== 'pending') continue;
      if (!ex) added++;
      await db.invites.put({
        ...r,
        status: 'pending',
        firstSeen: ex ? ex.firstSeen : new Date().toISOString(),
      });
    }
  });
  return added;
}

async function pendingInvites() {
  const rows = await db.invites.where('status').equals('pending').toArray();
  rows.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  return rows;
}
async function countPendingInvites() {
  return db.invites.where('status').equals('pending').count();
}
async function dismissInvite(externalId) {
  const iv = await db.invites.get(externalId);
  if (iv) await db.invites.put({ ...iv, status: 'dismissed' });
}
async function acceptInvite(externalId) {
  const iv = await db.invites.get(externalId);
  if (iv) await db.invites.put({ ...iv, status: 'accepted' });
}

// --- Exports ----------------------------------------------------------------

window.DB = {
  db,
  DEFAULT_ANCHOR,
  getSetting, setSetting,
  getAnchor, setAnchor,
  getOvertimeMode, setOvertimeMode,
  getOvertimeModeDefault, setOvertimeModeDefault,
  getOvertimeModeOverrides, setOvertimeModeOverrides,
  getOvertimeModeForPeriodStart, setOvertimeModeOverride,
  entryPayKind,
  getCreditDefaultOverrides, setCreditDefaultOverrides,
  getCreditDefaultForPeriodStart, setCreditDefaultOverride,
  getCreditHoursEnabled, setCreditHoursEnabled,
  getLeaveGranular, setLeaveGranular,
  getCreditUsedMap, getCreditUsed, setCreditUsed,
  getHourlyRate, setHourlyRate,
  getUse24h, setUse24h,
  getCalendarMode, setCalendarMode,
  getValidationDay, setValidationDay,
  getDefaultSchedule, setDefaultSchedule, applyDefaultSchedule,
  getAutoHolidays, setAutoHolidays, getHolidays, setHolidays,
  HOLIDAY_LEAVE_HOURS,
  getOpenEntry, clockIn, clockOut,
  upsertEntry, deleteEntry,
  entriesForDate, entriesForPeriod,
  getLeave, getLeaveMinutes, setLeaveHours, setLeaveMinutes,
  addLeave, addLeaveMinutes, leaveForPeriod,
  getLeaveStart, setLeaveStart, leaveStartForPeriod,
  getEvent, eventsForDate, eventsForPeriod, upsertEvent, deleteEvent,
  deleteEventAndSync, addEventTombstone, eventTombstones, removeEventTombstone,
  eventByGoogleId, eventsBySource,
  recurringSeries, backlogEvents,
  recordEventHistory, searchEventHistory, deleteEventHistory,
  getSources, seedSources, upsertSource, deleteSource,
  setSourceEnabled, setSourceFetched,
  upsertInvites, pendingInvites, countPendingInvites, dismissInvite, acceptInvite,
  exportToCsv, importFromCsv,
};

// --- CSV export / import ----------------------------------------------------
// Single .csv file split into sections by `# Section: NAME` marker lines. The
// file is meant to be both human-readable (a manager can open it in Excel and
// see a timecard) and round-trippable (import restores settings, default
// schedule, entries, and leave).

const DAYS_LONG = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
const DAYS_SHORT = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

// Local-device secrets / per-device config that must never land in a portable
// CSV backup (it could be emailed). Excluded from export AND preserved across a
// CSV import (which otherwise wipes the settings table) so restoring a backup
// doesn't silently disconnect Google.
// `scheduleSyncMap` is per-account sync bookkeeping ({ calendarId, items:{key:
// {googleId,sig}} }) keyed to a specific Google calendar — meaningless on
// another device/account, so it's local-only like the token.
const LOCAL_ONLY_SETTINGS = ['googleClientId', 'googleToken', 'apiKey', 'scheduleSyncMap'];

function csvEscape(v) {
  if (v == null) return '';
  const s = String(v);
  if (/[",\n\r]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}
function csvLine(arr) { return arr.map(csvEscape).join(','); }
function pad2(n) { return String(n).padStart(2, '0'); }
function minToHHMM(m) {
  const h = Math.floor(m / 60) % 24;
  return `${pad2(h)}:${pad2(m % 60)}`;
}
function hhmmToMin(s) {
  const m = String(s || '').trim().match(/^(\d{1,2}):(\d{2})$/);
  if (!m) return null;
  const h = Number(m[1]), min = Number(m[2]);
  if (!isFinite(h) || !isFinite(min)) return null;
  return h * 60 + min;
}
function isoOnDate(dateStr, hhmm) {
  const min = hhmmToMin(hhmm);
  if (min == null) return null;
  return T.buildDateTime(dateStr, Math.floor(min / 60), min % 60).toISOString();
}

async function exportToCsv() {
  const lines = [];
  lines.push('# Timecard App Export');
  lines.push('# Generated: ' + new Date().toISOString());
  lines.push('# This file is a complete backup of your timecard data. Sections below');
  lines.push('# can be edited by hand; on import, ALL existing data is replaced with');
  lines.push('# whatever is in this file. Hours are computed from Start/End and reflect');
  lines.push('# the 30-min lunch auto-deduction when a span is >= 4 hours.');
  lines.push('');

  // SETTINGS — emit all known keys plus any unrecognized future keys.
  lines.push('# Section: SETTINGS');
  lines.push('Key,Value');
  const settingsRows = await db.settings.toArray();
  const settingsMap = {};
  for (const r of settingsRows) settingsMap[r.key] = r.value;
  const EXCLUDE_SETTINGS = new Set(LOCAL_ONLY_SETTINGS);
  const KNOWN_SETTINGS = [
    'anchorDate',
    'overtimeModeDefault',
    'overtimeModeOverrides',
    'overtime8hMode',  // legacy — exported empty unless still present
    'hourlyRate',
    'use24h',
    'autoHolidays',
    'holidays',
  ];
  for (const k of KNOWN_SETTINGS) {
    if (EXCLUDE_SETTINGS.has(k)) continue;
    const v = settingsMap[k];
    lines.push(csvLine([k, v == null ? '' : JSON.stringify(v)]));
  }
  // defaultSchedule lives in its own readable section, not the JSON blob.
  for (const k of Object.keys(settingsMap)) {
    if (KNOWN_SETTINGS.includes(k) || EXCLUDE_SETTINGS.has(k) || k === 'defaultSchedule') continue;
    lines.push(csvLine([k, JSON.stringify(settingsMap[k])]));
  }
  lines.push('');

  // DEFAULT_SCHEDULE — 14 rows, indexed by day-of-period. Times persist even
  // when Enabled=no so re-enabling restores the user's last values.
  lines.push('# Section: DEFAULT_SCHEDULE');
  lines.push('PeriodDay,Weekday,Enabled,StartTime,EndTime,Leave');
  const sched = await getDefaultSchedule();
  for (let i = 0; i < 14; i++) {
    const slot = sched[i];
    const weekday = DAYS_LONG[i % 7];
    if (slot) {
      const en = slot.enabled === false ? 'no' : 'yes';
      const lv = Math.max(0, Math.round(Number(slot.leaveHours) || 0));
      lines.push(csvLine([i, weekday, en, minToHHMM(slot.startMin), minToHHMM(slot.endMin), lv]));
    } else {
      lines.push(csvLine([i, weekday, 'no', '', '', 0]));
    }
  }
  lines.push('');

  // ENTRIES — every clock-in record. EndDate is blank if same as Date.
  // LunchMin is the explicit deducted minutes (replaces the boolean Lunch flag,
  // which is kept for human readability and old-file back-compat).
  lines.push('# Section: ENTRIES');
  lines.push('Date,Day,StartTime,EndTime,EndDate,Hours,Lunch,LunchMin,Overtime,PayKind,Incomplete,FromDefault,ID');
  const entries = await db.entries.orderBy('date').toArray();
  for (const e of entries) {
    const sd = e.startTime ? new Date(e.startTime) : null;
    const ed = e.endTime ? new Date(e.endTime) : null;
    const startDateStr = e.date || (sd ? T.formatLocalDate(sd) : '');
    const endDateStr = ed ? T.formatLocalDate(ed) : '';
    const endDateCol = (endDateStr && endDateStr !== startDateStr) ? endDateStr : '';
    const dayName = sd ? DAYS_SHORT[sd.getDay()] : '';
    const startTime = sd ? `${pad2(sd.getHours())}:${pad2(sd.getMinutes())}` : '';
    const endTime = ed ? `${pad2(ed.getHours())}:${pad2(ed.getMinutes())}` : '';
    const lm = e.lunchMinutes != null ? e.lunchMinutes : (e.lunchDeducted ? 30 : 0);
    const hours = (sd && ed) ? T.hoursForEntry(sd, ed, lm).hours : 0;
    lines.push(csvLine([
      startDateStr, dayName, startTime, endTime, endDateCol,
      hours,
      lm > 0 ? 'yes' : 'no',
      lm,
      // Overtime column kept for human readability + old-importer back-compat;
      // PayKind is the authoritative classification (LOGIC-FREEZE §4.3).
      entryPayKind(e) === 'overtime' ? 'yes' : 'no',
      entryPayKind(e),
      e.incomplete ? 'yes' : 'no',
      e.fromDefault ? 'yes' : 'no',
      e.id,
    ]));
  }
  lines.push('');

  // LEAVE — `Hours` stays for back-compat (old readers); `Minutes` is the precise
  // 15-min-granular value, preferred by readers that know it.
  lines.push('# Section: LEAVE');
  lines.push('Date,Day,Hours,Minutes,StartMin');
  const leaveRows = await db.leave.orderBy('date').toArray();
  for (const l of leaveRows) {
    const d = T.parseLocalDate(l.date);
    const minutes = leaveRowMinutes(l);
    const start = leaveRowStart(l);
    lines.push(csvLine([l.date, DAYS_SHORT[d.getDay()], String(minutes / 60), minutes,
                        start == null ? '' : start]));
  }
  lines.push('');

  // EVENTS — calendar events (single + recurring series + backlog). Times are
  // HH:MM (blank for all-day / backlog). Exdates are space-separated dates.
  lines.push('# Section: EVENTS');
  lines.push('Date,Title,AllDay,Start,End,Color,Location,Notes,RRule,Exdates,SeriesId,NeedsScheduling,Source,GoogleId,ID');
  const eventRows = await db.events.toArray();
  for (const e of eventRows) {
    lines.push(csvLine([
      e.date || '',
      e.title || '',
      e.allDay ? 'yes' : 'no',
      (!e.allDay && isFinite(e.startMin)) ? minToHHMM(e.startMin) : '',
      (!e.allDay && isFinite(e.endMin)) ? minToHHMM(e.endMin) : '',
      e.color || 'work',
      e.location || '',
      e.notes || '',
      e.rrule || '',
      Array.isArray(e.exdates) ? e.exdates.join(' ') : '',
      e.seriesId || '',
      e.needsScheduling ? 'yes' : 'no',
      e.source || 'local',
      e.googleId || '',
      e.id,
    ]));
  }
  lines.push('');

  // EVENT_HISTORY — the type-ahead memory list.
  lines.push('# Section: EVENT_HISTORY');
  lines.push('Title,DisplayTitle,DefaultColor,LastUsed,Count');
  const histRows = await db.eventHistory.toArray();
  for (const h of histRows) {
    lines.push(csvLine([h.title, h.displayTitle || '', h.defaultColor || 'work', h.lastUsed || 0, h.count || 0]));
  }
  lines.push('');

  return lines.join('\n');
}

// Parse an RFC-4180 CSV into an array of rows (each row is an array of cells).
function parseCsv(text) {
  const rows = [];
  let row = [], cell = '', inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { cell += '"'; i++; }
        else inQuotes = false;
      } else cell += ch;
    } else {
      if (ch === '"') inQuotes = true;
      else if (ch === ',') { row.push(cell); cell = ''; }
      else if (ch === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
      else if (ch === '\r') { /* skip */ }
      else cell += ch;
    }
  }
  if (cell.length > 0 || row.length > 0) { row.push(cell); rows.push(row); }
  return rows;
}

async function importFromCsv(text) {
  const rows = parseCsv(text);
  // Split into sections by `# Section: NAME` markers in column 0.
  const sections = {};
  let curName = null, curRows = [];
  for (const row of rows) {
    const first = (row[0] || '').trim();
    if (first.startsWith('# Section:')) {
      if (curName) sections[curName] = curRows;
      curName = first.slice('# Section:'.length).trim().toUpperCase();
      curRows = [];
      continue;
    }
    if (first.startsWith('#')) continue;       // comment
    if (row.every(c => c === '')) continue;    // blank
    if (!curName) continue;                    // before first section
    curRows.push(row);
  }
  if (curName) sections[curName] = curRows;

  // Wipe + restore in a single transaction so a mid-way error rolls back.
  // events + eventHistory are included so a calendar-mode backup round-trips;
  // old CSVs without those sections simply leave the (cleared) tables empty.
  // Preserve local-only settings (Google token/client id, API keys) across the
  // wipe — they're never in the CSV, so clearing the table would disconnect them.
  const preserved = [];
  for (const k of LOCAL_ONLY_SETTINGS) {
    const row = await db.settings.get(k);
    if (row) preserved.push(row);
  }
  await db.transaction('rw', db.entries, db.leave, db.settings, db.events, db.eventHistory, async () => {
    await db.entries.clear();
    await db.leave.clear();
    await db.settings.clear();
    await db.events.clear();
    await db.eventHistory.clear();
    await importApplySections(sections);
    for (const row of preserved) await db.settings.put(row);
  });
}

async function importApplySections(sections) {
  if (sections.SETTINGS) {
    const data = sections.SETTINGS.slice(1); // drop header
    for (const r of data) {
      const key = (r[0] || '').trim();
      const raw = (r[1] == null ? '' : String(r[1])).trim();
      if (!key) continue;
      if (raw === '') continue;
      let value;
      try { value = JSON.parse(raw); }
      catch { value = raw; }
      await db.settings.put({ key, value });
    }
  }

  if (sections.DEFAULT_SCHEDULE) {
    // Detect format by inspecting the header row. New: PeriodDay,Weekday,...
    // Legacy: Weekday,Enabled,StartTime,EndTime (7 rows).
    const header = (sections.DEFAULT_SCHEDULE[0] || []).map(h => String(h || '').trim().toLowerCase());
    const data = sections.DEFAULT_SCHEDULE.slice(1);
    const dowMap = {};
    for (let i = 0; i < 7; i++) dowMap[DAYS_LONG[i].toLowerCase()] = i;
    const sched14 = Array.from({ length: 14 }, () => null);
    const isNewFormat = header[0] === 'periodday';
    for (const r of data) {
      let idx, enabledCol, startCol, endCol, leaveCol;
      if (isNewFormat) {
        idx = parseInt(r[0], 10);
        if (!isFinite(idx) || idx < 0 || idx >= 14) continue;
        enabledCol = r[2]; startCol = r[3]; endCol = r[4]; leaveCol = r[5];
      } else {
        const dow = dowMap[(r[0] || '').trim().toLowerCase()];
        if (dow == null) continue;
        idx = dow;                              // legacy first week
        enabledCol = r[1]; startCol = r[2]; endCol = r[3]; leaveCol = undefined;
      }
      const enabled = String(enabledCol || '').trim().toLowerCase() === 'yes';
      const leaveHours = Math.max(0, Math.round(Number(leaveCol) || 0));
      const sm = hhmmToMin(startCol), em = hhmmToMin(endCol);
      if (sm != null && em != null) {
        sched14[idx] = { enabled, startMin: sm, endMin: em, leaveHours };
        if (!isNewFormat) sched14[idx + 7] = { enabled, startMin: sm, endMin: em, leaveHours };
      }
    }
    await db.settings.put({ key: 'defaultSchedule', value: sched14 });
  }

  if (sections.ENTRIES) {
    const header = sections.ENTRIES[0] || [];
    const col = {};
    header.forEach((h, i) => { col[h.trim().toLowerCase()] = i; });
    const get = (row, name) => {
      const i = col[name.toLowerCase()];
      return i == null ? '' : (row[i] == null ? '' : row[i]);
    };
    const data = sections.ENTRIES.slice(1);
    for (const r of data) {
      const date = String(get(r, 'date') || '').trim();
      if (!date) continue;
      const startTime = get(r, 'starttime');
      const endTime = get(r, 'endtime');
      const endDate = String(get(r, 'enddate') || '').trim() || date;
      const startIso = startTime ? isoOnDate(date, startTime) : null;
      const endIso = endTime ? isoOnDate(endDate, endTime) : null;
      const lunchYes = String(get(r, 'lunch') || '').trim().toLowerCase() === 'yes';
      const lunchMinRaw = String(get(r, 'lunchmin') || '').trim();
      const lunchMinutes = lunchMinRaw !== ''
        ? Math.max(0, Math.round(Number(lunchMinRaw)))
        : (lunchYes ? 30 : 0);
      const incomplete = String(get(r, 'incomplete') || '').trim().toLowerCase() === 'yes';
      const fromDefault = String(get(r, 'fromdefault') || '').trim().toLowerCase() === 'yes';
      const isOvertime = String(get(r, 'overtime') || '').trim().toLowerCase() === 'yes';
      // PayKind is authoritative when present; older exports without the column
      // fall back to the Overtime flag (yes → 'overtime', else 'auto').
      const payKindRaw = String(get(r, 'paykind') || '').trim();
      const payKind = PAY_KINDS.includes(payKindRaw)
        ? payKindRaw
        : (isOvertime ? 'overtime' : 'auto');
      const id = String(get(r, 'id') || '').trim() || uuid();
      await db.entries.put({
        id, date,
        startTime: startIso, endTime: endIso,
        lunchMinutes, lunchDeducted: lunchMinutes > 0,
        payKind, incomplete, fromDefault,
      });
    }
  }

  if (sections.LEAVE) {
    const data = sections.LEAVE.slice(1);
    for (const r of data) {
      const date = (r[0] || '').trim();
      // Prefer the precise Minutes column; fall back to Hours (old 3-col CSV).
      let minutes = Math.max(0, Math.round(Number(r[3])));
      if (!isFinite(minutes) || minutes <= 0) {
        minutes = Math.max(0, Math.round((Number(r[2]) || 0) * 60));
      }
      if (!date || !isFinite(minutes) || minutes <= 0) continue;
      const startRaw = (r[4] || '').trim();
      const startNum = startRaw === '' ? -1 : Math.round(Number(startRaw));
      const startMin = isFinite(startNum) && startNum >= 0 ? startNum : -1;
      await db.leave.put({ date, hours: Math.round(minutes / 60), minutes, startMin });
    }
  }

  if (sections.EVENTS) {
    const header = sections.EVENTS[0] || [];
    const col = {};
    header.forEach((h, i) => { col[String(h).trim().toLowerCase()] = i; });
    const get = (row, name) => {
      const i = col[name.toLowerCase()];
      return i == null ? '' : (row[i] == null ? '' : String(row[i]));
    };
    for (const r of sections.EVENTS.slice(1)) {
      const id = get(r, 'id').trim();
      const title = get(r, 'title').trim();
      if (!id && !title) continue;
      const allDay = get(r, 'allday').trim().toLowerCase() === 'yes';
      const sm = hhmmToMin(get(r, 'start'));
      const em = hhmmToMin(get(r, 'end'));
      const exRaw = get(r, 'exdates').trim();
      const dateStr = get(r, 'date').trim();
      await db.events.put(normalizeEvent({
        id: id || uuid(),
        date: dateStr || null,
        title,
        allDay,
        startMin: allDay ? null : sm,
        endMin: allDay ? null : em,
        color: get(r, 'color').trim() || 'work',
        location: get(r, 'location'),
        notes: get(r, 'notes'),
        rrule: get(r, 'rrule').trim() || null,
        exdates: exRaw ? exRaw.split(/[\s,]+/).filter(Boolean) : [],
        seriesId: get(r, 'seriesid').trim() || null,
        needsScheduling: get(r, 'needsscheduling').trim().toLowerCase() === 'yes',
        source: get(r, 'source').trim() || 'local',
        googleId: get(r, 'googleid').trim() || null,
      }));
    }
  }

  if (sections.EVENT_HISTORY) {
    for (const r of sections.EVENT_HISTORY.slice(1)) {
      const title = String(r[0] || '').trim().toLowerCase();
      if (!title) continue;
      await db.eventHistory.put({
        title,
        displayTitle: String(r[1] || '').trim() || title,
        defaultColor: String(r[2] || 'work').trim() || 'work',
        lastUsed: Number(r[3]) || 0,
        count: Number(r[4]) || 0,
      });
    }
  }
}
