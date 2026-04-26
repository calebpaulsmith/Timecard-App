// db.js — Dexie wrapper and data-access helpers.
// Requires Dexie global (loaded via <script> in index.html).

const db = new Dexie('MaxiflexTracker');
db.version(1).stores({
  entries: 'id, date',     // id is uuid; indexed on date for per-day queries
  leave: 'date',           // YYYY-MM-DD primary key
  settings: 'key',         // key/value store
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

async function getAnchor() {
  return getSetting('anchorDate', null);
}

async function setAnchor(yyyymmdd) {
  if (!T.isSunday(yyyymmdd)) throw new Error('Anchor must be a Sunday');
  await setSetting('anchorDate', yyyymmdd);
}

async function getOvertimeMode() {
  return !!(await getSetting('overtime8hMode', false));
}

async function setOvertimeMode(enabled) {
  await setSetting('overtime8hMode', !!enabled);
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
  const { lunchDeducted } = T.hoursForEntry(open.startTime, rounded);
  await db.entries.update(open.id, {
    endTime: rounded.toISOString(),
    lunchDeducted,
  });
  return await db.entries.get(open.id);
}

async function upsertEntry(entry) {
  // Recompute lunchDeducted from the times.
  if (entry.startTime && entry.endTime) {
    const { lunchDeducted } = T.hoursForEntry(entry.startTime, entry.endTime);
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

async function getLeave(yyyymmdd) {
  const row = await db.leave.get(yyyymmdd);
  return row ? row.hours : 0;
}

async function setLeaveHours(yyyymmdd, hours) {
  const h = Math.max(0, Math.round(hours));
  if (h === 0) {
    await db.leave.delete(yyyymmdd);
  } else {
    await db.leave.put({ date: yyyymmdd, hours: h });
  }
  return h;
}

async function addLeave(yyyymmdd, delta) {
  const current = await getLeave(yyyymmdd);
  return setLeaveHours(yyyymmdd, current + delta);
}

async function leaveForPeriod(period) {
  const rows = await db.leave.where('date').anyOf(period.days).toArray();
  const map = {};
  for (const r of rows) map[r.date] = r.hours;
  return map;
}

// --- Exports ----------------------------------------------------------------

window.DB = {
  db,
  getSetting, setSetting,
  getAnchor, setAnchor,
  getOvertimeMode, setOvertimeMode,
  getHourlyRate, setHourlyRate,
  getOpenEntry, clockIn, clockOut,
  upsertEntry, deleteEntry,
  entriesForDate, entriesForPeriod,
  getLeave, setLeaveHours, addLeave, leaveForPeriod,
};
