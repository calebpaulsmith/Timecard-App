// calendar.js — Home Calendar layer (Phase 0 skeleton).
//
// Wrapped in an IIFE so its top-level declarations don't collide with the shared
// "script scope" across classic <script> tags (db.js and app.js both declare
// `const T` — see CLAUDE.md "Script-scope const collision"). Loaded AFTER db.js
// so window.DB / window.TimeUtil are available.
//
// This is intentionally empty-but-wired for now. Later phases hang real logic
// off window.Calendar:
//   - Phase 2: the dependency-free RRULE recurrence engine + occurrence
//     expansion over a visible date window (home-calendar-plan.md §5).
//   - Phase 3: RFC-5545 .ics export/import for events (§3, Tier 1).
//   - Phase 4: Google sync helpers (gated behind calendar mode + explicit
//     connect; never loaded or fired in timecard mode).
//
// Nothing here renders UI or touches the DOM in Phase 0; the only visible change
// this phase is the Settings calendar-mode toggle, wired in app.js.

(function () {
'use strict';

const T = window.TimeUtil;   // pure time helpers (no DOM/DB)
const DB = window.DB;        // data-access layer

// Palette tokens for event colors, mirroring the CSS custom properties added in
// styles.css (§6). Kept here as the canonical name→meaning list so later phases
// can map an event's stored `color` token to its swatch without re-deriving it.
// Colorblind-conscious, small, high-contrast set: the "Me line" work/personal
// pair plus one color per tracked person.
const COLORS = {
  work:     { label: 'Work',     cssVar: '--cal-work',     lane: 'me' },
  personal: { label: 'Personal', cssVar: '--cal-personal', lane: 'me' },
  ritza:    { label: 'Ritza',    cssVar: '--cal-ritza',    lane: 'person' },
  amelia:   { label: 'Amelia',   cssVar: '--cal-amelia',   lane: 'person' },
};
// Order shown in the color/category picker (Me line first, then people).
const COLOR_ORDER = ['work', 'personal', 'ritza', 'amelia'];

// Which tier a color token lives on: 'me' (work/personal, the main bar) or
// 'person' (Ritza/Amelia, the thin lanes above) — see plan §6.
function laneForColor(token) {
  const c = COLORS[token];
  return c ? c.lane : 'me';
}

// CSS var() expression for a token's color, falling back to the Me-line work
// blue for anything unrecognized.
function colorVar(token) {
  const c = COLORS[token];
  return `var(${c ? c.cssVar : '--cal-work'})`;
}

// Greedy interval stacking: assign each timed event the lowest lane index that
// doesn't overlap an already-placed event in that lane. Input events need
// numeric startMin/endMin. Returns a Map(event -> laneIndex) and the lane count.
// Pure (no DOM/DB) so it's unit-testable and reusable by later phases.
function stackEvents(events) {
  const sorted = events.slice().sort((a, b) =>
    (a.startMin - b.startMin) || (a.endMin - b.endMin));
  const laneEnds = [];          // laneEnds[i] = endMin of last event in lane i
  const laneOf = new Map();
  for (const ev of sorted) {
    let placed = -1;
    for (let i = 0; i < laneEnds.length; i++) {
      if (ev.startMin >= laneEnds[i]) { placed = i; break; }
    }
    if (placed === -1) { placed = laneEnds.length; laneEnds.push(0); }
    laneEnds[placed] = ev.endMin;
    laneOf.set(ev, placed);
  }
  return { laneOf, laneCount: laneEnds.length };
}

// --- Recurrence engine (Phase 2) -------------------------------------------
// A dependency-free subset of iCalendar RRULE: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY
// with INTERVAL, BYDAY (weekly), COUNT and UNTIL. Stored as a standard RRULE
// string on the series' anchor event so recurrence round-trips through .ics and
// Google later (§5). Local date helpers keep this pure & node-testable (no T).

const RRULE_DOW = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

function parseYmd(s) {
  const [y, m, d] = String(s).split('-').map(Number);
  return new Date(y, m - 1, d);
}
function fmtYmd(dt) {
  const y = dt.getFullYear();
  const m = String(dt.getMonth() + 1).padStart(2, '0');
  const d = String(dt.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}
function addDays(dt, n) {
  const r = new Date(dt.getFullYear(), dt.getMonth(), dt.getDate());
  r.setDate(r.getDate() + n);
  return r;
}

function parseRRule(str) {
  if (!str) return null;
  const out = { freq: null, interval: 1, byday: [], count: null, until: null };
  for (const part of String(str).split(';')) {
    const [k, v] = part.split('=');
    if (!v) continue;
    const key = k.toUpperCase();
    if (key === 'FREQ') out.freq = v.toUpperCase();
    else if (key === 'INTERVAL') out.interval = Math.max(1, parseInt(v, 10) || 1);
    else if (key === 'BYDAY') out.byday = v.toUpperCase().split(',').map(s => s.trim()).filter(Boolean);
    else if (key === 'COUNT') out.count = Math.max(1, parseInt(v, 10) || 1);
    else if (key === 'UNTIL') out.until = v.slice(0, 8); // YYYYMMDD (drop any time part)
  }
  return out.freq ? out : null;
}

function formatRRule(o) {
  if (!o || !o.freq) return null;
  const p = ['FREQ=' + o.freq];
  if (o.interval && o.interval > 1) p.push('INTERVAL=' + o.interval);
  if (o.freq === 'WEEKLY' && o.byday && o.byday.length) p.push('BYDAY=' + o.byday.join(','));
  if (o.count) p.push('COUNT=' + o.count);
  else if (o.until) p.push('UNTIL=' + o.until);
  return p.join(';');
}

// Expand a recurrence into the YYYY-MM-DD occurrence dates that fall within
// [winStart, winEnd] (inclusive). `startDate` is the series anchor (DTSTART).
// COUNT/UNTIL are honored from the anchor (occurrences before the window still
// consume the count). `exdates` removes cancelled occurrences. Returns [] for a
// null rule unless the lone anchor sits in the window.
function expandRRule(startDate, ruleStr, winStart, winEnd, exdates) {
  const ex = new Set(exdates || []);
  const res = [];
  const rule = parseRRule(ruleStr);
  if (!rule) {
    if (startDate >= winStart && startDate <= winEnd && !ex.has(startDate)) res.push(startDate);
    return res;
  }
  const start = parseYmd(startDate);
  const wStart = parseYmd(winStart);
  const wEnd = parseYmd(winEnd);
  const until = rule.until
    ? parseYmd(`${rule.until.slice(0, 4)}-${rule.until.slice(4, 6)}-${rule.until.slice(6, 8)}`)
    : null;
  const interval = rule.interval || 1;
  const maxCount = rule.count || Infinity;
  let count = 0;
  const CAP = 5000;
  let iter = 0;

  const emit = (dt) => {
    // Returns false to signal termination (past UNTIL / COUNT).
    if (until && dt > until) return false;
    if (count >= maxCount) return false;
    count++;
    if (dt > wEnd) return false;
    if (dt >= wStart) {
      const s = fmtYmd(dt);
      if (!ex.has(s)) res.push(s);
    }
    return true;
  };

  if (rule.freq === 'WEEKLY' && rule.byday && rule.byday.length) {
    const bydays = rule.byday.map(c => RRULE_DOW.indexOf(c)).filter(i => i >= 0).sort((a, b) => a - b);
    if (!bydays.length) bydays.push(start.getDay());
    let weekStart = addDays(start, -start.getDay()); // Sunday of the anchor's week
    while (iter++ < CAP) {
      let alive = true;
      for (const dow of bydays) {
        const occ = addDays(weekStart, dow);
        if (occ < start) continue;     // skip days before the series start
        if (!emit(occ)) { alive = false; break; }
      }
      if (!alive) break;
      weekStart = addDays(weekStart, 7 * interval);
      // No later week can land inside the window, so stop scanning.
      if (weekStart > wEnd) break;
      if (count >= maxCount) break;
    }
    return res;
  }

  let cur = new Date(start);
  while (iter++ < CAP) {
    if (!emit(cur)) break;
    if (rule.freq === 'DAILY') cur = addDays(cur, interval);
    else if (rule.freq === 'WEEKLY') cur = addDays(cur, 7 * interval);
    else if (rule.freq === 'MONTHLY') { const r = new Date(cur); r.setMonth(r.getMonth() + interval); cur = r; }
    else if (rule.freq === 'YEARLY') { const r = new Date(cur); r.setFullYear(r.getFullYear() + interval); cur = r; }
    else break;
  }
  return res;
}

// Expand a stored series row into concrete occurrence instances over a window.
// Each instance is a shallow clone carrying the occurrence `date` plus markers
// (`_occurrenceOf`, `_seriesDate`) so the editor can offer this/all choices.
function expandSeries(series, winStart, winEnd) {
  const dates = expandRRule(series.date, series.rrule, winStart, winEnd, series.exdates);
  return dates.map(date => ({
    ...series,
    date,
    _occurrenceOf: series.id,
    _seriesDate: series.date,
  }));
}

window.Calendar = {
  COLORS,
  COLOR_ORDER,
  laneForColor,
  colorVar,
  stackEvents,
  parseRRule,
  formatRRule,
  expandRRule,
  expandSeries,
  // .ics + Google sync helpers land in later phases.
};

})();
