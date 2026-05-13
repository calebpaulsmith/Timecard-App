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

// Default anchor: Sunday, May 3, 2026 (when the user hasn't picked one yet).
const DEFAULT_ANCHOR = '2026-05-03';

async function getAnchor() {
  return getSetting('anchorDate', DEFAULT_ANCHOR);
}

async function setAnchor(yyyymmdd) {
  if (!T.isSunday(yyyymmdd)) throw new Error('Anchor must be a Sunday');
  await setSetting('anchorDate', yyyymmdd);
}

async function getOvertimeMode() {
  // 8-hour overtime mode defaults to ON now. Existing users who explicitly
  // toggled it off still get false; this only affects fresh installs (no
  // record in the settings table yet).
  const v = await getSetting('overtime8hMode', null);
  if (v === null) return true;
  return !!v;
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

async function getUse24h() {
  return !!(await getSetting('use24h', false));
}

async function setUse24h(enabled) {
  await setSetting('use24h', !!enabled);
}

// Default schedule: 14-element array, indexed by day-of-period (0..13).
// Each slot is either null (never configured) or { enabled, startMin, endMin }.
// Day 0 corresponds to the period's anchor day (always Sunday for our anchor).
// Legacy 7-element schedules are expanded by repeating each weekday for the
// second week.
async function getDefaultSchedule() {
  const v = await getSetting('defaultSchedule', null);
  const empty14 = Array.from({ length: 14 }, () => null);
  if (!Array.isArray(v)) return empty14;
  const normalize = (slot) => {
    if (!slot || !isFinite(slot.startMin) || !isFinite(slot.endMin)) return null;
    return {
      enabled: slot.enabled === false ? false : true,
      startMin: slot.startMin | 0,
      endMin: slot.endMin | 0,
    };
  };
  if (v.length === 7) {
    // Legacy weekday-indexed → duplicate across both weeks.
    return Array.from({ length: 14 }, (_, i) => normalize(v[i % 7]));
  }
  if (v.length === 14) return v.map(normalize);
  return empty14;
}

async function setDefaultSchedule(schedule) {
  await setSetting('defaultSchedule', schedule);
}

// Apply the default schedule to N pay periods starting at `startPeriod`.
// Schedule is 14 slots indexed by day-of-period (0..13). Overwrites work
// entries on each ENABLED day. Off days (null OR enabled===false) are left
// alone. Leave is never touched.
async function applyDefaultSchedule(schedule, startPeriod, anchorDateStr, periodCount = 26) {
  let written = 0;
  let cursor = new Date(startPeriod.start);
  for (let p = 0; p < periodCount; p++) {
    const period = T.payPeriodFor(cursor, anchorDateStr);
    for (let i = 0; i < period.days.length; i++) {
      const d = period.days[i];
      const slot = schedule[i];
      if (!slot || slot.enabled === false) continue;
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
  return written;
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
  DEFAULT_ANCHOR,
  getSetting, setSetting,
  getAnchor, setAnchor,
  getOvertimeMode, setOvertimeMode,
  getHourlyRate, setHourlyRate,
  getUse24h, setUse24h,
  getDefaultSchedule, setDefaultSchedule, applyDefaultSchedule,
  getOpenEntry, clockIn, clockOut,
  upsertEntry, deleteEntry,
  entriesForDate, entriesForPeriod,
  getLeave, setLeaveHours, addLeave, leaveForPeriod,
  exportToCsv, importFromCsv,
};

// --- CSV export / import ----------------------------------------------------
// Single .csv file split into sections by `# Section: NAME` marker lines. The
// file is meant to be both human-readable (a manager can open it in Excel and
// see a timecard) and round-trippable (import restores settings, default
// schedule, entries, and leave).

const DAYS_LONG = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
const DAYS_SHORT = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

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
  const KNOWN_SETTINGS = ['anchorDate', 'overtime8hMode', 'hourlyRate', 'use24h'];
  for (const k of KNOWN_SETTINGS) {
    const v = settingsMap[k];
    lines.push(csvLine([k, v == null ? '' : JSON.stringify(v)]));
  }
  // defaultSchedule lives in its own readable section, not the JSON blob.
  for (const k of Object.keys(settingsMap)) {
    if (KNOWN_SETTINGS.includes(k) || k === 'defaultSchedule') continue;
    lines.push(csvLine([k, JSON.stringify(settingsMap[k])]));
  }
  lines.push('');

  // DEFAULT_SCHEDULE — 14 rows, indexed by day-of-period. Times persist even
  // when Enabled=no so re-enabling restores the user's last values.
  lines.push('# Section: DEFAULT_SCHEDULE');
  lines.push('PeriodDay,Weekday,Enabled,StartTime,EndTime');
  const sched = await getDefaultSchedule();
  for (let i = 0; i < 14; i++) {
    const slot = sched[i];
    const weekday = DAYS_LONG[i % 7];
    if (slot) {
      const en = slot.enabled === false ? 'no' : 'yes';
      lines.push(csvLine([i, weekday, en, minToHHMM(slot.startMin), minToHHMM(slot.endMin)]));
    } else {
      lines.push(csvLine([i, weekday, 'no', '', '']));
    }
  }
  lines.push('');

  // ENTRIES — every clock-in record. EndDate is blank if same as Date.
  // LunchMin is the explicit deducted minutes (replaces the boolean Lunch flag,
  // which is kept for human readability and old-file back-compat).
  lines.push('# Section: ENTRIES');
  lines.push('Date,Day,StartTime,EndTime,EndDate,Hours,Lunch,LunchMin,Incomplete,FromDefault,ID');
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
      e.incomplete ? 'yes' : 'no',
      e.fromDefault ? 'yes' : 'no',
      e.id,
    ]));
  }
  lines.push('');

  // LEAVE — one row per date with leave hours.
  lines.push('# Section: LEAVE');
  lines.push('Date,Day,Hours');
  const leaveRows = await db.leave.orderBy('date').toArray();
  for (const l of leaveRows) {
    const d = T.parseLocalDate(l.date);
    lines.push(csvLine([l.date, DAYS_SHORT[d.getDay()], l.hours]));
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
  await db.transaction('rw', db.entries, db.leave, db.settings, async () => {
    await db.entries.clear();
    await db.leave.clear();
    await db.settings.clear();
    await importApplySections(sections);
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
      let idx, enabledCol, startCol, endCol;
      if (isNewFormat) {
        idx = parseInt(r[0], 10);
        if (!isFinite(idx) || idx < 0 || idx >= 14) continue;
        enabledCol = r[2]; startCol = r[3]; endCol = r[4];
      } else {
        const dow = dowMap[(r[0] || '').trim().toLowerCase()];
        if (dow == null) continue;
        idx = dow;                              // legacy first week
        enabledCol = r[1]; startCol = r[2]; endCol = r[3];
      }
      const enabled = String(enabledCol || '').trim().toLowerCase() === 'yes';
      const sm = hhmmToMin(startCol), em = hhmmToMin(endCol);
      if (sm != null && em != null) {
        sched14[idx] = { enabled, startMin: sm, endMin: em };
        if (!isNewFormat) sched14[idx + 7] = { enabled, startMin: sm, endMin: em };
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
      const id = String(get(r, 'id') || '').trim() || uuid();
      await db.entries.put({
        id, date,
        startTime: startIso, endTime: endIso,
        lunchMinutes, lunchDeducted: lunchMinutes > 0,
        incomplete, fromDefault,
      });
    }
  }

  if (sections.LEAVE) {
    const data = sections.LEAVE.slice(1);
    for (const r of data) {
      const date = (r[0] || '').trim();
      const hours = Math.max(0, Math.round(Number(r[2])));
      if (!date || !isFinite(hours) || hours === 0) continue;
      await db.leave.put({ date, hours });
    }
  }
}
