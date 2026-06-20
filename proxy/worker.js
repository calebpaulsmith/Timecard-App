// Cloudflare Worker — CORS fetch-proxy ("tunnel") for the Discover connectors.
//
// The Timecard/Calendar app is a static PWA (GitHub Pages, no server). Socrata
// (data.cityofchicago.org) sends CORS headers and is fetched DIRECTLY from the
// browser — it does not need this. But ActiveNet, arbitrary .ics feeds, and
// geocoding (Nominatim) do not allow cross-origin browser fetches, so those go
// through here. The Worker is a dumb relay: it only forwards to an allowlist of
// hosts and stamps permissive CORS on the way back.
//
// Deploy (free tier is plenty):
//   npm i -g wrangler
//   wrangler deploy            # from this proxy/ dir, with the wrangler.toml below
// Then set the deployed URL as `proxyBase` in the app's calendar Settings, e.g.
//   https://timecard-proxy.<you>.workers.dev
// The client calls:  <proxyBase>/proxy?url=<encoded target URL>   (method/body passed through)
//
// Reuses the same pattern as the user's CurbIntel Worker (/api/nws, /api/usgs).

const ALLOW_HOSTS = [
  'data.cityofchicago.org',           // Chicago Data Portal (Socrata)
  'datacatalog.cookcountyil.gov',     // Cook County (Socrata) — future
  'anc.apm.activecommunities.com',    // Chicago Park District (ActiveNet)
  'nominatim.openstreetmap.org',      // home-address geocoding
];

// A descriptive UA keeps us polite with Nominatim/NWS-style hosts (their usage
// policies require one). Set a contact you control.
const USER_AGENT = 'TimecardCalendar/1.0 (+https://calebpaulsmith.github.io/Timecard-App/)';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, page_info, X-Requested-With',
  'Access-Control-Max-Age': '86400',
};

export default {
  async fetch(request) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });

    const reqUrl = new URL(request.url);
    if (reqUrl.pathname !== '/proxy') {
      return json({ error: 'Not found. Use /proxy?url=...' }, 404);
    }
    const target = reqUrl.searchParams.get('url');
    if (!target) return json({ error: 'Missing ?url=' }, 400);

    let t;
    try { t = new URL(target); } catch { return json({ error: 'Bad url' }, 400); }
    if (t.protocol !== 'https:') return json({ error: 'https only' }, 400);
    if (!ALLOW_HOSTS.includes(t.hostname)) {
      return json({ error: 'Host not allowed: ' + t.hostname }, 403);
    }

    // Forward selected headers + body; never forward cookies / auth.
    const fwd = new Headers();
    fwd.set('User-Agent', USER_AGENT);
    fwd.set('Accept', request.headers.get('Accept') || 'application/json, text/calendar, */*');
    const ct = request.headers.get('Content-Type');
    if (ct) fwd.set('Content-Type', ct);
    const pageInfo = request.headers.get('page_info');
    if (pageInfo) fwd.set('page_info', pageInfo);
    const xrw = request.headers.get('X-Requested-With');
    if (xrw) fwd.set('X-Requested-With', xrw);

    const init = { method: request.method, headers: fwd };
    if (request.method === 'POST') init.body = await request.text();

    let upstream;
    try {
      upstream = await fetch(t.toString(), init);
    } catch (err) {
      return json({ error: 'Upstream fetch failed', detail: String(err) }, 502);
    }

    const headers = new Headers(CORS);
    const upCt = upstream.headers.get('Content-Type');
    if (upCt) headers.set('Content-Type', upCt);
    headers.set('Cache-Control', 'public, max-age=300');   // 5-min edge cache
    return new Response(upstream.body, { status: upstream.status, headers });
  },
};

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: Object.assign({ 'Content-Type': 'application/json' }, CORS),
  });
}
