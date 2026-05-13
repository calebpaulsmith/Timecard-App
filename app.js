// app.js — UI layer for the Maxiflex tracker.
// Depends on window.TimeUtil (time.js) and window.DB (db.js).
// Wrapped in an IIFE so its top-level `const`s (T, DB, state) don't collide with
// the shared "script scope" across <script> tags — db.js also declares `const T`.

(function () {
'use strict';

const T = window.TimeUtil;
const DB = window.DB;

const state = {
  anchor: null,           // YYYY-MM-DD
  otMode: false,
  hourlyRate: 0,          // $/hour straight-time
  use24h: false,
  defaultSchedule: [null, null, null, null, null, null, null], // Sun..Sat
  openEntry: null,        // current clocked-in entry or null
  period: null,           // payPeriodFor output for today (the *current* period)
  viewedPeriodOffset: 0,  // 0 = current, -1 = previous, etc. — used by Period view
  editingDate: null,      // YYYY-MM-DD in the day editor
  editingEntry: null,     // entry object being edited in modal, or null for new
  runningTimer: null,     // setInterval handle
};

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

// Computes totals for one day: { worked, leave, total, regular, overtime, entries }
async function dayTotals(yyyymmdd, otMode) {
  const entries = await DB.entriesForDate(yyyymmdd);
  const leave = await DB.getLeave(yyyymmdd);
  let worked = 0;
  for (const e of entries) {
    if (e.incomplete) continue;
    if (!e.endTime) continue;          // in-progress contributes via dedicated path
    worked += T.hoursForEntry(e.startTime, e.endTime).hours;
  }
  const { regular, overtime } = T.overtimeSplit(worked, otMode);
  return { worked, leave, total: worked + leave, regular, overtime, entries };
}

// Today includes the running in-progress entry's live elapsed.
async function todayTotalsLive(yyyymmdd, otMode) {
  const base = await dayTotals(yyyymmdd, otMode);
  if (state.openEntry && state.openEntry.date === yyyymmdd) {
    const now = T.roundToQuarter(new Date());
    const { hours } = T.hoursForEntry(state.openEntry.startTime, now);
    base.worked += hours;
    base.total += hours;
    const split = T.overtimeSplit(base.worked, otMode);
    base.regular = split.regular;
    base.overtime = split.overtime;
  }
  return base;
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
// Always uses the current `otMode` toggle to compute OT (if off, returns zeros).
async function ytdOvertime(year) {
  if (!state.otMode) return { hours: 0, dollars: 0 };
  const periods = await allPeriodsWithData();
  let hours = 0;
  for (const p of periods) {
    if (T.paydateYear(p) !== year) continue;
    const t = await periodTotals(p, true);
    hours += t.ot;
  }
  return { hours, dollars: hours * state.hourlyRate * T.OT_MULTIPLIER };
}

// Totals for the whole pay period
async function periodTotals(period, otMode) {
  const entries = await DB.entriesForPeriod(period);
  const leaveMap = await DB.leaveForPeriod(period);
  // Group worked by date for OT split
  const byDate = {};
  for (const d of period.days) byDate[d] = 0;
  for (const e of entries) {
    if (e.incomplete || !e.endTime) continue;
    if (!(e.date in byDate)) continue;
    byDate[e.date] += T.hoursForEntry(e.startTime, e.endTime).hours;
  }
  // Add live hours to today if applicable
  const todayStr = T.formatLocalDate(new Date());
  if (state.openEntry && state.openEntry.date === todayStr && todayStr in byDate) {
    const now = T.roundToQuarter(new Date());
    byDate[todayStr] += T.hoursForEntry(state.openEntry.startTime, now).hours;
  }
  let worked = 0, ot = 0, leave = 0;
  for (const d of period.days) {
    worked += byDate[d];
    const split = T.overtimeSplit(byDate[d], otMode);
    ot += split.overtime;
    leave += (leaveMap[d] || 0);
  }
  return { worked, ot, leave, total: worked + leave, byDate, leaveMap };
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
    state.otMode = await DB.getOvertimeMode();
    state.hourlyRate = await DB.getHourlyRate();
    state.use24h = await DB.getUse24h();
    state.defaultSchedule = await DB.getDefaultSchedule();
    state.openEntry = await DB.getOpenEntry();
  } catch (err) {
    console.error('Failed to load data:', err);
    showToast('Data load error: ' + err.message);
    return;
  }

  await renderAll();
}

function wireGlobalEvents() {
  // Navigation
  document.body.addEventListener('click', (ev) => {
    const t = ev.target.closest('[data-goto]');
    if (!t) return;
    const dest = t.dataset.goto;
    // When entering Period view via nav, default to the current period.
    if (dest === 'period') state.viewedPeriodOffset = 0;
    setView(dest);
    if (dest === 'period') renderPeriodView();
    if (dest === 'home') renderHome();
    if (dest === 'settings') renderSettings();
  });

  $('prevPeriod').addEventListener('click', () => {
    state.viewedPeriodOffset -= 1;
    renderPeriodView();
  });
  $('nextPeriod').addEventListener('click', () => {
    if (state.viewedPeriodOffset >= 0) return; // never go past today's period
    state.viewedPeriodOffset += 1;
    renderPeriodView();
  });

  $('clockBtn').addEventListener('click', onClockToggle);
  $('leaveBtn').addEventListener('click', async () => {
    const today = T.formatLocalDate(new Date());
    const prev = await DB.getLeave(today);
    const next = await DB.addLeave(today, 1);
    showToast(`Added leave hour. Total: ${next} hr${next === 1 ? '' : 's'}`, async () => {
      await DB.setLeaveHours(today, prev);
      renderAll();
    });
    vibrate(10);
    renderAll();
  });

  $('addEntryBtn').addEventListener('click', () => openEntryModal(null));
  $('leavePlus').addEventListener('click', async () => {
    const d = state.editingDate;
    await DB.addLeave(d, 1);
    vibrate(8);
    renderDayView();
  });
  $('leaveMinus').addEventListener('click', async () => {
    const d = state.editingDate;
    const prev = await DB.getLeave(d);
    if (prev === 0) return;
    await DB.setLeaveHours(d, prev - 1);
    showToast('Removed leave hour', async () => {
      await DB.setLeaveHours(d, prev);
      renderDayView();
    });
    vibrate(8);
    renderDayView();
  });

  $('anchorInput').addEventListener('change', onAnchorChange);
  $('otToggle').addEventListener('change', async (ev) => {
    state.otMode = ev.target.checked;
    await DB.setOvertimeMode(state.otMode);
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

  // Default schedule
  $('applyScheduleBtn').addEventListener('click', onApplyDefaultSchedule);

  // Backup / restore
  $('exportBtn').addEventListener('click', onExport);
  $('importBtn').addEventListener('click', () => $('importFile').click());
  $('importFile').addEventListener('change', onImport);

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

// --- Rendering --------------------------------------------------------------

async function renderAll() {
  await renderHome();
  if (document.body.dataset.view === 'period') await renderPeriodView();
  if (document.body.dataset.view === 'day') await renderDayView();
}

async function renderHome() {
  if (!state.anchor) {
    $('heroRemaining').textContent = '—';
    $('statWorked').textContent = '—';
    $('statDaysLeft').textContent = '—';
    $('statPace').textContent = '—';
    $('statToday').textContent = '—';
    $('clockStatus').textContent = 'Set an anchor date in Settings first.';
    $('clockBtn').disabled = true;
    return;
  }
  $('clockBtn').disabled = false;
  state.period = T.payPeriodFor(new Date(), state.anchor);
  const totals = await periodTotals(state.period, state.otMode);
  const remaining = Math.max(0, T.PAY_PERIOD_TARGET - totals.total);
  const daysLeft = T.PAY_PERIOD_DAYS - state.period.dayIndex;
  const paceHrs = T.pace(totals.total, daysLeft);
  const status = T.paceStatus(totals.total, state.period.dayIndex);

  $('heroRemaining').textContent = T.formatHours(remaining);

  const badge = $('statusBadge');
  badge.className = 'status-badge ' + status;
  badge.textContent = status === 'on-pace' ? 'On pace' : status[0].toUpperCase() + status.slice(1);

  $('statWorked').textContent = T.formatHours(totals.total);
  $('statDaysLeft').textContent = String(daysLeft);
  $('statPace').textContent = T.formatHours(paceHrs) + '/d';

  // Today's live total
  const todayStr = T.formatLocalDate(new Date());
  const today = await todayTotalsLive(todayStr, state.otMode);
  $('statToday').textContent = T.formatHours(today.total);

  // OT stat
  $('statOTWrap').hidden = !state.otMode;
  if (state.otMode) $('statOT').textContent = T.formatHours(totals.ot);

  // OT $ this period — shown when otMode is on AND hourly rate is set.
  const showMoney = state.otMode && state.hourlyRate > 0;
  $('statOTPayWrap').hidden = !showMoney;
  if (showMoney) {
    $('statOTPay').textContent = T.formatMoney(totals.ot * state.hourlyRate * T.OT_MULTIPLIER);
  }

  // YTD OT $ — sums every past period whose paydate falls in this calendar year.
  $('statYTDWrap').hidden = !showMoney;
  if (showMoney) {
    const currentYear = new Date().getFullYear();
    const ytd = await ytdOvertime(currentYear);
    $('statYTDLabel').textContent = `${currentYear} OT $`;
    $('statYTD').textContent = T.formatMoney(ytd.dollars);
  }

  // Projected clock-out: when to end current entry so today's WORKED hours hit 8.
  const projWrap = $('statProjWrap');
  if (state.openEntry) {
    // Prior worked hours today (other closed entries this date).
    const prior = await dayTotals(todayStr, state.otMode);
    const alreadyToday = prior.worked; // closed entries only
    const targetForThisEntry = 8 - alreadyToday;
    if (targetForThisEntry > 0) {
      const proj = T.projectedClockOut(state.openEntry.startTime, targetForThisEntry);
      projWrap.hidden = false;
      $('statProj').textContent = T.formatTime(proj, state.use24h);
    } else {
      projWrap.hidden = true;
    }
  } else {
    projWrap.hidden = true;
  }

  // Clock button state
  const btn = $('clockBtn');
  if (state.openEntry) {
    btn.textContent = 'Clock Out';
    btn.classList.add('clocked-in');
    const start = T.formatTime(state.openEntry.startTime, state.use24h);
    const live = T.hoursForEntry(state.openEntry.startTime, T.roundToQuarter(new Date()));
    $('clockStatus').textContent = `Clocked in at ${start} · ${T.formatHours(live.hours)} hrs`;
  } else {
    btn.textContent = 'Clock In';
    btn.classList.remove('clocked-in');
    $('clockStatus').textContent = '';
  }
}

// Queue of (wheelEl, scrollTop) pairs to apply after the period list is in the DOM.
// scroll-snap needs the element laid out before we set scrollTop, otherwise the
// browser ignores the assignment.
const wheelInitQueue = [];

async function renderPeriodView() {
  if (!state.anchor) { setView('settings'); return; }
  // Resolve the period being viewed (offset from today's period).
  const viewed = T.payPeriodOffset(new Date(), state.anchor, state.viewedPeriodOffset);
  const totals = await periodTotals(viewed, state.otMode);
  const startStr = T.formatDateShort(viewed.days[0]);
  const endStr = T.formatDateShort(viewed.days[13]);
  const name = T.payPeriodName(viewed, state.anchor);
  const paydate = T.paydateFor(viewed);

  $('periodTitle').textContent = state.viewedPeriodOffset === 0 ? 'Pay Period' : 'Past Period';
  $('periodName').textContent = name;
  $('periodPaydate').textContent = `Paydate: ${paydate.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}`;

  // Disable forward nav once we've returned to today (no future periods).
  $('nextPeriod').disabled = state.viewedPeriodOffset >= 0;

  const otText = state.otMode ? ` · ${T.formatHours(totals.ot)} OT` : '';
  const otPayText = state.otMode && state.hourlyRate > 0
    ? ` · ${T.formatMoney(totals.ot * state.hourlyRate * T.OT_MULTIPLIER)} OT pay`
    : '';
  $('periodMeta').innerHTML = '';
  $('periodMeta').appendChild(document.createTextNode(
    `${startStr} – ${endStr} · ${T.formatHours(totals.total)} / 80 hrs${otText}`));
  if (otPayText) {
    const otLine = el('span', { class: 'ot-line' }, otPayText.replace(/^ · /, ''));
    $('periodMeta').appendChild(otLine);
  }

  const todayStr = T.formatLocalDate(new Date());
  const list = $('dayList');
  list.innerHTML = '';
  wheelInitQueue.length = 0;

  // Hoist per-day entry/leave lookups so card builder can stay synchronous.
  const allEntries = await DB.entriesForPeriod(viewed);
  const entriesByDate = {};
  for (const d of viewed.days) entriesByDate[d] = [];
  for (const e of allEntries) {
    if (entriesByDate[e.date]) entriesByDate[e.date].push(e);
  }

  for (const d of viewed.days) {
    list.appendChild(buildDayCard(d, totals, todayStr, entriesByDate[d]));
  }

  // Wheels were appended; now apply their initial scroll positions.
  // requestAnimationFrame waits for layout so scrollTop sticks.
  requestAnimationFrame(() => {
    for (const [wheelEl, top] of wheelInitQueue) wheelEl.scrollTop = top;
    wheelInitQueue.length = 0;
    // Scroll today's card into view
    const todayEl = list.querySelector('.day-card.today');
    if (todayEl) todayEl.scrollIntoView({ block: 'center', behavior: 'instant' });
  });
}

function buildDayCard(d, totals, todayStr, dayEntries) {
  const dayWorked = totals.byDate[d] || 0;
  const dayLeave = totals.leaveMap[d] || 0;
  const { overtime } = T.overtimeSplit(dayWorked, state.otMode);
  const total = dayWorked + dayLeave;
  const date = T.parseLocalDate(d);
  const dow = date.getDay();
  const isToday = d === todayStr;
  const isWeekend = dow === 0 || dow === 6;

  const card = el('div', {
    class: 'day-card' + (isToday ? ' today' : '') + (isWeekend ? ' weekend' : ''),
  });

  const header = el('div', { class: 'day-header' },
    el('div', { class: 'day-main', onclick: () => openDayEditor(d) },
      el('div', { class: 'day-name' },
        date.toLocaleDateString(undefined, { weekday: 'short' }) + (isToday ? ' · Today' : '')),
      el('div', { class: 'day-date' }, date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })),
    ),
    el('div', { class: 'day-totals', onclick: () => openDayEditor(d) },
      el('div', { class: 'day-hours' }, T.formatHours(total), el('span', { class: 'unit' }, ' hr')),
      state.otMode && overtime > 0
        ? el('div', { class: 'day-ot' }, `+${T.formatHours(overtime)} OT`)
        : null,
    ),
    el('button', {
      class: 'day-plus',
      title: 'Add 1 leave hour',
      onclick: async (ev) => {
        ev.stopPropagation();
        await DB.addLeave(d, 1);
        vibrate(8);
        renderPeriodView();
      },
    }, '+'),
  );
  card.appendChild(header);
  card.appendChild(buildDayEditorRow(d, dayEntries, dayLeave));
  return card;
}

// Inline editor row under each day card.
// 0 entries, no leave: "+ Add" button (uses default schedule for this weekday, else 9-5).
// 1 closed entry, no leave: inline scroll-wheel pickers for start/end.
// Anything else (multi entries, in-progress, leave-only, incomplete): summary text.
function buildDayEditorRow(d, dayEntries, dayLeave) {
  const closed = dayEntries.filter(e => !e.incomplete && e.endTime);

  if (dayEntries.length === 0 && dayLeave === 0) {
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

  if (closed.length === 1 && dayLeave === 0 && dayEntries.length === 1) {
    return el('div', { class: 'day-editor' }, buildInlineEditor(d, closed[0]));
  }

  // Fallback: summary + tap-to-open
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
  const dow = T.parseLocalDate(dateStr).getDay();
  const slot = state.defaultSchedule[dow] || { startMin: 9 * 60, endMin: 17 * 60 };
  const startTime = T.buildDateTime(dateStr, Math.floor(slot.startMin / 60), slot.startMin % 60);
  const endTime = T.buildDateTime(dateStr, Math.floor(slot.endMin / 60), slot.endMin % 60);
  await DB.upsertEntry({
    date: dateStr,
    startTime: startTime.toISOString(),
    endTime: endTime.toISOString(),
    incomplete: false,
  });
}

// Save a single field of an entry, debounced per-entry to avoid hammering the DB
// while the user is scrolling. Re-renders the period view after the save.
const inlineSaveTimers = new Map();
function scheduleInlineSave(entry) {
  const id = entry.id;
  clearTimeout(inlineSaveTimers.get(id));
  inlineSaveTimers.set(id, setTimeout(async () => {
    inlineSaveTimers.delete(id);
    const start = new Date(entry.startTime);
    const end = new Date(entry.endTime);
    if (end <= start) {
      showToast('End must be after start');
      return;
    }
    await DB.upsertEntry(entry);
    if (state.openEntry && state.openEntry.id === entry.id) {
      state.openEntry = null;
    }
    renderPeriodView();
  }, 250));
}

function buildInlineEditor(dateStr, entry) {
  const row = el('div', { class: 'inline-time-row' });
  row.appendChild(buildTimeWheels(new Date(entry.startTime), (newDate) => {
    entry.startTime = newDate.toISOString();
    scheduleInlineSave(entry);
  }));
  row.appendChild(el('span', { class: 'inline-sep' }, '–'));
  row.appendChild(buildTimeWheels(new Date(entry.endTime), (newDate) => {
    entry.endTime = newDate.toISOString();
    scheduleInlineSave(entry);
  }));
  row.appendChild(el('button', {
    class: 'inline-delete-btn',
    title: 'Delete entry',
    onclick: async (ev) => {
      ev.stopPropagation();
      await DB.deleteEntry(entry.id);
      if (state.openEntry && state.openEntry.id === entry.id) state.openEntry = null;
      renderPeriodView();
    },
  }, '×'));
  return row;
}

// Build a triplet of scroll wheels (hour, min, am/pm) — or doublet in 24h mode.
// onChange fires whenever any wheel snaps to a new value, with a freshly built Date.
function buildTimeWheels(date, onChange) {
  const dateStr = T.formatLocalDate(date);
  const cur = {
    h: date.getHours(),
    m: Math.round(date.getMinutes() / 15) * 15 % 60,
  };
  const wrap = el('div', { class: 'time-wheels' });
  const fire = () => onChange(T.buildDateTime(dateStr, cur.h, cur.m));

  if (state.use24h) {
    const vals = Array.from({ length: 24 }, (_, i) => String(i).padStart(2, '0'));
    wrap.appendChild(createScrollWheel(vals, String(cur.h).padStart(2, '0'), (v) => {
      cur.h = Number(v);
      fire();
    }));
  } else {
    const vals = ['12','1','2','3','4','5','6','7','8','9','10','11'];
    let h12 = cur.h % 12; if (h12 === 0) h12 = 12;
    wrap.appendChild(createScrollWheel(vals, String(h12), (v) => {
      let n = Number(v);
      const pm = cur.h >= 12;
      if (n === 12) n = pm ? 12 : 0;
      else if (pm) n += 12;
      cur.h = n;
      fire();
    }));
  }

  const mVals = ['00','15','30','45'];
  wrap.appendChild(createScrollWheel(mVals, String(cur.m).padStart(2, '0'), (v) => {
    cur.m = Number(v);
    fire();
  }));

  if (!state.use24h) {
    wrap.appendChild(createScrollWheel(['AM','PM'], cur.h >= 12 ? 'PM' : 'AM', (v) => {
      if (v === 'PM' && cur.h < 12) cur.h += 12;
      else if (v === 'AM' && cur.h >= 12) cur.h -= 12;
      fire();
    }));
  }

  return wrap;
}

// iOS-style scroll-snap picker. Returns a scrollable column; the centered item
// is the selected value. Snapping + debounced onChange.
const WHEEL_ITEM_H = 32;
function createScrollWheel(values, initialValue, onChange) {
  const wheel = el('div', { class: 'wheel' });
  const inner = el('ul', { class: 'wheel-inner' });
  for (const v of values) {
    inner.appendChild(el('li', { dataset: { value: String(v) } }, String(v)));
  }
  wheel.appendChild(inner);
  // Prevent card-tap when user is interacting with the wheel.
  wheel.addEventListener('click', (ev) => ev.stopPropagation());
  const idx = Math.max(0, values.findIndex(v => String(v) === String(initialValue)));
  wheelInitQueue.push([wheel, idx * WHEEL_ITEM_H]);

  let timer;
  wheel.addEventListener('scroll', () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      const raw = wheel.scrollTop / WHEEL_ITEM_H;
      const i = Math.max(0, Math.min(values.length - 1, Math.round(raw)));
      // Snap exactly (some browsers leave a sub-pixel offset).
      if (Math.abs(wheel.scrollTop - i * WHEEL_ITEM_H) > 0.5) {
        wheel.scrollTop = i * WHEEL_ITEM_H;
      }
      onChange(values[i]);
    }, 140);
  });
  return wheel;
}

async function openDayEditor(yyyymmdd) {
  state.editingDate = yyyymmdd;
  setView('day');
  await renderDayView();
}

async function renderDayView() {
  const d = state.editingDate;
  if (!d) return;
  $('dayTitle').textContent = T.formatDateShort(d);

  const totals = state.openEntry && state.openEntry.date === d
    ? await todayTotalsLive(d, state.otMode)
    : await dayTotals(d, state.otMode);

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
  if (state.otMode) {
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
      const h = T.hoursForEntry(e.startTime, e.endTime).hours;
      meta = `${T.formatHours(h)} hrs` + (e.lunchDeducted ? ' (−0.5 lunch)' : '');
    }
    list.appendChild(el('div', { class: 'entry-card' },
      el('div', {},
        el('div', { class: 'entry-times' }, times),
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

  $('leaveCount').textContent = String(totals.leave);
}

async function renderSettings() {
  if (state.anchor) $('anchorInput').value = state.anchor;
  $('otToggle').checked = state.otMode;
  $('hourlyRateInput').value = state.hourlyRate > 0 ? String(state.hourlyRate) : '';
  $('use24hToggle').checked = state.use24h;
  $('anchorError').textContent = '';
  renderScheduleGrid();
}

// 7 day-rows: checkbox (work this day) + start/end <input type="time">.
// Stored in state.defaultSchedule and not persisted until "Save & apply" is hit.
function renderScheduleGrid() {
  const grid = $('scheduleGrid');
  grid.innerHTML = '';
  for (let dow = 0; dow < 7; dow++) {
    const slot = state.defaultSchedule[dow];
    const enabled = !!slot;
    const startMin = slot ? slot.startMin : 9 * 60;
    const endMin = slot ? slot.endMin : 17 * 60;

    const row = el('div', { class: 'schedule-row' + (enabled ? '' : ' off') });
    const enableBox = el('input', {
      type: 'checkbox',
      class: 'schedule-enable',
      onchange: (ev) => {
        const on = ev.target.checked;
        if (on) {
          state.defaultSchedule[dow] = { startMin, endMin };
        } else {
          state.defaultSchedule[dow] = null;
        }
        renderScheduleGrid();
      },
    });
    if (enabled) enableBox.checked = true;

    const label = el('label', { class: 'schedule-day' }, DAY_NAMES[dow]);

    const startIn = el('input', {
      type: 'time',
      class: 'schedule-time',
      value: minutesToTimeInput(startMin),
      onchange: (ev) => {
        const mins = timeInputToMinutes(ev.target.value);
        if (mins == null) return;
        const cur = state.defaultSchedule[dow] || { startMin, endMin };
        state.defaultSchedule[dow] = { startMin: mins, endMin: cur.endMin };
      },
    });
    const sep = el('span', { class: 'schedule-sep' }, '–');
    const endIn = el('input', {
      type: 'time',
      class: 'schedule-time',
      value: minutesToTimeInput(endMin),
      onchange: (ev) => {
        const mins = timeInputToMinutes(ev.target.value);
        if (mins == null) return;
        const cur = state.defaultSchedule[dow] || { startMin, endMin };
        state.defaultSchedule[dow] = { startMin: cur.startMin, endMin: mins };
      },
    });
    if (!enabled) {
      startIn.disabled = true;
      endIn.disabled = true;
    }

    row.appendChild(enableBox);
    row.appendChild(label);
    row.appendChild(startIn);
    row.appendChild(sep);
    row.appendChild(endIn);
    grid.appendChild(row);
  }
}

function minutesToTimeInput(m) {
  // Always emit 24h HH:MM for the native <input type="time"> regardless of use24h.
  const h = Math.floor(m / 60) % 24;
  const min = m % 60;
  return `${String(h).padStart(2, '0')}:${String(min).padStart(2, '0')}`;
}
function timeInputToMinutes(s) {
  if (!s) return null;
  const [h, m] = s.split(':').map(Number);
  if (!isFinite(h) || !isFinite(m)) return null;
  // Snap to 15 min so schedule entries are clean quarters.
  const snapped = Math.round((h * 60 + m) / 15) * 15;
  return Math.max(0, Math.min(24 * 60 - 15, snapped));
}

async function onExport() {
  try {
    const csv = await DB.exportToCsv();
    const today = T.formatLocalDate(new Date());
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `maxiflex-export-${today}.csv`;
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
    state.otMode = await DB.getOvertimeMode();
    state.hourlyRate = await DB.getHourlyRate();
    state.use24h = await DB.getUse24h();
    state.defaultSchedule = await DB.getDefaultSchedule();
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
    const count = await DB.applyDefaultSchedule(
      state.defaultSchedule, startPeriod, state.anchor, 26);
    // Clocked-in entry may have been wiped; refresh.
    state.openEntry = await DB.getOpenEntry();
    $('scheduleStatus').textContent = `Filled ${count} day${count === 1 ? '' : 's'} across the next year.`;
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

function openEntryModal(entry) {
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
  $('entryModal').hidden = false;
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
    incomplete: false,
  };
  await DB.upsertEntry(entry);
  // If the edited entry was the open one, the edit implicitly closes it.
  if (state.openEntry && state.openEntry.id === entry.id) {
    state.openEntry = null;
  }
  closeEntryModal();
  showToast('Entry saved');
  await renderAll();
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
