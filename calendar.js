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

window.Calendar = {
  COLORS,
  COLOR_ORDER,
  laneForColor,
  colorVar,
  stackEvents,
  // Recurrence engine, .ics, and sync helpers land here in later phases.
};

})();
