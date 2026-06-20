// connectors.js — Discover / Invites connector framework (calendar app only).
//
// A generic "plug-and-play" data adapter: every source — whatever its origin —
// is described by (1) HOW TO FETCH and (2) a field-MAP from its records into the
// app's one normalized INVITE shape, plus a unified `filters` object. The app
// only ever speaks the normalized shape, so any clean source plugs in.
//
// Source types (Tier 1+2; HTML→LLM extraction is a later tier):
//   - `json`     — generic: fetch a URL, dig records out at `recordPath`, map
//                  fields. Filtering is post-fetch (we don't know the API's
//                  query language). The universal adapter.
//   - `socrata`  — `json` + we DO know SoQL, so the unified filters compile into
//                  a `$where` (date floor, geo bbox, category/place LIKEs, kw).
//   - `activenet`— `json` + the known CPD POST shape; keyword server-side, the
//                  rest post-filtered (age/center server params are ignored).
//   - `ics`      — reuse Calendar.parseEventsIcs, then the same post-filters.
//
// ONE `filters` object per source is the contract shared by the engine, the
// add-source form, and the (optional) LLM (NL → filters + curation). See
// CLAUDE.md "Filter model". PURE: no DOM, no DB, no network. IIFE-wrapped.

(function () {
'use strict';

const Cal = window.Calendar;   // for parseEventsIcs (ics sources); may be undefined in tests

// --- Geo ----------------------------------------------------------------------
const FT_PER_DEG_LAT = 364000;
const EARTH_FT = 20902231;
const toRad = (d) => (d * Math.PI) / 180;

function haversineFeet(lat1, lng1, lat2, lng2) {
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_FT * Math.asin(Math.min(1, Math.sqrt(a)));
}
function boxAround(lat, lng, radiusFt) {
  const dLat = radiusFt / FT_PER_DEG_LAT;
  const dLng = radiusFt / (FT_PER_DEG_LAT * Math.max(0.01, Math.cos(toRad(lat))));
  return { latMin: lat - dLat, latMax: lat + dLat, lngMin: lng - dLng, lngMax: lng + dLng };
}

// --- Small helpers ------------------------------------------------------------
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
function addDaysYmd(ymd, n) {
  const [y, m, d] = ymd.split('-').map(Number);
  const dt = new Date(y, m - 1, d); dt.setDate(dt.getDate() + n);
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
}
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
function dowOf(ymd) {
  const [y, m, d] = ymd.split('-').map(Number);
  return DOW[new Date(y, m - 1, d).getDay()];
}
const num = (v) => { const n = Number(v); return isFinite(n) ? n : null; };
// Dot-path getter so a field-map can reach nested fields ('location.label').
function getPath(obj, path) {
  if (!path) return undefined;
  return String(path).split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}
function moneyNum(v) {
  if (v == null) return null;
  const m = String(v).replace(/[, ]/g, '').match(/-?\d+(\.\d+)?/);
  return m ? Number(m[0]) : (String(v).toLowerCase().includes('free') ? 0 : null);
}

// The normalized INVITE shape every connector emits.
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
    allDay: f.allDay != null ? !!f.allDay : !isFinite(f.startMin),
    startMin: isFinite(f.startMin) ? f.startMin : null,
    endMin: isFinite(f.endMin) ? f.endMin : null,
    lat: f.lat != null ? f.lat : null,
    lng: f.lng != null ? f.lng : null,
    location: f.location || '',
    url: f.url || null,
    ageMin: f.ageMin != null ? f.ageMin : null,
    ageMax: f.ageMax != null ? f.ageMax : null,
    fee: f.fee != null ? f.fee : null,
    pending: true,
  };
}

