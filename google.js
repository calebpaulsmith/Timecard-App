// google.js — Google Calendar connector for the Home Calendar layer.
//
// Pure-ish module (window.GoogleCal): OAuth via Google Identity Services (GIS)
// running entirely in the browser (no server, no client secret — this is a
// static GitHub Pages PWA), the Calendar REST v3 calls, and pure field mappers
// between our local event shape and Google's resource shape. The DB
// reconciliation / sync orchestration lives in app.js (mirrors how connectors.js
// is pure and app.js drives it).
//
// HARD RULE (see CLAUDE.md): every caller is gated behind calendar mode — this
// file is never touched in plain timecard mode, which stays network-free.
//
// Auth model: GIS token client (implicit/token flow). No refresh token is
// available client-side, so we cache the short-lived access token + expiry and
// silently re-request (`prompt: ''`) when it lapses; the user only sees a
// consent screen on first connect. The token never leaves the device and is
// excluded from CSV export.

(function () {
'use strict';

// Full calendar scope: lets us list calendars, read shared calendars (Ritza's),
// and read/write the user's own events. (calendar.readonly is a strict subset.)
const SCOPES = 'https://www.googleapis.com/auth/calendar';
const GIS_SRC = 'https://accounts.google.com/gsi/client';
const API_BASE = 'https://www.googleapis.com/calendar/v3';

// The viewer's IANA timezone, sent with timed events so Google anchors our
// floating-local minutes to the right wall-clock time.
function localTimeZone() {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'; }
  catch { return 'UTC'; }
}

// --- GIS bootstrap ----------------------------------------------------------

let _gisPromise = null;
function loadGis() {
  if (window.google && window.google.accounts && window.google.accounts.oauth2) {
    return Promise.resolve();
  }
  if (_gisPromise) return _gisPromise;
  _gisPromise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = GIS_SRC;
    s.async = true;
    s.defer = true;
    s.onload = () => resolve();
    s.onerror = () => { _gisPromise = null; reject(new Error('Could not load Google Identity Services')); };
    document.head.appendChild(s);
  });
  return _gisPromise;
}

// Reuse one token client per client id (GIS recommends not re-initializing).
let _tokenClient = null;
let _tokenClientId = null;

// Request an access token. `interactive` shows the consent/account UI; otherwise
// we attempt a silent refresh (works once the user has already granted access).
// Resolves to { access_token, expiresAt } or rejects.
function requestToken(clientId, opts) {
  opts = opts || {};
  if (!clientId) return Promise.reject(new Error('Missing Google OAuth client ID'));
  return loadGis().then(() => new Promise((resolve, reject) => {
    if (!_tokenClient || _tokenClientId !== clientId) {
      _tokenClient = window.google.accounts.oauth2.initTokenClient({
        client_id: clientId,
        scope: SCOPES,
        callback: () => {},        // replaced per-request below
      });
      _tokenClientId = clientId;
    }
    _tokenClient.callback = (resp) => {
      if (resp && resp.access_token) {
        const ttl = (Number(resp.expires_in) || 3600) * 1000;
        // Expire a minute early so an in-flight call never races the deadline.
        resolve({ access_token: resp.access_token, expiresAt: Date.now() + ttl - 60000 });
      } else {
        reject(new Error('Google did not return an access token'));
      }
    };
    _tokenClient.error_callback = (err) => {
      reject(new Error('Google sign-in failed: ' + (err && err.type ? err.type : 'unknown')));
    };
    // 'consent' on first connect guarantees the grant; '' attempts silent reuse.
    _tokenClient.requestAccessToken({ prompt: opts.interactive ? 'consent' : '' });
  }));
}

function revokeToken(accessToken) {
  return loadGis().then(() => new Promise((resolve) => {
    if (!accessToken || !window.google.accounts.oauth2.revoke) { resolve(); return; }
    window.google.accounts.oauth2.revoke(accessToken, () => resolve());
  }));
}

// --- REST helpers -----------------------------------------------------------

async function api(token, path, { method = 'GET', params = null, body = null } = {}) {
  let url = API_BASE + path;
  if (params) {
    const qs = Object.entries(params)
      .filter(([, v]) => v != null && v !== '')
      .map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v))
      .join('&');
    if (qs) url += (url.includes('?') ? '&' : '?') + qs;
  }
  const opts = { method, headers: { Authorization: 'Bearer ' + token } };
  if (body != null) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const resp = await fetch(url, opts);
  if (resp.status === 204) return null;          // DELETE
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    const msg = (data && data.error && data.error.message) || resp.statusText || ('HTTP ' + resp.status);
    const e = new Error(msg);
    e.status = resp.status;
    throw e;
  }
  return data;
}

// All calendars the user can see (owned + subscribed/shared, e.g. Ritza's).
async function listCalendars(token) {
  const out = [];
  let pageToken = null;
  do {
    const data = await api(token, '/users/me/calendarList', {
      params: { maxResults: 250, showHidden: true, pageToken },
    });
    for (const c of data.items || []) out.push(c);
    pageToken = data.nextPageToken || null;
  } while (pageToken);
  return out;
}

