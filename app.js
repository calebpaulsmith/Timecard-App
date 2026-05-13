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
  otMode: true,           // 8h overtime mode (default on)
  hourlyRate: 0,          // $/hour straight-time
  use24h: false,
  showWeekends: false,    // legacy/global Sat-Sun visibility — kept for the schedule view's behavior (no longer used by period view)
  shownWeekends: {},      // per-period weekend reveal: { [periodStartDate]: [dayIndex,...] }
  validationDay: null,    // 0..13 day-of-period or null (timecard validation deadline)
  defaultSchedule: Array.from({ length: 14 }, () => null),  // 14 days of period
  openEntry: null,        // current clocked-in entry or null
  period: null,           // payPeriodFor output for today (the *current* period)
  viewedPeriodOffset: 0,  // 0 = current, -1 = previous, etc.
  viewedPage: 1,          // 0 = Home, 1 = Week 1, 2 = Week 2 — carousel scroll position
  viewedWeek: 1,          // 1 or 2 — kept for the schedule view (still uses tabs)
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
    state.showWeekends = !!(await DB.getSetting('showWeekends', false));
    state.shownWeekends = (await DB.getSetting('shownWeekends', null)) || {};
    state.validationDay = await DB.getValidationDay();
    state.defaultSchedule = await DB.getDefaultSchedule();
    // First-launch: persist the Mon-Fri-on defaults so any toggle the user
    // flips (e.g., turning Wed off) sticks across reloads.
    if ((await DB.getSetting('defaultSchedule', null)) == null) {
      await DB.setDefaultSchedule(state.defaultSchedule);
    }
    state.openEntry = await DB.getOpenEntry();
  } catch (err) {
    console.error('Failed to load data:', err);
    showToast('Data load error: ' + err.message);
    return;
  }

  // Land the carousel on whichever week contains today.
  if (state.anchor) {
    const today = new Date();
    const period = T.payPeriodFor(today, state.anchor);
    state.viewedPage = period.dayIndex < 7 ? 1 : 2;
  } else {
    state.viewedPage = 1;
  }

  await renderAll();
  scrollCarouselTo(state.viewedPage, /*instant*/ true);
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
      renderHome();
      renderPeriodPages();
      requestAnimationFrame(() => scrollCarouselTo(state.viewedPage, true));
    }
    if (dest === 'settings') renderSettings();
    if (dest === 'schedule') renderScheduleView();
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

  // Page dots: tap to jump to that carousel page.
  $('pageDots').addEventListener('click', (ev) => {
    const dot = ev.target.closest('.dot');
    if (!dot) return;
    const idx = Number(dot.dataset.pageIdx);
    if (idx >= 0 && idx <= 2) scrollCarouselTo(idx, false);
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
  $('copyDayBtn').addEventListener('click', onCopyDayToWeekdays);
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
  $('importBtn').addEventListener('click', () => $('importFile').click());
  $('importFile').addEventListener('change', onImport);

  // Danger zone
  $('clearAllBtn').addEventListener('click', onClearAll);

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

// Count Mon-Fri days remaining in the period (today inclusive). For an 8h
// schedule this is the relevant "days left" metric — Saturdays/Sundays don't
// count toward the 80-hour target.
function countWeekdaysRemaining(period) {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  let count = 0;
  for (let i = period.dayIndex; i < T.PAY_PERIOD_DAYS; i++) {
    const d = T.parseLocalDate(period.days[i]);
    const dow = d.getDay();
    if (dow >= 1 && dow <= 5) count++;
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
  await renderHome();
  if (document.body.dataset.view === 'main') await renderPeriodPages();
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

  // Weekday days-remaining in the period (Mon..Fri only).
  const weekdaysLeft = countWeekdaysRemaining(state.period);
  const paceHrs = T.pace(totals.total, Math.max(1, weekdaysLeft));
  const status = T.paceStatus(totals.total, state.period.dayIndex);

  // Hero: in 8h mode show OT this period (the user's primary number for that
  // mode). Otherwise the classic "hours remaining" hero.
  if (state.otMode) {
    $('heroLabel').textContent = 'OT this period';
    $('heroRemaining').textContent = T.formatHours(totals.ot);
  } else {
    $('heroLabel').textContent = 'Hours left this period';
    $('heroRemaining').textContent = T.formatHours(remaining);
  }

  // Status badge — only meaningful in non-8h mode (pace tracking). In 8h mode
  // the user doesn't care about "ahead / on-pace / behind" since OT is the
  // measure.
  const badge = $('statusBadge');
  if (state.otMode) {
    badge.hidden = true;
  } else {
    badge.hidden = false;
    badge.className = 'status-badge ' + status;
    badge.textContent = status === 'on-pace' ? 'On pace' : status[0].toUpperCase() + status.slice(1);
  }

  $('statWorked').textContent = T.formatHours(totals.total);
  $('statDaysLeft').textContent = String(weekdaysLeft);

  // Pace stat: hidden in 8h mode (per request).
  const paceWrap = $('statPace').parentElement;
  paceWrap.hidden = state.otMode;
  if (!state.otMode) $('statPace').textContent = T.formatHours(paceHrs) + '/d';

  // Today's live total
  const todayStr = T.formatLocalDate(new Date());
  const today = await todayTotalsLive(todayStr, state.otMode);
  $('statToday').textContent = T.formatHours(today.total);

  // "OT this period" stat card — hidden in 8h mode because the HERO already
  // shows the period's OT number; only shown if OT mode is OFF (kept never-
  // really-shown since OT mode is on by default — but kept consistent here).
  $('statOTWrap').hidden = true;

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

// Render BOTH week pages (Week 1 and Week 2 of the current period offset).
// Each page in the carousel gets its own period nav + meta + day list.
async function renderPeriodPages() {
  if (!state.anchor) return;
  const viewed = T.payPeriodOffset(new Date(), state.anchor, state.viewedPeriodOffset);
  const totals = await periodTotals(viewed, state.otMode);
  const startStr = T.formatDateShort(viewed.days[0]);
  const endStr = T.formatDateShort(viewed.days[13]);
  const name = T.payPeriodName(viewed, state.anchor);
  const paydate = T.paydateFor(viewed);
  const paydateStr = `Paydate: ${paydate.toLocaleDateString(undefined,
    { month: 'short', day: 'numeric', year: 'numeric' })}`;

  for (const wk of [1, 2]) {
    $('periodName' + 'W' + wk).textContent = name;
    $('periodPaydateW' + wk).textContent = paydateStr;

    // OT pay text on the meta line stays on both pages.
    const otText = state.otMode ? ` · ${T.formatHours(totals.ot)} OT` : '';
    const otPayText = state.otMode && state.hourlyRate > 0
      ? ` · ${T.formatMoney(totals.ot * state.hourlyRate * T.OT_MULTIPLIER)} OT pay`
      : '';
    const metaEl = $('periodMetaW' + wk);
    metaEl.innerHTML = '';
    metaEl.appendChild(document.createTextNode(
      `${startStr} – ${endStr} · ${T.formatHours(totals.total)} / 80 hrs${otText}`));
    if (otPayText) {
      metaEl.appendChild(el('span', { class: 'ot-line' }, otPayText.replace(/^ · /, '')));
    }
  }

  const todayStr = T.formatLocalDate(new Date());
  const allEntries = await DB.entriesForPeriod(viewed);
  const entriesByDate = {};
  for (const d of viewed.days) entriesByDate[d] = [];
  for (const e of allEntries) {
    if (entriesByDate[e.date]) entriesByDate[e.date].push(e);
  }

  for (const wk of [1, 2]) {
    const list = $('dayListW' + wk);
    list.innerHTML = '';
    const weekStart = wk === 1 ? 0 : 7;
    const sundayIdx = weekStart;
    const saturdayIdx = weekStart + 6;

    // Sunday: shown for this period? Render card + hide footer, else add btn.
    if (isWeekendShown(viewed, sundayIdx)) {
      list.appendChild(buildDayCard(viewed.days[sundayIdx], totals, todayStr, entriesByDate[viewed.days[sundayIdx]]));
      list.appendChild(buildHideDayBtn('× Hide Sunday', viewed, sundayIdx));
    } else {
      list.appendChild(buildAddDayBtn('+ Add Sunday', viewed, sundayIdx));
    }

    // Mon-Fri always
    for (let i = weekStart + 1; i < weekStart + 6; i++) {
      const d = viewed.days[i];
      list.appendChild(buildDayCard(d, totals, todayStr, entriesByDate[d]));
    }

    // Saturday: same pattern
    if (isWeekendShown(viewed, saturdayIdx)) {
      list.appendChild(buildDayCard(viewed.days[saturdayIdx], totals, todayStr, entriesByDate[viewed.days[saturdayIdx]]));
      list.appendChild(buildHideDayBtn('× Hide Saturday', viewed, saturdayIdx));
    } else {
      list.appendChild(buildAddDayBtn('+ Add Saturday', viewed, saturdayIdx));
    }
    requestAnimationFrame(() => reflowList(list));
  }
}

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

function buildDayCard(d, totals, todayStr, dayEntries) {
  const dayWorked = totals.byDate[d] || 0;
  const dayLeave = totals.leaveMap[d] || 0;
  const { overtime } = T.overtimeSplit(dayWorked, state.otMode);
  const total = dayWorked + dayLeave;
  const date = T.parseLocalDate(d);
  const dow = date.getDay();
  const isToday = d === todayStr;
  const isWeekend = dow === 0 || dow === 6;

  const isValidation = state.validationDay != null
    && Number(state.validationDay) === viewedPeriodDayIndex(d);

  const card = el('div', {
    class: 'day-card'
      + (isToday ? ' today' : '')
      + (isWeekend ? ' weekend' : '')
      + (isValidation ? ' validation' : ''),
  });

  // Leave stepper: visible labelled "Lv" with both − and + so the user can
  // remove leave hours too (previously only +). Disable − when at 0.
  const leaveDec = el('button', {
    class: 'leave-btn',
    title: 'Remove 1 leave hour',
    onclick: async (ev) => {
      ev.stopPropagation();
      if ((dayLeave || 0) <= 0) return;
      await DB.setLeaveHours(d, (dayLeave || 0) - 1);
      vibrate(8);
      renderPeriodView();
    },
  }, '−');
  if ((dayLeave || 0) <= 0) leaveDec.disabled = true;

  const leaveInc = el('button', {
    class: 'leave-btn',
    title: 'Add 1 leave hour',
    onclick: async (ev) => {
      ev.stopPropagation();
      await DB.addLeave(d, 1);
      vibrate(8);
      renderPeriodView();
    },
  }, '+');

  const header = el('div', { class: 'day-header' },
    el('div', { class: 'day-main', onclick: () => openDayEditor(d) },
      el('div', { class: 'day-name' },
        date.toLocaleDateString(undefined, { weekday: 'short' }) + (isToday ? ' · Today' : '')),
      el('div', { class: 'day-date' }, date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })),
    ),
    el('div', { class: 'day-totals', onclick: () => openDayEditor(d) },
      el('span', { class: 'day-hours' }, T.formatHours(total)),
      el('span', { class: 'unit' }, ' hr'),
      state.otMode && overtime > 0
        ? el('span', { class: 'day-ot' }, ` +${T.formatHours(overtime)}`)
        : null,
    ),
    el('div', { class: 'leave-mini', title: 'Leave hours' },
      leaveDec,
      el('span', { class: 'leave-mini-label' }, `Leave ${dayLeave || 0}`),
      leaveInc,
    ),
  );
  card.appendChild(header);
  card.appendChild(buildDayEditorRow(d, dayEntries, dayLeave));
  return card;
}

// Position 0..13 of a YYYY-MM-DD within its pay period (anchored to Sunday).
function viewedPeriodDayIndex(dateStr) {
  if (!state.anchor) return -1;
  const period = T.payPeriodFor(T.parseLocalDate(dateStr), state.anchor);
  return period.dayIndex;
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
const DEFAULT_SCALE_START = 6 * 60;        // 6 AM (default visible left)
const DEFAULT_SCALE_END = 18 * 60;         // 6 PM (default visible right)
const SCALE_PAD_MIN = 30;                  // padding when auto-extending
const SNAP_MIN = 15;
// Non-linear scale: COMPRESS the core workday (9 AM – 2:30 PM) since those
// hours are routine and rarely tweaked, and EXPAND the edges where the user
// actually adjusts start/end times. CORE_WEIGHT is the fraction of strip
// width allocated to the core zone (less than 0.5 makes the core compressed).
const CORE_START_MIN = 9 * 60;             // 9 AM
const CORE_END_MIN = 14 * 60 + 30;         // 2:30 PM
const CORE_WEIGHT = 0.30;                  // core gets 30% of width (compressed)

function minToPct(m, scale) {
  const { startMin, endMin } = scale;
  if (endMin <= startMin) return 0;
  if (m <= startMin) return 0;
  if (m >= endMin) return 100;
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
  let startMin = DEFAULT_SCALE_START;
  let endMin = DEFAULT_SCALE_END;
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
  let startMin = DEFAULT_SCALE_START;
  let endMin = DEFAULT_SCALE_END;
  const wraps = list.querySelectorAll('.day-timeline');
  for (const w of wraps) {
    for (const child of w.children) {
      if (!child.classList.contains('tl-bar')) continue;
      const lm = parseFloat(child.dataset.leftMin);
      const wm = parseFloat(child.dataset.widthMin);
      if (!isFinite(lm) || !isFinite(wm)) continue;
      startMin = Math.min(startMin, Math.max(ABSOLUTE_START_MIN, lm - SCALE_PAD_MIN));
      endMin = Math.max(endMin, Math.min(ABSOLUTE_END_MIN, lm + wm + SCALE_PAD_MIN));
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
}

function buildDayTimeline(dateStr, entries) {
  const wrap = el('div', { class: 'day-timeline' });
  wrap._scale = autoFitScale(entries);

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

  reflowTimeline(wrap);
  return wrap;
}

function drawEntryOnTimeline(wrap, dateStr, entry, tooltip) {
  const startMin = clampToAbsolute(minutesOfDate(entry.startTime));
  const rawEnd = entry.endTime ? endMinutesForEntry(entry) : minutesOfDate(new Date());
  const endMin = clampToAbsolute(rawEnd);
  const inProgress = !entry.endTime;

  const bar = el('div', {
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

function attachHandleDrag(wrap, hit, knob, which, refs) {
  let dragging = false;
  let oppMin = 0;
  let curMin = 0;
  // Offset between pointer and the handle's centerline at drag-start, in
  // minutes. Lets the user grab the handle without it jumping to under the
  // finger; pointer drift translates 1:1 into time movement.
  let grabOffsetMin = 0;

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
      // Cap end one snap-tick short of midnight so we never write a next-day
      // endTime via the slider (which previously broke the bar display).
      m = Math.max(oppMin + SNAP_MIN, Math.min(ABSOLUTE_END_MIN - SNAP_MIN, m));
    }
    curMin = m;

    // Scale is now derived from ALL bars by reflowList(); the per-wrap
    // extension that used to live here has been removed in favor of that
    // global pass (which also contracts when bars retreat).

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

async function renderDayView() {
  const d = state.editingDate;
  if (!d) return;
  $('dayTitle').textContent = T.formatDateShort(d);

  // Show the validation-deadline banner when this day's day-of-period
  // index matches the user's chosen validation day.
  const dayIdx = viewedPeriodDayIndex(d);
  $('validationBanner').hidden = !(state.validationDay != null
    && state.validationDay === dayIdx);

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
}

// One row for the 14-day schedule. dayIndex is 0..13.
function buildScheduleRow(dayIndex) {
  // Resolve a slot to render. Fall back to 9–5 for display purposes only —
  // the slot stays null in state until the user toggles it on or drags it.
  const saved = state.defaultSchedule[dayIndex];
  const slot = saved
    ? { enabled: saved.enabled !== false, startMin: saved.startMin, endMin: saved.endMin }
    : { enabled: false, startMin: 9 * 60, endMin: 17 * 60 };

  const weekday = dayIndex % 7;
  const row = el('div', { class: 'schedule-row' + (slot.enabled ? '' : ' off') });

  const toggleWrap = el('label', { class: 'schedule-toggle' });
  const toggle = el('input', {
    type: 'checkbox',
    onchange: (ev) => {
      const on = ev.target.checked;
      const cur = state.defaultSchedule[dayIndex] || { startMin: slot.startMin, endMin: slot.endMin };
      state.defaultSchedule[dayIndex] = {
        enabled: on,
        startMin: cur.startMin,
        endMin: cur.endMin,
      };
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
    state.defaultSchedule[dayIndex] = {
      enabled: slot.enabled,
      startMin: newStart,
      endMin: newEnd,
    };
    timeText.textContent = `${T.formatMinutes(newStart, state.use24h)} – ${T.formatMinutes(newEnd, state.use24h)}`;
  });

  const timeText = el('span', { class: 'schedule-time-text' },
    `${T.formatMinutes(slot.startMin, state.use24h)} – ${T.formatMinutes(slot.endMin, state.use24h)}`);

  // Copy this row's hours to all 10 weekday slots (Mon-Fri × both weeks),
  // turning them on. Weekend rows are untouched. Most users set up Monday
  // and want it replicated across the rest of the work week.
  const copyBtn = el('button', {
    class: 'schedule-copy',
    title: 'Copy these hours to all weekdays',
    onclick: (ev) => {
      ev.stopPropagation();
      if (!window.confirm(
        `Copy ${DAY_NAMES[weekday]}'s hours to every weekday in both weeks?`
      )) return;
      const src = state.defaultSchedule[dayIndex] || slot;
      const weekdayIdx = [1, 2, 3, 4, 5, 8, 9, 10, 11, 12];
      for (const i of weekdayIdx) {
        state.defaultSchedule[i] = {
          enabled: true,
          startMin: src.startMin,
          endMin: src.endMin,
        };
      }
      renderScheduleView();
    },
  }, '⧉');

  row.appendChild(toggleWrap);
  row.appendChild(label);
  row.appendChild(strip);
  row.appendChild(timeText);
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
      curMin = m;
      knob.dataset.leftMin = String(m);
      hit.dataset.leftMin = String(m);
      const sm = which === 'start' ? m : oppMin;
      const em = which === 'end' ? m : oppMin;
      bar.dataset.leftMin = String(sm);
      bar.dataset.widthMin = String(em - sm);
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
      knob.classList.add('dragging');
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
    state.otMode = false;
    state.hourlyRate = 0;
    state.use24h = false;
    state.defaultSchedule = [null, null, null, null, null, null, null];
    state.openEntry = null;
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