// Map one raw record → invite, using src.map (dot-path field names).
function mapRecord(rec, src) {
  const m = src.map || {};
  const startRaw = getPath(rec, m.startDate);
  return shape(src, {
    externalId: (m.id && getPath(rec, m.id)) || `${toYmd(startRaw) || ''}|${getPath(rec, m.title) || ''}`,
    title: getPath(rec, m.title),
    category: m.category ? getPath(rec, m.category) : undefined,
    date: toYmd(startRaw),
    endDate: m.endDate ? toYmd(getPath(rec, m.endDate)) : null,
    startMin: m.startMin ? num(getPath(rec, m.startMin)) : undefined,
    endMin: m.endMin ? num(getPath(rec, m.endMin)) : undefined,
    lat: m.lat ? num(getPath(rec, m.lat)) : null,
    lng: m.lng ? num(getPath(rec, m.lng)) : null,
    location: m.location ? getPath(rec, m.location) : '',
    url: m.url ? getPath(rec, m.url) : null,
    ageMin: m.ageMin ? num(getPath(rec, m.ageMin)) : null,
    ageMax: m.ageMax ? num(getPath(rec, m.ageMax)) : null,
    fee: m.fee ? moneyNum(getPath(rec, m.fee)) : null,
  });
}

// --- The unified post-fetch filter engine ------------------------------------
// Honors the whole `filters` schema client-side. (Socrata also pushes some of
// this down to the query; running it again here is harmless and covers the
// generic `json` type, which can't push anything down.)
function timeBucket(startMin) {
  if (!isFinite(startMin)) return 'any';
  if (startMin < 12 * 60) return 'morning';
  if (startMin < 17 * 60) return 'afternoon';
  return 'evening';
}
function applyFilters(events, src, ctx) {
  const F = src.filters || {};
  const today = (ctx && ctx.today) || null;
  const home = (ctx && ctx.home) || null;
  const geo = F.geo || { mode: 'anywhere' };
  const when = F.when || {};
  const cat = F.category || {};
  const inc = (cat.include || []).map((s) => String(s).toLowerCase());
  const exc = (cat.excludeKeywords || []).map((s) => String(s).toLowerCase());
  const kw = (F.keyword || '').toLowerCase();
  const places = (geo.places || geo.neighborhoods || []).map((s) => String(s).toLowerCase());
  const horizonMax = (today && when.horizonDays) ? addDaysYmd(today, when.horizonDays) : null;
  const anchor = geo.anchor === 'home' || !geo.anchor ? home : geo.anchor;

  const seen = new Set();
  const out = [];
  for (const e of events) {
    if (!e.date) continue;
    if (today && e.date < today) continue;                         // date floor
    if (horizonMax && e.date > horizonMax) continue;               // horizon
    // geo
    if (geo.mode === 'radius' && F.geo && geo.radiusFt && anchor) {
      if (e.lat == null || e.lng == null) continue;
      if (haversineFeet(anchor.lat, anchor.lng, e.lat, e.lng) > geo.radiusFt) continue;
    } else if ((geo.mode === 'places' || geo.mode === 'neighborhoods') && places.length) {
      const loc = (e.location || '').toLowerCase();
      if (!places.some((p) => loc.includes(p))) continue;
    }
    // when: days of week / time of day
    if (when.daysOfWeek && when.daysOfWeek.length && !when.daysOfWeek.includes(dowOf(e.date))) continue;
    if (when.timeOfDay && when.timeOfDay !== 'any' && e.startMin != null
        && timeBucket(e.startMin) !== when.timeOfDay) continue;
    // age overlap
    if (F.age && F.age.min != null && F.age.max != null && e.ageMin != null && e.ageMax != null) {
      if (!(e.ageMin <= F.age.max && e.ageMax >= F.age.min)) continue;
    }
    // cost
    if (F.cost && F.cost.freeOnly && e.fee != null && e.fee > 0) continue;
    if (F.cost && F.cost.maxPrice != null && e.fee != null && e.fee > F.cost.maxPrice) continue;
    // category include / exclude / keyword (on title + category)
    const hay = `${e.title} ${e.category}`.toLowerCase();
    if (inc.length && !inc.some((s) => hay.includes(s))) continue;
    if (exc.length && exc.some((s) => hay.includes(s))) continue;
    if (kw && !hay.includes(kw)) continue;
    // de-dupe
    if (seen.has(e.externalId)) continue;
    seen.add(e.externalId);
    out.push(e);
  }
  out.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  const max = F.maxResults || src.maxResults || 200;
  return out.slice(0, max);
}

