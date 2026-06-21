# TV Home Dashboard — Concept

A glanceable, zero-interaction **daily-briefing display on the living-room (or
bedroom) TV**: it turns on when you walk in and turn the lights on, and shows a
uniquely-styled daily report — calendar (week + month), to-dos, grocery list,
suggested events, a stoic quote or two. The value is *ambient and effortless* —
you don't open an app, the report is just there on the wall.

This is a **separate personal-track product**, not part of the sellable iOS
timecard. It is the **culminating surface for the calendar app + the
Discover/Invites connector engine + the BYO-LLM layer** — they all feed the
daily report. See `CLAUDE.md` for how the personal track is fenced off from the
timecard MVP.

## JTBD

> "When I start my day, I want a beautiful daily report — what's on my calendar
> this week and month, what I have to do, what we need from the store, and a few
> things worth doing nearby — to be *already on the wall*, without me reaching
> for a phone or opening anything."

The mental model is a **self-updating morning paper / fridge whiteboard**:
passive, always-current, no interaction. Reading-only on the TV — you manage the
underlying data elsewhere (the calendar app / Google directly).

## Architecture (DECIDED): Apple TV screensaver via a Photos album

The report is rendered to an **image** and shown as the **Apple TV screensaver**,
sourced from a Photos album. This is the chosen approach because the screensaver
*is* auto-display — it sidesteps the "force my app to the foreground on wake"
problem entirely, and may require **no tvOS app at all**.

**Pipeline:**
1. **Render job** (scheduled, e.g. daily 5am): pull Google + connectors + LLM →
   compose a styled HTML report → screenshot to a **PNG at a stable URL**.
   Candidate hosts: Cloudflare **Browser Rendering** (fits the existing Worker
   from the connector proxy) or a home machine (Pi/Mac) running headless Chromium.
2. **iOS Shortcut automation** (scheduled Personal Automation): `Get Contents of
   URL` (the PNG) → `Save to Photo Album` (the report album). This is the bridge
   from a web image into an iCloud album.
3. **Apple TV**: screensaver source = that album; the TV is powered on via
   HomeKit (lights-on automation) or a smart plug.

### Verified facts (the load-bearing assumptions)
- **Apple TV 4K screensaver can source a Shared Album** (also personal albums,
  Favorites, Memories). Confirmed via Apple Support.
- **Shortcuts can add a photo to an album** (incl. shared) via `Save to Photo
  Album`, runnable unattended from a scheduled Personal Automation. Confirmed.
- **Replace is NOT one clean action — append, don't replace.** There is no
  reliable Shortcuts action to *remove* a photo from a shared album (removal is a
  manual touch-and-hold → "Delete from Shared Album"); the general `Delete Photos`
  action works on library photos but typically shows a **confirmation prompt**
  that breaks hands-off automation. So the Shortcut reliably *adds* today's
  report; clearing old ones is the friction point.

### Album hygiene (because we can't auto-replace)
Stale content (last week's grocery list) must not resurface in the rotation.
Options, cheapest first:
1. **One image at a time + weekly manual clear** (~10s). Ship this for MVP.
2. **Single composite image** so only the latest few exist — still needs pruning.
3. **Personal album + a separate "prune" Shortcut** tapped occasionally (accepts
   the delete confirmation). More control, more fiddle.

### Idle/timing notes
- On power-on the Apple TV lands on the Home screen; the screensaver starts after
  the idle timer (~2 min min). To make the report appear *instantly* when the TV
  turns on, leave the **Apple TV always on/idle** (screensaver already running)
  and gate on **TV power** (HomeKit/plug).
- Apple TV pulls new album photos periodically (not instant) — fine for a
  once/few-times-daily report.

## The report (content + craft)

A daily, **uniquely-styled** report image — the styling/quote can vary day to day
so it feels alive. Sections:
- **Calendar** — weekly and monthly view (Google Calendar).
- **To-dos** — items due this week (Google Tasks).
- **Grocery list** (Google Tasks list).
- **Suggested events** — surfaced from the **Discover/Invites connector engine**
  (`connectors.js`, the Chicago Socrata sources). The report is the *push surface*
  for invites — passive discovery, now on the wall.
- **Stoic quote(s)** — one to three, chosen for the day.
- **Webpage reminders (stretch)** — a headless-rendered screenshot of an event's
  web page (connectors already carry URLs) embedded to entice attendance.

### LLM's role (reuses the planned BYO-LLM layer)
The deferred BYO-LLM layer (Claude API / local Ollama; see `CLAUDE.md`) gets a
new job: **compose the daily report** — pick the quote(s), curate/rank which
invites make the cut (taste from accept/dismiss history), and theme the daily
look + framing. Degrades gracefully: no model → plain styling, date+geo-ordered
invites, a quote from a static list.

## Reuse map (this is mostly assembly, not new invention)

| Report piece | Source / existing component |
| --- | --- |
| Week/month calendar | Google Calendar API (read-only) |
| To-dos | Google Tasks (read-only) |
| Groceries | Google Tasks list (read-only) |
| Suggested events | `connectors.js` engine + `DEFAULT_SOURCES` + Worker proxy |
| Curation, quotes, styling | planned BYO-LLM layer |
| Webpage shots | headless Chromium in the render job |
| The report UI itself | a web page (reuses the app's rendering skills) |

Google is **read-only** on this side; everything is display-only. The TV report
is **decoupled** from the calendar app — it reads Google + runs the connectors;
it does not need the PWA's deferred Google *write*-sync built first (you can
manage data directly in Google for now).

## MVP scope

**In:**
1. **Render job** producing a styled daily report **PNG at a stable URL** from
   Google Calendar + Google Tasks (calendar, to-dos, groceries) + connector
   suggested-events + a stoic quote.
2. **iOS Shortcut** (scheduled) that fetches the PNG and adds it to the report
   album. Album hygiene = weekly manual clear (option 1).
3. **Apple TV** screensaver pointed at that album; TV powered on via HomeKit/plug
   when the lights come on; Apple TV left always-on so the report shows instantly.

**Deferred:**
- LLM curation/quote/styling (start with static quote list + simple ranking).
- Webpage-screenshot reminders.
- Automated album pruning / true replace.
- Bedroom as a second unit.
- The PWA → Google *write* sync.

## Fallback architecture (documented, not chosen): Android/Google TV box

If the screensaver path disappoints (album sync latency, can't keep it clean,
styling looks bad as a photo), fall back to a **web-view dashboard on a cheap
Android/Google TV box**: app auto-launches on boot (`BOOT_COMPLETED`), sends
HDMI-CEC to power the TV, woken by a smart plug + lights automation. Same render
logic, shown live in a kiosk web view instead of as a screensaver image. Native
Google, full web-code reuse. (Smart-TV built-in apps — Tizen/webOS — are a dead
end: locked-down auto-launch.)

## Open questions / riskiest assumptions

1. **Does the screensaver actually look good and behave as expected with a
   text-dense report image?** Spike first: drop one hand-made report PNG into a
   shared album, set it as the Apple TV screensaver, eyeball legibility + how the
   pan/zoom (Ken Burns) treats text. This gates the whole approach.
2. **Album hygiene** — confirm the weekly-clear flow is tolerable, or whether a
   prune Shortcut is worth building.
3. **Render host** — Cloudflare Browser Rendering vs. a home Pi/Mac for the
   headless screenshot job (auth to Google + reaching the connectors + cost).
4. **Google token longevity** in an unattended render job (server-side OAuth /
   refresh token).
5. **Apple TV always-on vs. idle delay** — accept ~2 min delay, or keep it always
   powered so the report shows the instant the TV turns on.
