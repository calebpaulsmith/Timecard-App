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
  work:     { label: 'Work',     cssVar: '--cal-work' },
  personal: { label: 'Personal', cssVar: '--cal-personal' },
  ritza:    { label: 'Ritza',    cssVar: '--cal-ritza' },
  amelia:   { label: 'Amelia',   cssVar: '--cal-amelia' },
};

window.Calendar = {
  COLORS,
  // Recurrence engine, .ics, and sync helpers land here in later phases.
};

})();