// --- Socrata: compile the unified filters into a SoQL $where ------------------
function like(field, val) { return `upper(${field}) like '%${String(val).toUpperCase().replace(/'/g, "''")}%'`; }
function socrataWhere(src, ctx) {
  const m = src.map || {}, F = src.filters || {};
  const today = (ctx && ctx.today) || '1970-01-01';
  const clauses = [];
  if (m.startDate) {
    clauses.push(`${m.startDate} >= '${today}'`);
    if (F.when && F.when.horizonDays) clauses.push(`${m.startDate} < '${addDaysYmd(today, F.when.horizonDays)}'`);
  }
  const geo = F.geo || {};
  if (geo.mode === 'radius' && geo.radiusFt && m.lat && m.lng && ctx && ctx.home) {
    const a = geo.anchor === 'home' || !geo.anchor ? ctx.home : geo.anchor;
    const b = boxAround(a.lat, a.lng, geo.radiusFt);
    clauses.push(`${m.lat} > ${b.latMin} AND ${m.lat} < ${b.latMax} AND ${m.lng} > ${b.lngMin} AND ${m.lng} < ${b.lngMax}`);
  }
  const places = geo.places || geo.neighborhoods || [];
  if ((geo.mode === 'places' || geo.mode === 'neighborhoods') && places.length && m.location) {
    clauses.push('(' + places.map((p) => like(m.location, p)).join(' OR ') + ')');
  }
  const inc = (F.category && F.category.include) || [];
  if (inc.length && m.category) clauses.push('(' + inc.map((c) => like(m.category, c)).join(' OR ') + ')');
  if (F.keyword && m.title) clauses.push(like(m.title, F.keyword));
  if (src.whereExtra) clauses.push('(' + src.whereExtra + ')');
  return clauses.join(' AND ');
}

// --- Type handlers: buildRequest + getRecords --------------------------------
const TYPES = {
  json: {
    buildRequest(src, ctx) {
      let url = (src.url || '').replace(/{today}/g, (ctx && ctx.today) || '');
      return { url, method: src.method || 'GET', headers: src.headers || {},
               body: src.body, proxied: src.proxied !== false };
    },
    getRecords(raw, src) {
      const r = src.recordPath ? getPath(raw, src.recordPath) : raw;
      return Array.isArray(r) ? r : [];
    },
  },
  socrata: {
    buildRequest(src, ctx) {
      const p = new URLSearchParams();
      const where = socrataWhere(src, ctx);
      if (where) p.set('$where', where);
      p.set('$order', src.order || (src.map && src.map.startDate) || ':id');
      p.set('$limit', String(src.limit || 400));
      return { url: `https://${src.domain}/resource/${src.dataset}.json?${p.toString()}`,
               method: 'GET', proxied: !!src.proxied };
    },
    getRecords(raw) { return Array.isArray(raw) ? raw : []; },
  },
  activenet: {
    buildRequest(src) {
      const pattern = Object.assign(
        { activity_select_param: 2 },
        src.search || {},
        src.filters && src.filters.keyword ? { activity_keyword: src.filters.keyword } : {});
      return {
        url: `https://${src.host}/${src.org}/rest/activities/list?locale=en-US`,
        method: 'POST', proxied: true,
        headers: { 'Content-Type': 'application/json;charset=utf-8', 'X-Requested-With': 'XMLHttpRequest',
                   'page_info': JSON.stringify({ order_by: '', page_number: 1, total_records_per_page: src.pageSize || 100 }) },
        body: JSON.stringify({ activity_search_pattern: pattern, activity_transfer_pattern: {} }),
      };
    },
    getRecords(raw, src) {
      const r = getPath(raw, src.recordPath || 'body.activity_items');
      return Array.isArray(r) ? r : [];
    },
  },
  ics: {
    buildRequest(src) { return { url: src.url, method: 'GET', proxied: src.proxied !== false }; },
    getRecords(text, src) {
      const parse = Cal && Cal.parseEventsIcs;
      const rows = parse ? parse(String(text)) : [];
      // ICS rows are pre-shaped-ish; wrap so mapRecord's getPath works uniformly.
      return rows;
    },
    map: { id: 'uid', title: 'title', startDate: 'date', startMin: 'startMin', endMin: 'endMin', location: 'location' },
  },
};