// Events in [timeMin, timeMax). singleEvents:false keeps recurring masters as
// one row carrying the RRULE (matches our series model). showDeleted surfaces
// cancelled events so the sync can tombstone them locally.
async function listEvents(token, calendarId, { timeMin, timeMax, singleEvents = false, showDeleted = true } = {}) {
  const out = [];
  let pageToken = null;
  do {
    const data = await api(token, '/calendars/' + encodeURIComponent(calendarId) + '/events', {
      params: {
        timeMin, timeMax,
        singleEvents: singleEvents ? 'true' : 'false',
        showDeleted: showDeleted ? 'true' : 'false',
        maxResults: 2500,
        pageToken,
      },
    });
    for (const e of data.items || []) out.push(e);
    pageToken = data.nextPageToken || null;
  } while (pageToken);
  return out;
}

function insertEvent(token, calendarId, resource) {
  return api(token, '/calendars/' + encodeURIComponent(calendarId) + '/events', { method: 'POST', body: resource });
}
function patchEvent(token, calendarId, eventId, resource) {
  return api(token, '/calendars/' + encodeURIComponent(calendarId) + '/events/' + encodeURIComponent(eventId), { method: 'PATCH', body: resource });
}
function deleteEvent(token, calendarId, eventId) {
  return api(token, '/calendars/' + encodeURIComponent(calendarId) + '/events/' + encodeURIComponent(eventId), { method: 'DELETE' });
}

// --- Pure mappers -----------------------------------------------------------

function pad2(n) { return String(n).padStart(2, '0'); }

// Local floating-local minutes → "YYYY-MM-DDTHH:MM:SS" (no zone suffix; the
// timeZone field carries the zone).
function localDateTime(dateStr, min) {
  const h = Math.floor(min / 60), m = min % 60;
  return `${dateStr}T${pad2(h)}:${pad2(m)}:00`;
}

// Local event (our shape) → Google event resource. Recurrence rides as the
// stored RRULE string. Timed events use the viewer's timeZone; all-day events
// use date-only with an exclusive end (Google convention).
function toGoogleResource(ev) {
  const tz = localTimeZone();
  const res = {
    summary: ev.title || '(untitled)',
    description: ev.notes || '',
    location: ev.location || '',
  };
  if (ev.allDay || !isFinite(ev.startMin)) {
    res.start = { date: ev.date };
    // All-day end is exclusive → next day.
    const d = new Date(ev.date + 'T00:00:00');
    d.setDate(d.getDate() + 1);
    res.end = { date: `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}` };
  } else {
    const start = Math.max(0, ev.startMin | 0);
    let end = Math.max(start + 15, ev.endMin | 0);
    let endDate = ev.date;
    // An end past midnight rolls to the next day.
    if (end >= 24 * 60) { end -= 24 * 60; const d = new Date(ev.date + 'T00:00:00'); d.setDate(d.getDate() + 1); endDate = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; }
    res.start = { dateTime: localDateTime(ev.date, start), timeZone: tz };
    res.end = { dateTime: localDateTime(endDate, end), timeZone: tz };
  }
  if (ev.rrule) res.recurrence = ['RRULE:' + ev.rrule];
  return res;
}

// Parse a Google date/dateTime block → { date, min|null, allDay }.
function fromGoogleWhen(block) {
  if (!block) return { date: null, min: null, allDay: true };
  if (block.date) return { date: block.date, min: null, allDay: true };
  // dateTime like 2026-06-21T09:30:00-05:00 — read the wall-clock fields.
  const m = String(block.dateTime).match(/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/);
  if (!m) return { date: null, min: null, allDay: true };
  return { date: m[1], min: Number(m[2]) * 60 + Number(m[3]), allDay: false };
}

// Google event → partial local event shape (the caller merges id/color/source).
// Returns null for malformed events.
function fromGoogleEvent(g) {
  if (!g || !g.id) return null;
  const start = fromGoogleWhen(g.start);
  const end = fromGoogleWhen(g.end);
  if (!start.date) return null;
  let rrule = null;
  if (Array.isArray(g.recurrence)) {
    const line = g.recurrence.find(r => /^RRULE:/i.test(r));
    if (line) rrule = line.replace(/^RRULE:/i, '');
  }
  // All-day Google end is exclusive; our model has no separate end date, so we
  // just keep the start date for the day bucket.
  let endMin = end.min;
  if (!start.allDay) {
    if (end.date && end.date !== start.date && isFinite(end.min)) endMin = end.min + 24 * 60; // crosses midnight
    if (!isFinite(endMin)) endMin = (start.min | 0) + 60;
  }
  return {
    googleId: g.id,
    title: g.summary || '(untitled)',
    date: start.date,
    allDay: start.allDay,
    startMin: start.allDay ? null : start.min,
    endMin: start.allDay ? null : endMin,
    notes: g.description || '',
    location: g.location || '',
    rrule,
    cancelled: g.status === 'cancelled',
    updated: g.updated || null,
  };
}

window.GoogleCal = {
  SCOPES,
  localTimeZone,
  requestToken, revokeToken,
  listCalendars, listEvents, insertEvent, patchEvent, deleteEvent,
  toGoogleResource, fromGoogleEvent,
};

})();
