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
    worked += T.hoursForEntry(e.startTime, e.endTime, e.lunchMinutes).hours;
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
    byDate[e.date] += T.hoursForEntry(e.startTime, e.endTime, e.lunchMinutes).hours;
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

  // Scroll today's card into view after layout settles.
  requestAnimationFrame(() => {
    const todayEl = list.querySelector('.day-card.today');
    if (todayEl) todayEl.scrollIntoView({ block: 'center' });
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
// Wheels are LAZY: only the currently-expanded day mounts scroll-snap pickers
// (iOS Safari can't handle 14 of them at once — they cause the page to crash).
// Collapsed days show plain text and switch into wheel mode on tap.
// Inline editor row under each day card.
// Renders an SVG timeline strip for every day with entries (any number).
// Drag handles on each end of each entry snap to 15-min increments. Empty days
// show an "+ Add work hours" button. Leave-only / incomplete days fall back to
// text summary + tap-to-open the full day editor.
function buildDayEditorRow(d, dayEntries, dayLeave) {
  const drawable = dayEntries.filter(e => !e.incomplete);

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
    wrap.appendChild(buildDayTimeline(d, drawable));
    // Inline lunch stepper: only for the simple case of one closed entry.
    const closedOne = drawable.filter(e => e.endTime).length === 1 && drawable.length === 1
      ? drawable[0] : null;
    if (closedOne && closedOne.endTime) {
      wrap.appendChild(buildLunchStepper(closedOne));
    }
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
// HTML/CSS-based horizontal strip. Children are absolutely positioned with
// percentage `left`/`width` so the layout scales cleanly to any container
// width without the aspect-ratio gymnastics SVG would need.

const TIMELINE_START_MIN = 4 * 60 + 30;  // 4:30 AM
const TIMELINE_END_MIN = 24 * 60;        // midnight (next day's 0:00)
const TIMELINE_RANGE = TIMELINE_END_MIN - TIMELINE_START_MIN;  // 1170 minutes
const SNAP_MIN = 15;

function minutesOfDate(iso) {
  const d = new Date(iso);
  return d.getHours() * 60 + d.getMinutes();
}
function clampToTimeline(mins) {
  return Math.max(TIMELINE_START_MIN, Math.min(TIMELINE_END_MIN, mins));
}
function minToPct(m) {
  return ((m - TIMELINE_START_MIN) / TIMELINE_RANGE) * 100;
}

function buildDayTimeline(dateStr, entries) {
  const wrap = el('div', { class: 'day-timeline' });

  // Ticks at every whole hour (5 AM .. midnight). Major tick + label every 3.
  const firstWholeHour = Math.ceil(TIMELINE_START_MIN / 60) * 60;
  for (let m = firstWholeHour; m <= TIMELINE_END_MIN; m += 60) {
    const isMajor = (m % 180 === 0);
    wrap.appendChild(el('div', {
      class: 'tl-tick' + (isMajor ? ' major' : ''),
      style: `left: ${minToPct(m)}%`,
    }));
    if (isMajor) {
      const h = Math.floor(m / 60) % 24;
      const label = state.use24h
        ? String(h).padStart(2, '0')
        : (h === 0 ? '12' : h === 12 ? '12' : h < 12 ? String(h) : String(h - 12));
      wrap.appendChild(el('div', {
        class: 'tl-label',
        style: `left: ${minToPct(m)}%`,
      }, label));
    }
  }

  // Now-line for today.
  if (dateStr === T.formatLocalDate(new Date())) {
    const nowMin = clampToTimeline(minutesOfDate(new Date()));
    wrap.appendChild(el('div', {
      class: 'tl-now',
      style: `left: ${minToPct(nowMin)}%`,
    }));
  }

  // One shared tooltip per timeline — created on demand by drag handlers.
  const tooltip = el('div', { class: 'tl-tooltip' });
  wrap.appendChild(tooltip);

  // Sort entries by start so overlaps render predictably.
  const sorted = entries.slice().sort((a, b) =>
    new Date(a.startTime) - new Date(b.startTime));
  for (const entry of sorted) {
    drawEntryOnTimeline(wrap, dateStr, entry, tooltip);
  }
  return wrap;
}

function drawEntryOnTimeline(wrap, dateStr, entry, tooltip) {
  const startMin = clampToTimeline(minutesOfDate(entry.startTime));
  const endIso = entry.endTime || new Date().toISOString();
  const endMin = clampToTimeline(minutesOfDate(endIso));
  const inProgress = !entry.endTime;

  const bar = el('div', {
    class: 'tl-bar' + (inProgress ? ' in-progress' : ''),
    style: `left: ${minToPct(startMin)}%; width: ${minToPct(endMin) - minToPct(startMin)}%`,
    onclick: (ev) => {
      // Bar click (outside a handle) opens the day editor.
      ev.stopPropagation();
      openDayEditor(dateStr);
    },
  });
  wrap.appendChild(bar);

  // Lunch gap: rendered as a sibling overlay on the timeline (not inside the
  // bar), positioned in actual minutes so its width matches lunchMinutes.
  // Centered within the entry's worked span.
  const lm = entry.lunchMinutes != null ? entry.lunchMinutes : (entry.lunchDeducted ? 30 : 0);
  if (lm > 0 && endMin > startMin) {
    const lunchStart = (startMin + endMin) / 2 - lm / 2;
    const lunchEnd = lunchStart + lm;
    const lunch = el('div', {
      class: 'tl-lunch',
      style: `left: ${minToPct(lunchStart)}%; width: ${minToPct(lunchEnd) - minToPct(lunchStart)}%`,
      title: `${lm}-min lunch`,
      onclick: (ev) => {
        ev.stopPropagation();
        openDayEditor(dateStr);
      },
    });
    wrap.appendChild(lunch);
  }

  const refs = { bar, tooltip, entry, dateStr };
  if (!inProgress) addHandle(wrap, 'start', startMin, refs);
  addHandle(wrap, 'end', endMin, refs);
}

function addHandle(wrap, which, atMin, refs) {
  // The visible knob and the larger invisible hit-target share a position;
  // the hit element gets the pointer events.
  const knob = el('div', {
    class: 'tl-handle tl-handle-' + which,
    style: `left: ${minToPct(atMin)}%`,
  });
  const hit = el('div', {
    class: 'tl-hit',
    style: `left: ${minToPct(atMin)}%`,
  });
  attachHandleDrag(wrap, hit, knob, which, refs);
  // Append knob first so hit ends up on top (catches taps even over the bar).
  wrap.appendChild(knob);
  wrap.appendChild(hit);
}

function attachHandleDrag(wrap, hit, knob, which, refs) {
  let dragging = false;
  let startClientX = 0;
  let originMin = 0;
  let oppMin = 0;
  let widthPx = 1;
  let curMin = 0;

  const onMove = (ev) => {
    if (!dragging) return;
    ev.preventDefault();
    const dxPx = ev.clientX - startClientX;
    const dMin = Math.round((dxPx / widthPx * TIMELINE_RANGE) / SNAP_MIN) * SNAP_MIN;
    let m = originMin + dMin;
    if (which === 'start') m = Math.min(oppMin - SNAP_MIN, Math.max(TIMELINE_START_MIN, m));
    else                   m = Math.max(oppMin + SNAP_MIN, Math.min(TIMELINE_END_MIN, m));
    curMin = m;
    const pct = minToPct(m);
    knob.style.left = pct + '%';
    hit.style.left = pct + '%';
    const startMin = which === 'start' ? m : oppMin;
    const endMin = which === 'end' ? m : oppMin;
    refs.bar.style.left = minToPct(startMin) + '%';
    refs.bar.style.width = (minToPct(endMin) - minToPct(startMin)) + '%';
    refs.tooltip.textContent = T.formatMinutes(m, state.use24h);
    refs.tooltip.style.left = pct + '%';
    refs.tooltip.classList.add('visible');
  };

  const onUp = async (ev) => {
    if (!dragging) return;
    dragging = false;
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
    startClientX = ev.clientX;
    originMin = which === 'start' ? minutesOfDate(refs.entry.startTime)
                                  : (refs.entry.endTime ? minutesOfDate(refs.entry.endTime) : minutesOfDate(new Date()));
    oppMin = which === 'start' ? minutesOfDate(refs.entry.endTime || new Date())
                               : minutesOfDate(refs.entry.startTime);
    widthPx = wrap.getBoundingClientRect().width || 1;
    curMin = originMin;
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
      const h = T.hoursForEntry(e.startTime, e.endTime, e.lunchMinutes).hours;
      const lm = e.lunchMinutes != null ? e.lunchMinutes : (e.lunchDeducted ? 30 : 0);
      meta = `${T.formatHours(h)} hrs` + (lm > 0 ? ` (−${lm} min lunch)` : '');
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
  // Lunch — falls back to 30 if the legacy lunchDeducted flag is true and
  // lunchMinutes hasn't been set yet.
  const lm = entry && entry.lunchMinutes != null
    ? entry.lunchMinutes
    : (entry && entry.lunchDeducted ? 30 : 30);
  $('lunchMinutesSelect').value = String(lm);
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
    lunchMinutes: Number($('lunchMinutesSelect').value) || 0,
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
