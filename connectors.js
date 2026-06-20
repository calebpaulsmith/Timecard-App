// connectors.js — Discover / Invites connector framework (calendar app only).
//
// PURE: no DOM, no DB, no network. Given a SOURCE config it (1) builds a fetch
// request — URL / method / headers / body, plus whether it must go through the
// CORS proxy — and (2) normalizes the raw response into INVITE events (the
// pending, not-yet-accepted items the Invites lane surfaces). Everything is
// config-driven so ANY user can add a source by describing it; the user's own
// Chicago / Ravenswood-Manor setup ships as DEFAULT_SOURCES (seed, editable).
//
// Wrapped in an IIFE (see CLAUDE.md "Script-scope const collision"). Loaded after
// calendar.js so window.Calendar (the .ics parser) is available for ICS sources.
// This is the calendar app's; it is never referenced by timecard-mode code.

(function () {
'use strict';

const Cal = window.Calendar;   // for parseEventsIcs (ICS sources); may be undefined in tests

// --- Geo ----------------------------------------------------------------------
const FT_PER_DEG_LAT = 364000;            // ~feet per degree of latitude
const EARTH_FT = 20902231;                // mean earth radius in feet
const toRad = (d) => (d * Math.PI) / 180;

// Great-circle distance in feet between two lat/lng points.
function haversineFeet(lat1, lng1, lat2, lng2) {
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_FT * Math.asin(Math.min(1, Math.sqrt(a)));
}

// A lat/lng bounding box around a center for a given radius in feet. Used to
// pre-narrow a Socrata query before the exact radius filter runs client-side.
function boxAround(lat, lng, radiusFt) {
  const dLat = radiusFt / FT_PER_DEG_LAT;
  const dLng = radiusFt / (FT_PER_DEG_LAT * Math.max(0.01, Math.cos(toRad(lat))));
  return { latMin: lat - dLat, latMax: lat + dLat, lngMin: lng - dLng, lngMax: lng + dLng };
}

// --- Shared helpers -----------------------------------------------------------
// Tolerant "→ YYYY-MM-DD": handles ISO ("2026-07-04T00:00:00.000"), bare ISO
// dates, and US long form ("July 4, 2026"). Returns null if unparseable.
const MONTHS = ['january','february','march','april','may','june','july',
  'august','september','october','november','december'];
function toYmd(v) {
  if (!v) return null;
  const s = String(v).trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/^([A-Za-z]+)\s+(\d{1,2}),?\s+(\d{4})/);
  if (m) {
    const mi = MONTHS.indexOf(m[1].toLowerCase());
    if (mi >= 0) return `${m[3]}-${String(mi + 1).padStart(2, '0')}-${String(+m[2]).padStart(2, '0')}`;
  }
  return null;
}
const num = (v) => { const n = Number(v); return isFinite(n) ? n : null; };
const pick = (obj, path) => (path && obj ? obj[path] : undefined);

// The normalized INVITE shape every connector emits. `pending:true` + a non-local
// `source` is what makes the render layer treat it as an invite, not a committed
// event. `externalId` is the stable key for de-duping across re-fetches.
function shape(src, f) {
  return {
    source: src.id,
    sourceLabel: src.label,
    externalId: `${src.id}:${f.externalId}`,
    title: f.title || '(untitled)',
    category: f.category || src.category || 'event',
    color: src.color || 'personal',
    date: f.date || null,
    endDate: f.endDate || null,
    allDay: f.allDay !== false ? !isFinite(f.startMin) : false,
    startMin: isFinite(f.startMin) ? f.startMin : null,
    endMin: isFinite(f.endMin) ? f.endMin : null,
    lat: f.lat != null ? f.lat : null,
    lng: f.lng != null ? f.lng : null,
    location: f.location || '',
    url: f.url || null,
    pending: true,
  };
}

// Apply the common post-fetch filters every source supports: a date floor
// (drop past), an exact geo radius (when the source carries lat/lng and the
// user set radiusFt + home), and de-dupe by externalId.
function postFilter(events, src, ctx) {
  const today = ctx && ctx.today;
  const home = ctx && ctx.home;
  const seen = new Set();
  const out = [];
  for (const e of events) {
    if (!e.date) continue;
    if (today && e.date < today) continue;
    if (src.geoRadiusFt && home && e.lat != null && e.lng != null) {
      if (haversineFeet(home.lat, home.lng, e.lat, e.lng) > src.geoRadiusFt) continue;
    }
    if (seen.has(e.externalId)) continue;
    seen.add(e.externalId);
    out.push(e);
  }
  out.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  return out;
}

// --- Source TYPES -------------------------------------------------------------
// Each type knows how to build a request from a config and normalize the raw
// response into INVITE rows. `proxied` marks requests that must go through the
// CORS proxy (the static PWA can't fetch non-CORS hosts directly).
const TYPES = {
  // Chicago Data Portal etc. SoQL over a dataset. Browser-fetchable (CORS-OK),
  // so proxied defaults false. `whereTemplate` may use {today}; geoRadiusFt +
  // home auto-appends a bounding box for efficiency before the exact filter.
  socrata: {
    buildRequest(src, ctx) {
      const p = new URLSearchParams();
      if (src.select) p.set('$select', src.select);
      let where = (src.whereTemplate || src.where || '').replace(/{today}/g, (ctx && ctx.today) || '1970-01-01');
      const m = src.map || {};
      if (src.geoRadiusFt && ctx && ctx.home && m.lat && m.lng) {
        const b = boxAround(ctx.home.lat, ctx.home.lng, src.geoRadiusFt);
        const box = `${m.lat} > ${b.latMin} AND ${m.lat} < ${b.latMax} AND ` +
          `${m.lng} > ${b.lngMin} AND ${m.lng} < ${b.lngMax}`;
        where = where ? `(${where}) AND ${box}` : box;
      }
      if (where) p.set('$where', where);
      p.set('$order', src.order || (m.startDate || 'date'));
      p.set('$limit', String(src.limit || 200));
      const url = `https://${src.domain}/resource/${src.dataset}.json?${p.toString()}`;
      return { url, method: 'GET', proxied: !!src.proxied };
    },
    normalize(rows, src) {
      const m = src.map || {};
      return (Array.isArray(rows) ? rows : []).map((r) => shape(src, {
        externalId: pick(r, m.id) || pick(r, m.startDate) + '|' + (pick(r, m.title) || ''),
        title: pick(r, m.title),
        category: m.category ? pick(r, m.category) : undefined,
        date: toYmd(pick(r, m.startDate)),
        endDate: m.endDate ? toYmd(pick(r, m.endDate)) : null,
        lat: m.lat ? num(pick(r, m.lat)) : null,
        lng: m.lng ? num(pick(r, m.lng)) : null,
        location: m.location ? pick(r, m.location) : '',
        url: m.url ? pick(r, m.url) : null,
      }));
    },
  },

  // ActiveNet (e.g. Chicago Park District programs). POST the list endpoint.
  // Age/center server-side params are unreliable, so we post-filter by age using
  // the record's age_min_year/age_max_year and by center label. Needs the proxy
  // (internal XHR endpoint, no CORS). NOTE: exact server filter params + paging
  // should be confirmed against a live browser XHR capture; post-filter is the
  // guaranteed path. See CLAUDE.md.
  activenet: {
    buildRequest(src) {
      const pattern = Object.assign({ activity_select_param: 2 }, src.search || {});
      return {
        url: `https://${src.host}/${src.org}/rest/activities/list?locale=en-US`,
        method: 'POST',
        proxied: true,
        headers: {
          'Content-Type': 'application/json;charset=utf-8',
          'X-Requested-With': 'XMLHttpRequest',
          'page_info': JSON.stringify({ order_by: '', page_number: 1, total_records_per_page: src.pageSize || 100 }),
        },
        body: JSON.stringify({ activity_search_pattern: pattern, activity_transfer_pattern: {} }),
      };
    },
    normalize(payload, src) {
      const body = payload && (payload.body || payload);
      const items = (body && body.activity_items) || [];
      const ageMin = src.ageMin, ageMax = src.ageMax;
      const centers = (src.centerNames || []).map((s) => s.toUpperCase());
      const out = [];
      for (const it of items) {
        const lo = it.age_min_year, hi = it.age_max_year;
        if (ageMin != null && ageMax != null && lo != null && hi != null) {
          if (!(lo <= ageMax && hi >= ageMin)) continue;   // age window overlap
        }
        const loc = (it.location && it.location.label) || '';
        if (centers.length && !centers.some((c) => loc.toUpperCase().includes(c))) continue;
        out.push(shape(src, {
          externalId: String(it.id || it.number || it.name),
          title: it.name,
          category: it.category || 'Kids program',
          date: toYmd(it.date_range_start) || toYmd(it.date_range),
          endDate: toYmd(it.date_range_end),
          location: loc,
          url: it.detail_url,
          allDay: true,
        }));
      }
      return out;
    },
  },

  // Generic ICS feed subscription. Reuses the calendar's RFC-5545 parser. Most
  // third-party .ics hosts lack CORS → proxied by default.
  ics: {
    buildRequest(src) {
      return { url: src.url, method: 'GET', proxied: src.proxied !== false };
    },
    normalize(text, src) {
      const parse = Cal && Cal.parseEventsIcs;
      const rows = parse ? parse(String(text)) : [];
      return rows.map((r) => shape(src, {
        externalId: r.uid || `${r.date}|${r.title}`,
        title: r.title,
        date: r.date,
        startMin: r.startMin,
        endMin: r.endMin,
        allDay: r.allDay,
        location: r.location,
      }));
    },
  },
};

// --- Public API ---------------------------------------------------------------
// Build the fetch request for a source. ctx = { today:'YYYY-MM-DD', home:{lat,lng} }.
function prepare(src, ctx) {
  const t = TYPES[src.type];
  if (!t) throw new Error('Unknown source type: ' + src.type);
  return t.buildRequest(src, ctx || {});
}
// Turn a raw response into filtered, de-duped INVITE rows.
function ingest(src, raw, ctx) {
  const t = TYPES[src.type];
  if (!t) throw new Error('Unknown source type: ' + src.type);
  return postFilter(t.normalize(raw, src), src, ctx || {});
}

// --- The user's seed configuration (Ravenswood Manor / Chicago) ---------------
// Editable defaults. Other users start empty and ADD sources; these double as
// worked templates for the add-source UI. `home` lives in Settings (geocoded);
// the ~Ravenswood Manor point here is a placeholder until the real address is set.
const HOME_FALLBACK = { lat: 41.9655, lng: -87.7005 };

// Verified Chicago Park District program center IDs near home.
const MY_PARK_CENTER_IDS = ['4', '8', '13', '521', '578']; // Horner/River/Gompers/Welles/Winnemac
const MY_PARK_NAMES = ['River Park', 'Ronan', 'Horner', 'Welles', 'Winnemac', 'Gompers', 'Jacob', 'Buttercup'];

const DEFAULT_SOURCES = [
  {
    id: 'cpd-park-events', type: 'socrata', label: 'Park events near me',
    category: 'Festival', color: 'personal', enabled: true,
    domain: 'data.cityofchicago.org', dataset: 'pk66-w54g',
    // Public-event permit types only (drops admin holds, athletic training,
    // private photo permits); still ~half private parties → LLM curation later.
    whereTemplate: "reservation_start_date >= '{today}T00:00:00' AND " +
      "(event_type like 'Permit - Festival%' OR event_type like 'Permit - Event %') AND " +
      "(" + MY_PARK_NAMES.map(n => `upper(park_facility_name) like '%${n.toUpperCase()}%'`).join(' OR ') + ")",
    map: { title: 'event_description', startDate: 'reservation_start_date',
           endDate: 'reservation_end_date', category: 'event_type', location: 'park_facility_name' },
    order: 'reservation_start_date', limit: 200,
  },
  {
    id: 'cdot-festivals', type: 'socrata', label: 'Street festivals nearby',
    category: 'Festival', color: 'personal', enabled: true,
    domain: 'data.cityofchicago.org', dataset: 'jdis-5sry',
    whereTemplate: "applicationstartdate >= '{today}' AND upper(worktypedescription) like '%FESTIVAL%'",
    geoRadiusFt: 2 * 5280,           // within ~2 miles of home
    map: { id: 'uniquekey', title: 'applicationname', startDate: 'applicationstartdate',
           endDate: 'applicationenddate', lat: 'latitude', lng: 'longitude', location: 'streetname' },
  },
  {
    id: 'cdot-block-party', type: 'socrata', label: 'Block party on my block',
    category: 'Block party', color: 'personal', enabled: true,
    domain: 'data.cityofchicago.org', dataset: '9zhy-9n5f',
    whereTemplate: "applicationstartdate >= '{today}' AND applicationstartdate < '2100-01-01'",
    geoRadiusFt: 1000,               // only if it's right on my block (~2-3 blocks)
    map: { id: 'uniquekey', title: 'applicationname', startDate: 'applicationstartdate',
           endDate: 'applicationenddate', lat: 'latitude', lng: 'longitude', location: 'streetname' },
  },
  {
    id: 'cpd-kids-3-4', type: 'activenet', label: 'Kid programs (ages 3–4) at my parks',
    category: 'Kids program', color: 'personal', enabled: true,
    host: 'anc.apm.activecommunities.com', org: 'chicagoparkdistrict',
    search: { center_ids: MY_PARK_CENTER_IDS },
    centerNames: MY_PARK_NAMES,      // belt-and-suspenders post-filter on label
    ageMin: 3, ageMax: 4, pageSize: 100,
  },
];

window.Connectors = {
  TYPES, prepare, ingest,
  haversineFeet, boxAround, toYmd, shape, postFilter,
  DEFAULT_SOURCES, HOME_FALLBACK, MY_PARK_CENTER_IDS,
};

})();