// --- Public API ---------------------------------------------------------------
function prepare(src, ctx) {
  const t = TYPES[src.type];
  if (!t) throw new Error('Unknown source type: ' + src.type);
  return t.buildRequest(src, ctx || {});
}
function ingest(src, raw, ctx) {
  const t = TYPES[src.type];
  if (!t) throw new Error('Unknown source type: ' + src.type);
  // ICS carries its own fixed map; others use src.map.
  const effSrc = (src.type === 'ics' && !src.map) ? Object.assign({}, src, { map: t.map }) : src;
  const records = t.getRecords(raw, src);
  const mapped = records.map((r) => mapRecord(r, effSrc));
  return applyFilters(mapped, src, ctx || {});
}

// --- The user's seed configuration (Ravenswood Manor / Chicago) ---------------
// Editable defaults + worked templates for the add-source form. Every source is
// just { type, endpoint, map, filters } — that's the whole plug-and-play config.
const HOME_FALLBACK = { lat: 41.9655, lng: -87.7005 };
const MY_PARK_CENTER_IDS = ['4', '8', '13', '521', '578']; // Horner/River/Gompers/Welles/Winnemac
const MY_PARK_NAMES = ['River Park', 'Ronan', 'Horner', 'Welles', 'Winnemac', 'Gompers', 'Jacob', 'Buttercup'];

const DEFAULT_SOURCES = [
  {
    id: 'cpd-park-events', type: 'socrata', label: 'Park events near me',
    color: 'personal', enabled: true,
    domain: 'data.cityofchicago.org', dataset: 'pk66-w54g',
    order: 'reservation_start_date', limit: 300,
    map: { title: 'event_description', startDate: 'reservation_start_date',
           endDate: 'reservation_end_date', category: 'event_type', location: 'park_facility_name' },
    filters: {
      geo: { mode: 'places', places: MY_PARK_NAMES },
      category: { include: ['Permit - Festival', 'Permit - Event '],
                  excludeKeywords: ['birthday', 'cookout', 'photography', 'wedding', 'camp', 'memorial'] },
      maxResults: 60,
    },
  },
  {
    id: 'cdot-festivals', type: 'socrata', label: 'Street festivals nearby',
    color: 'personal', enabled: true,
    domain: 'data.cityofchicago.org', dataset: 'jdis-5sry',
    map: { id: 'uniquekey', title: 'applicationname', startDate: 'applicationstartdate',
           endDate: 'applicationenddate', lat: 'latitude', lng: 'longitude',
           location: 'streetname', category: 'worktypedescription' },
    filters: { geo: { mode: 'radius', anchor: 'home', radiusFt: 2 * 5280 },
               category: { include: ['FESTIVAL'] }, maxResults: 40 },
  },
  {
    id: 'cdot-block-party', type: 'socrata', label: 'Block party on my block',
    color: 'personal', enabled: true,
    domain: 'data.cityofchicago.org', dataset: '9zhy-9n5f',
    map: { id: 'uniquekey', title: 'applicationname', startDate: 'applicationstartdate',
           endDate: 'applicationenddate', lat: 'latitude', lng: 'longitude', location: 'streetname' },
    filters: { geo: { mode: 'radius', anchor: 'home', radiusFt: 1000 }, maxResults: 20 },
  },
  {
    id: 'cpd-kids-3-4', type: 'activenet', label: 'Kid programs (ages 3–4) at my parks',
    color: 'personal', enabled: true,
    host: 'anc.apm.activecommunities.com', org: 'chicagoparkdistrict',
    recordPath: 'body.activity_items', search: { center_ids: MY_PARK_CENTER_IDS }, pageSize: 100,
    map: { id: 'id', title: 'name', startDate: 'date_range_start', endDate: 'date_range_end',
           location: 'location.label', url: 'detail_url',
           ageMin: 'age_min_year', ageMax: 'age_max_year', fee: 'fee.label', category: 'category' },
    filters: { age: { min: 3, max: 4 },
               geo: { mode: 'places', places: MY_PARK_NAMES }, maxResults: 40 },
  },
];

window.Connectors = {
  TYPES, prepare, ingest, applyFilters, mapRecord, socrataWhere,
  haversineFeet, boxAround, toYmd, getPath, shape,
  DEFAULT_SOURCES, HOME_FALLBACK, MY_PARK_CENTER_IDS, MY_PARK_NAMES,
};

})();
