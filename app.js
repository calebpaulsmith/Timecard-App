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
  openEntry: null,        // current clocked-in entry or null
  period: null,           // payPeriodFor output for today (the *current* period)
  viewedPeriodOffset: 0,  // 0 = current, -1 = previous, etc. — used by Period view
  editingDate: null,      // YYYY-MM-DD in the day editor
  editingEntry: null,     // entry object being edited in modal, or null for new
  runningTimer: null,     // setInterval handle
};

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

  // Now load persisted state. If this throws, surface the error rather than dying silently.
  try {
    if (!window.DB) throw new Error('Database library failed to load (offline?). Refresh while online.');
    state.anchor = await DB.getAnchor();
    state.otMode = await DB.getOvertimeMode();
    state.hourlyRate = await DB.getHourlyRate();
    state.openEntry = await DB.getOpenEntry();
  } catch (err) {
    console.error('Failed to load data:', err);
    showToast('Data load error: ' + err.message);
    return;
  }

  // If no anchor yet, nudge to Settings with the most recent Sunday preselected.
  if (!state.anchor) {
    const today = new Date();
    const daysBack = today.getDay(); // Sunday=0
    const sunday = new Date(today);
    sunday.setDate(today.getDate() - daysBack);
    $('anchorInput').value = T.formatLocalDate(sunday);
    $('otToggle').checked = state.otMode;
    setView('settings');
    showToast('Pick your pay-period anchor to get started.');
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
  // Prepopulate select options (hours 1-12, minutes 00/15/30/45)
  for (let h = 1; h <= 12; h++) {
    const hOpt = el('option', { value: h }, String(h));
    const hOpt2 = hOpt.cloneNode(true);
    $('startHour').appendChild(hOpt);
    $('endHour').appendChild(hOpt2);
  }
  for (const m of [0, 15, 30, 45]) {
    const mOpt = el('option', { value: m }, ':' + String(m).padStart(2, '0'));
    const mOpt2 = mOpt.cloneNode(true);
    $('startMin').appendChild(mOpt);
    $('endMin').appendChild(mOpt2);
  }

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
      $('statProj').textContent = T.formatTime(proj);
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
    const start = T.formatTime(state.openEntry.startTime);
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

  for (const d of viewed.days) {
    const dayEntries = (await DB.entriesForDate(d));
    const dayLeave = totals.leaveMap[d] || 0;
    let worked = totals.byDate[d] || 0;
    const { overtime } = T.overtimeSplit(worked, state.otMode);
    const total = worked + dayLeave;
    const date = T.parseLocalDate(d);
    const dow = date.getDay();
    const isToday = d === todayStr;
    const isWeekend = dow === 0 || dow === 6;

    const entrySummary = dayEntries.length
      ? dayEntries.map(e => {
          if (e.incomplete) return 'incomplete';
          if (!e.endTime) return 'in progress';
          return `${T.formatTime(e.startTime)}–${T.formatTime(e.endTime)}`;
        }).join(' · ')
      : (dayLeave > 0 ? `${dayLeave} hr leave` : '—');

    const card = el('div', {
      class: 'day-card' + (isToday ? ' today' : '') + (isWeekend ? ' weekend' : ''),
      onclick: () => openDayEditor(d),
    },
      el('div', { class: 'day-main' },
        el('div', { class: 'day-name' },
          date.toLocaleDateString(undefined, { weekday: 'short' }) + (isToday ? ' · Today' : '')),
        el('div', { class: 'day-date' }, date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })),
        el('div', { class: 'day-entries' }, entrySummary),
      ),
      el('div', {},
        el('div', { class: 'day-hours' }, T.formatHours(total), el('span', { class: 'unit' }, ' hr')),
        state.otMode && overtime > 0
          ? el('div', { class: 'day-ot' }, `+${T.formatHours(overtime)} OT`)
          : null,
      ),
      el('button', {
        class: 'day-plus',
        onclick: async (ev) => {
          ev.stopPropagation();
          await DB.addLeave(d, 1);
          vibrate(8);
          renderPeriodView();
        },
      }, '+'),
    );
    list.appendChild(card);
  }

  // Scroll today's card into view
  const todayEl = list.querySelector('.day-card.today');
  if (todayEl) todayEl.scrollIntoView({ block: 'center', behavior: 'instant' });
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
      meta = `Started ${T.formatTime(e.startTime)} · tap to fix`;
    } else if (!e.endTime) {
      times = `${T.formatTime(e.startTime)} – (in progress)`;
      const now = T.roundToQuarter(new Date());
      meta = `${T.formatHours(T.hoursForEntry(e.startTime, now).hours)} hrs so far`;
    } else {
      const sameDay = T.formatLocalDate(e.startTime) === T.formatLocalDate(e.endTime);
      times = `${T.formatTime(e.startTime)} – ${T.formatTime(e.endTime)}${sameDay ? '' : ' (+1d)'}`;
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
  $('anchorError').textContent = '';
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

function setTimeSelect(prefix, date) {
  let h = date.getHours();
  const m = date.getMinutes();
  const ampm = h >= 12 ? 'PM' : 'AM';
  h = h % 12; if (h === 0) h = 12;
  $(prefix + 'Hour').value = String(h);
  // snap minutes to quarter
  const snap = Math.round(m / 15) * 15 % 60;
  $(prefix + 'Min').value = String(snap);
  $(prefix + 'AmPm').value = ampm;
}

function readTimeSelect(prefix, dateStr) {
  let h = parseInt($(prefix + 'Hour').value, 10);
  const m = parseInt($(prefix + 'Min').value, 10);
  const ampm = $(prefix + 'AmPm').value;
  if (ampm === 'PM' && h !== 12) h += 12;
  if (ampm === 'AM' && h === 12) h = 0;
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
