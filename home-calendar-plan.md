# Home Calendar — Implementation Plan

This document plans the evolution of the Maxiflex Timecard PWA into a **home
calendar** that *also* keeps doing everything it does today. It's a planning
deliverable — no app code changes yet.

Decisions baked in (from the request):

- **Keep the timecard.** Pay-period view, 80-hr tracking, OT, paydate math, and
  CSV all stay. Nothing is removed.
- **Calendar Mode is a sticky, opt-in toggle.** Off by default. The moment the
  user turns it on it stays on (persisted in settings) and reskins the UI into
  calendar mode. The pay-period day rows become the calendar's day rows — the
  two layers share the same days, so the transition is seamless rather than a
  separate app.
- **Local-first.** The whole calendar works with zero accounts and zero
  network, exactly like the timecard does today (IndexedDB via Dexie). Google
  Calendar sync is a **separate, optional, opt-in layer** — see the security
  section, which is why OAuth is *not* the default.

---

## 1. Security: the honest walkthrough on Google sync

You said OAuth "doesn't seem safe." That instinct is healthy. Here's exactly
what's involved, what the real risks are, and how the plan minimizes them.

### What OAuth actually is in this app

There is **no server** in this project — it's a static site on GitHub Pages.
So any Google integration is your browser talking **directly to Google**,
nothing in between that I or anyone else controls.

- You log in on **Google's own page** (`accounts.google.com`). The app never
  sees, stores, or transmits your Google password.
- Google hands the app a **temporary access token** scoped to *exactly* what you
  consent to. That token lives only in your browser, on your device.
- The token is **short-lived (~1 hour)**. In a pure client-side app there is no
  stored long-lived "refresh token," so there's no durable credential sitting
  around to be stolen. When it expires the app re-asks Google (silently if
  you're still signed in).

### The real risks, named plainly

1. **Scope = how much the app can touch.** A Calendar token could, in the worst
   case, read or change calendar data *within the granted scope* while it's
   valid. Mitigation: request the **narrowest scope possible**, and prefer a
   **dedicated app-owned calendar** so the app can never touch your primary
   calendar at all.
2. **A live token on a compromised device.** If your unlocked device is taken
   over while a token is live, an attacker could use it until it expires (~1 hr).
   Mitigation: short token life, no stored refresh token, minimal scope, and you
   can **revoke access instantly** at
   `myaccount.google.com/permissions` with no involvement from the app.
3. **The OAuth Client ID is public — and that's OK.** A client ID is not a
   secret. The defense is Google's **authorized JavaScript origins**: the token
   only works when the request comes from `https://calebpaulsmith.github.io`.
   Someone copying your client ID onto another site gets nothing.
4. **"Unverified app" screen.** Calendar is a "sensitive" scope, so Google shows
   a "Google hasn't verified this app" warning unless you pay for/complete
   Google's verification. For a **personal app you built and are the only user
   of**, you add yourself as a *test user* in your own Google Cloud project and
   click through that screen. That warning is expected and is *not* a sign of
   compromise — it just means you skipped Google's review of your own code.
5. **Supply chain.** Google sync loads Google's official auth library from
   Google's CDN. (Separately, the app already loads Dexie from unpkg — a
   pre-existing trust dependency we could pin/self-host as hardening.)

### How the plan respects the concern: a risk ladder

Sync is **tiered**, and you opt in one rung at a time. Calendar Mode itself
needs **none** of this — it's fully usable at Tier 0 forever.

| Tier | What it does | Login? | Risk |
| --- | --- | --- | --- |
| **0. Local only** | Full calendar in IndexedDB, offline. The default. | No | None |
| **1. `.ics` export / import** | Download an `.ics` of a pay period / range; import an `.ics` someone sends you. | No | Minimal — it's just a file |
| **2. OAuth read-only** | App *reads* your Google events to auto-import them. **Cannot change anything in Google** (`calendar.readonly` scope). This is the "can it read my calendar and auto-put in events?" feature. | Yes | Low — read-only, short token |
| **3. OAuth read/write to a dedicated calendar** | App creates a **new secondary calendar** and reads/writes only it, using the **`calendar.app.created`** scope — which by design lets an app touch **only calendars it created and never your primary calendar** (verified against Google's scope docs). This is "add the current PP to Google and keep it updated." | Yes | Contained — can't see your main calendar |

**Recommendation:** Build Tier 0 + Tier 1 first (zero login, immediate value).
Add Tier 2 (read-only, can't hurt anything) when you want auto-import. Only add
Tier 3 — and only against a dedicated calendar — once you've lived with the
read-only version and trust it. You can stop at any rung.

**Decision (chosen):** Go with **Tier 3 OAuth read/write to a dedicated
calendar**, on the **same Gmail account**, writing to a **new secondary calendar
the app creates**. Use the **`calendar.app.created`** scope so the app is
*structurally incapable* of seeing or modifying your primary calendar — it can
only touch the calendar it made. (Answering "does OAuth let me pick a calendar?":
yes — after consent the app can list calendars and/or create its own, and with
this scope it's locked to the one it created.) Every credential lives only in
your browser; there's no server in the middle. Tier 3 is also exactly the bridge
the Skylight needs (§12). Tiers 0/1 still ship first as the offline baseline.
The later "see *all* my Google events" view (§12) is the one feature that needs
a broader read scope (`calendar.readonly`) — a separate, explicit opt-in.

### Re-authentication & token lifetime (the "every hour" gripe)

The "~1 hour" is the **access token's lifetime, not a login interval.** You will
**not** be clicking a consent screen every hour. Here's the reality:

- With Google Identity Services' **token client**, the app renews the token
  **silently in the background** (`requestAccessToken({ prompt: '' })`) as long
  as you're still signed into Google on that device and have granted consent
  once. No popup, no interaction — the renewal is invisible.
- A *visible* re-consent only happens in edge cases: the browser was fully
  closed for a long time, your Google session ended, or **Safari/iOS Intelligent
  Tracking Prevention** blocks the silent cross-site renewal. Pure browser-only
  OAuth has no durable refresh token, so those edges can force a click.
- **Decision (chosen): build the token-broker up front.** A tiny serverless
  broker (e.g., a free Cloudflare Worker) holds the client secret + a long-lived
  **refresh token** and hands the app fresh access tokens on demand. This makes
  auth durable across restarts, immune to Safari/iOS ITP, and actually *more*
  secure (the secret and refresh token never touch the browser). It ships
  **with** the Google-sync phase rather than being deferred — so you never see an
  hourly re-prompt. The OAuth flow becomes the **authorization-code + refresh**
  flow (broker-side) instead of the browser-only token flow.
- **Reassurance:** the **Skylight wall display does not depend on the app's
  token at all.** Skylight keeps its *own* durable Google connection, so the wall
  keeps updating even if the app's token lapses. The app's token only needs to be
  alive in the moments you're actively adding/editing in the app — exactly when
  silent renewal works.

> Aside: in *this* Claude session I (the assistant) happen to have Google
> Calendar/Gmail tooling connected, so I could do one-off reads or migrations on
> request. But that's me doing it manually, which is the opposite of what you
> asked for ("automatic, not LLM-done"), so the plan above is about the **app**
> syncing itself, not me.

---

## 2. Architecture & how Calendar Mode layers on

No build step, classic `<script>` tags, Dexie, GitHub Pages — all unchanged.
Watch the existing gotchas (CLAUDE.md): any new script must avoid the
script-scope `const` collision (wrap in an IIFE or use unique top-level names),
and `CACHE_VERSION` in `sw.js` must bump on every shell change.

**New file: `calendar.js`** (wrapped in an IIFE), holding the recurrence engine,
event helpers, color palette, and `.ics` generation. `time.js` stays pure;
`db.js` gains the new tables; `app.js` gains the calendar UI and routing.

**Two modes, one screen layout.** The app has exactly two modes:

- **Timecard mode (default — untouched).** Looks and behaves *exactly* as it
  does today. This is the work-shareable view: weekends hideable, no events, and
  **zero Google / zero network / zero OAuth — ever.** This must not change; it's
  what gets shared at work.
- **Calendar mode (opt-in, sticky).** A new setting `calendarMode` (bool,
  default `false`). Turning it on is sticky. `body` gets `data-mode="calendar"`
  alongside the existing `data-view`, which CSS uses to layer event lanes onto
  the *same* week/pay-period day rows. Differences from timecard mode:
  Saturday & Sunday are **always shown** (no hide/reveal), event lanes appear on
  each day, day-tap expands in place, and the day editor gains event controls.

**Google is gated behind calendar mode, and then behind an explicit connect.**
No OAuth request, token, or Google network call can fire unless (a) calendar
mode is on **and** (b) the user explicitly taps "Connect Google." This keeps
timecard mode completely offline and safe to share. Calendar mode itself is
fully usable **local-only** with no Google connection — Google is purely for
later sync + the eventual "see all my Google events" view (§12), which is a
follow-on, not the core. The core purpose is fast week / day / hour planning,
all local.

---

## 3. Data model (Dexie v2)

Bump `db.version(2)` with an upgrade that leaves v1 tables intact and adds:

```
events: 'id, date, title, [needsScheduling], googleId'
  {
    id,                // uuid
    date,              // YYYY-MM-DD — single event's day, or a series anchor; null if unscheduled
    title,             // custom name
    allDay,            // bool
    startMin, endMin,  // minutes since midnight (null when allDay)
    color,             // palette token ('blue','green','red',... ) — see §6
    notes,             // optional
    location,          // optional
    rrule,             // iCalendar RRULE string or null (recurrence) — §5
    exdates,           // [YYYY-MM-DD] cancelled occurrences of a series
    seriesId,          // links an override instance back to its series
    needsScheduling,   // bool — backlog item with no firm date — §7
    source,            // 'local' | 'google'
    googleId,          // Google event id when synced (Tier 2/3)
    createdAt, updatedAt
  }

eventHistory: 'title, lastUsed'   // the "remember what I added" list — §8
  {
    title,             // normalized key (lowercased/trimmed)
    displayTitle,      // as the user typed it
    defaultColor,      // remembered color so re-adding auto-colors — automatic!
    lastUsed,          // timestamp (indexed) — drives newest-to-oldest ordering
    count              // how many times used
  }
```

Recurrence is stored as a standard **RRULE** string. That's the same grammar
`.ics` and Google Calendar use, so recurrence round-trips cleanly through both
sync paths instead of needing translation.

CSV backup gains an **`EVENTS`** section (and `EVENT_HISTORY`) so the existing
export/import stays a complete backup. Old CSVs without those sections import
fine (the sections are just absent).

---

## 4. Mapping every request to a piece of the plan

| Your request | Where it's handled |
| --- | --- |
| Default timeline 7:30 AM – 10:00 PM | `DEFAULT_SCALE_START = 7*60+30`, `DEFAULT_SCALE_END = 22*60`; widen `ABSOLUTE_END_MIN` to 22:00+. In calendar mode, drop the non-linear "core compression" (that's tuned for 9–2:30 workdays) in favor of a linear scale so evening events read correctly. (§9) |
| Add events, single **and** recurring, custom-named | `events` table + RRULE engine; add/edit in the full-screen day editor. (§3, §5) |
| Push current pay period to Google `.ics` that "updates properly" | Tier 1 `.ics` export for one-time; Tier 3 OAuth write to a dedicated calendar for live updates. (§1) |
| Read my calendar & auto-add events | Tier 2 OAuth read-only import. (§1) |
| Very easily color-code events | Palette of named colors + one-tap swatches; remembered per-title default color (auto-applies). (§6) |
| "Dragger things" become several color lines | Timeline gains stacked, per-event **color lanes** on top of the existing work/leave/lunch bars. (§9) |
| Tap a day → expands to show that day's events below | New inline accordion on the day card (calendar mode). (§9) |
| "Edit" → full-screen add/edit/delete for the day | Repurpose/extend the existing Day Editor view as the full-screen event editor. (§9) |
| Remember added events in a list below, forever, each deletable | `eventHistory` table; deletable rows. (§8) |
| List narrows as you type (prefix), newest→oldest | Prefix query on `eventHistory`, ordered by `lastUsed` desc. (§8) |
| "Need to schedule" list | `needsScheduling` events surfaced as a backlog you can later drop onto a day. (§7) |

---

## 5. Recurrence engine

- Store an `rrule` (e.g. `FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=1`) on the series'
  anchor event.
- **Expand on read:** given a visible date window (a pay period, a month), a
  pure function in `calendar.js` produces the concrete occurrences for that
  window. No pre-materializing thousands of rows.
- **Exceptions:** `exdates` removes a single occurrence; an *override* event
  (its own row carrying `seriesId`) replaces one occurrence (e.g. "this Tuesday
  the meeting moved to 3 PM"). Standard iCalendar semantics → free `.ics`/Google
  fidelity.
- Editing a recurring event prompts the familiar **"this event / this and
  following / all events"** choice.

A tiny dependency-free RRULE subset (DAILY/WEEKLY/MONTHLY/YEARLY + `INTERVAL`,
`BYDAY`, `COUNT`, `UNTIL`) covers ~all home-calendar needs without pulling in a
library. If we later want full RFC coverage, `rrule.js` is the drop-in.

---

## 6. Lane structure & color (final, per feedback)

The day timeline has **two tiers**:

**A. "Me" line — one lane, normal thickness (the main bar).** Both **Work** and
**Personal** events live on this single line at the same thickness, distinguished
**by color** (e.g. work = one color, personal = another). This is the primary
bar you already have.

**B. "People" lines — very thin lanes ABOVE the Me line.** **Ritza** and
**Amelia** events render as **much thinner** lines sitting above the Me line.
**Person is tracked by color** (Ritza = her color, Amelia = hers). These thin
lines **still have draggable brackets** so you can set their event times the same
way as the main bar. **Overlapping people-events stack upward**, each keeping its
person-color. So a glance shows: my stuff on the main line, and slim
person-colored ticks above it telling me who-else-has-what and roughly when.

**Labels = the event name, not the person.** Each lane/event is labeled with
*what the event is* (e.g. "Soccer", "Dentist"), never the person's name — the
person is conveyed by color. So colors here are **meaningful by design** (work vs
personal; per person), kept to a **small, high-contrast, colorblind-distinct
set** (~4: work, personal, Ritza, Amelia).

**Scheduling with people.** The add flow lets you create an event and attach a
person (Ritza/Amelia); that places it on their thin line and wires the Google
side (invite / shared / read-only — see §12).

**Automatic memory:** `eventHistory` remembers a title's category/person + color,
so re-adding "Soccer" lands on the right line with the right color automatically.
This also sets up future **weekly time-spent rollups** (§11).

---

## 7. "Need to schedule" list

- Events created with `needsScheduling: true` and no firm `date` live in a
  backlog list (shown on the Metrics/overview screen or a dedicated panel).
- Assigning a date (tap → "schedule for…", or drag onto a day) flips
  `needsScheduling` to false and sets `date`/times.
- Doubles as a lightweight to-do inbox ("dentist — sometime this month").

---

## 8. Event memory & type-ahead

- Every saved event upserts into `eventHistory` (key by normalized title;
  bump `lastUsed`, `count`).
- The title field in the editor shows a live list **below** it. With no input it
  shows most-recent-first. As you type, it filters to titles **starting with**
  what you typed, still ordered newest→oldest (your exact spec). Dexie:
  `eventHistory.where('title').startsWithIgnoreCase(q)` then sort by `lastUsed`.
- Each suggestion row has a **delete** affordance to forget it forever.
- Picking a suggestion pre-fills the title **and** its remembered color/duration.

---

## 9. UI / timeline changes

**Guiding principle (from feedback): mega-clean at a glance, detail on tap.**
The whole period stays on **one screen with no scrolling**, exactly like today —
even when there are after-work, Saturday, and Sunday events. Events never
introduce scrolling; they live as thin lanes *within* each existing day row.

**Same week / pay-period view.** No month grid, no new layout. The day rows are
the same rows. In calendar mode, Sat & Sun are always shown (in timecard mode
they stay hideable — unchanged).

**Default scale + linear mode.** Default window 7:30 AM–10:00 PM. In calendar
mode use a **linear** minute scale (the current non-linear core compression is
timecard-specific). The bar engine already positions children by
`dataset.leftMin`/`widthMin`, so lanes drop in with no structural rewrite.

**Collapsed day = the two-tier lanes (§6).** The **Me line** (work + personal,
one bar, color-coded) plus **very thin person lines above it** (Ritza/Amelia,
color = person), each positioned by start/end minute. Overlapping people-events
stack upward, very thin. The point: a quick downward glance across the week
answers "do I have something after work, roughly when, and is anyone else
involved."

**Tap a day → it expands in place (~3× taller). One day at a time.** Tapping a
day grows *that row* to about triple height, right where it sits (no navigation,
no scroll jump); only one day is ever expanded, so the full period still fits
with no scrolling. The Me line and the thin person lines all gain height to read
and manipulate. Tap again (or tap elsewhere) to collapse.

**Each event shows its name as a label** (what it is — not the person). Names
ride on/near each bar in the expanded row.

**Edit in the expanded row — reuse the maxiflex drag.** In the expanded state
the user can:
- **Drag to adjust times** using the *existing* bracket/drag handles — on the Me
  line **and** on the thin person lines (people-events are draggable too).
- **Add an event** with a quick "+" button, then **drag its edges** to set
  start/end — exactly like adding/resizing a maxiflex entry — and optionally
  **attach a person** (Ritza/Amelia) which drops it onto their thin line and
  wires the Google side (§12).
- **Rapid-name flow:** the title field with the type-ahead list (§8) so naming is
  one or two taps, and it remembers category/person + color.

**Full-screen editor for deeper edits.** A further action (an **Edit** button in
the expanded row) opens the full-screen day editor for recurrence, notes,
color/category overrides, delete, and the existing timecard entry + leave
controls. So: **collapsed = glance; tap = expand + quick drag/add; Edit =
full detail.** Two levels, friendly, no eye-blur.

**No regressions.** Timecard mode (calendar mode off) looks and behaves exactly
as it does today — the shareable timecard is untouched.

---

## 10. Phased roadmap (suggested PR sequence)

Each phase is independently shippable and reviewable.

- **Phase 0 — Data foundations.** Dexie v2 (`events`, `eventHistory`),
  `calendar.js` skeleton, color palette CSS vars, `calendarMode` setting +
  sticky toggle in Settings. No visible UI yet beyond the toggle.
- **Phase 1 — Calendar UI core.** Calendar-mode reskin (Sat/Sun always shown);
  7:30–22:00 linear scale; **category lanes** (work-top / personal / thin third)
  on each day row; **tap-a-day → expand ~3× in place** with labeled lanes;
  edit via the existing drag handles + quick-add with edge-drag + rapid naming;
  **Edit** button → full-screen day editor (add/edit/delete). Single events only.
- **Phase 2 — Recurrence, memory, backlog.** RRULE engine + occurrence
  expansion + exceptions; `eventHistory` type-ahead (prefix, newest-first,
  deletable, remembered color); "need to schedule" list.
- **Phase 3 — `.ics` + CSV (no login).** RFC-5545 `.ics` export for a pay period
  / date range incl. recurrence; `.ics` import; `EVENTS`/`EVENT_HISTORY` CSV
  sections.
- **Phase 4 — Google sync (with token-broker up front).** Stand up the
  serverless token-broker (auth-code + refresh flow) first so auth is durable;
  then Tier 3 read/write to the app-created calendar (`calendar.app.created`);
  per-person sub-calendars + invite/shared/read-only wiring (§12);
  connect/disconnect + revoke UI; conflict handling (last-write-wins keyed on
  `updatedAt`, never deleting Google events the app didn't create). The broader
  read-only "see all my Google events" view is a later add-on.

Remember after each shell change: bump `CACHE_VERSION` in `sw.js`.

---

## 11. Feature suggestions ("more uses")

Ideas that fit a *home* calendar and lean on what's already here:

- **Shared household view via a read-only `.ics` link** so a partner can
  subscribe to your schedule (works the moment Tier 3 / a published calendar
  exists).
- **Reminders / notifications.** PWAs can fire local notifications; "Trash night
  9 PM," "leave for appointment in 30 min." (iOS PWA notification support is
  improving but still finicky — worth a feasibility spike.)
- **Templates / quick-add.** "Add my usual week" — seed a set of recurring home
  events the way the default *work* schedule already seeds work days.
- **Chores / rotation tracker.** Recurring color-coded events with a "whose turn"
  rotation — natural fit for the recurrence engine.
- **Bills & renewals.** All-day recurring events in a distinct color, optionally
  surfaced in the "need to schedule"/overview as upcoming.
- **Meal planning lane.** A dedicated color used as a daily dinner plan; pairs
  with a "this week's meals" summary.
- **Countdowns.** "Days until <event>" surfaced on the overview (you already
  compute date deltas everywhere).
- **Conflict/overlap warnings** when two timed events collide on a day.
- **Week & month views.** Today's UI is pay-period (2×7). A month grid would
  make calendar mode feel like a "real" calendar; the day-cell renderer can
  reuse the event-lane component.
- **Natural-language quick add** ("lunch with Sam fri 12") parsed *locally* with
  a small date parser — automatic, no LLM, no network.
- **Weather strip** per day (optional, needs a network call — keep opt-in to
  preserve the offline-first guarantee).

**Requested "for later" features (parked, not in the first phases):**

- **Activity suggestions from pre-located sources.** Pull from a curated feed
  (e.g. **Chicago Park District** programs), filtered to a child's age (Amelia),
  date range, and your availability gaps, and surface them as one-tap adds /
  "need to schedule" items. Needs a source feed + a filtering layer; design once
  the core planner is solid.
- **Weekly time-spent rollups by category.** Since events auto-categorize (§6),
  roll up hours per category per week ("X hrs work, Y hrs personal, Z hrs
  Ritza") — a natural extension of the existing metrics view.
- **Full "see all my Google calendar" view.** A read-only view of *every* Google
  event (broader `calendar.readonly` scope), separate from the planning lanes.
  Explicitly later; the core tool is local week/day/hour planning.

---

## 12. Skylight Calendar integration

The user is adding a **Skylight Calendar** (wall-mounted family display). Key
fact: **Skylight has no push API — it *reads* calendars.** It two-way syncs only
with **Google Calendar**; everything else (Apple, Outlook, and **iCal/ICS URL**
subscriptions) is **one-way** (Skylight reads, can't write back). So the app
never talks to the Skylight directly — it talks to Google, and the Skylight
mirrors Google on the wall.

**This means the Tier-3 dedicated Google calendar (§1) *is* the Skylight
bridge.** One mechanism serves both: the app writes pay periods + events to its
dedicated Google calendar → Skylight displays them on the wall → because it's
Google, edits made on the wall flow **back** to Google, and the app re-reads
them. No extra integration work beyond Tier 3.

What to build *because* of the Skylight:

- **Per-person sub-calendars, each wired to a configurable target (decided:
  use sub-calendars).** Each person line (Ritza/Amelia, §6) maps to a Google
  sub-calendar so the wall color-codes by person. Crucially, **how the app
  touches each person's calendar is per-person configurable**, because you don't
  always want to *write* to someone else's calendar:
  - **Invite mode (default for shared events).** When you make an event "for both
    of us," the app creates it on **your** app calendar and **adds the person as a
    guest (attendee)** — Google then puts it on *their* calendar via a normal
    invitation. The app never writes directly into their calendar; it just
    invites. This is the clean Google-native path and matches "me adding a
    calendar item for both of us should just invite her."
  - **Shared sub-calendar mode.** A calendar you both can edit, if you'd rather
    co-own one.
  - **Read-only mode.** The app **reads** a person's calendar to *display* their
    events on their thin line, and **never writes** anything for them.
  - Each person gets a small setting: which calendar, and which of these modes.
- **Scope note (ties to §1).** Invite mode works under the minimal
  `calendar.app.created` scope (you're only creating events on your own app
  calendar, just with guests). **Read-only mode of someone else's calendar needs
  more:** that person shares their calendar with your Gmail, and the app uses the
  broader `calendar.readonly` scope. So read-only person-lanes are a deliberate,
  separate opt-in — invite mode stays on the tight scope.
- **Per-event "Show on Skylight" toggle.** Not everything belongs on a shared
  family wall. Each event chooses: *sync to Google (→ wall)* vs *keep
  local/private*. Cheap to add, high value.
- **Publish the maxiflex pay period as its own Skylight-visible calendar** so the
  family sees your work hours on the wall, auto-updating — something Skylight
  can't compute itself.

What **not** to build (Skylight already does these well, don't duplicate):

- Chore charts + reward stars, meal planning, the photo frame, shared lists, and
  "Magic Import" (screenshot → AI event). The app stays focused on its unique
  value: timecard/OT/paydate math, fast phone-side capture, and the "need to
  schedule" backlog — all feeding the wall through the same Google bridge.

Caveats / resilience:

- **Two-way is Google-only** on Skylight. To get wall→app edits, route through
  Google, not an ICS feed.
- **The wall doesn't depend on the app's token.** Skylight maintains its own
  durable Google connection, so the display keeps updating even if the app's
  OAuth token lapses (ties back to the re-auth note in §1).

Sources: Skylight Support —
[what it syncs with](https://skylight.zendesk.com/hc/en-us/articles/35986090425627-What-does-Skylight-Calendar-sync-with),
[two-way Google sync](https://skylight.zendesk.com/hc/en-us/articles/19197773155995-Skylight-Calendar-Two-Way-Sync-with-Google-Calendar),
[Calendar URL / ICS subscription](https://skylight.zendesk.com/hc/en-us/articles/4416124481819-Syncing-subscribed-calendars-using-the-Skylight-app).

---

## 13. Decisions locked & remaining questions

**Locked in (from feedback) — all resolved:**

- ✅ **Same week / pay-period view**, one screen, no scrolling. **No** month grid
  now (parked).
- ✅ **Calendar mode** is an opt-in sticky toggle; core tool is local week / day /
  hour planning. "See all Google events" is later.
- ✅ **Two-tier lanes (§6):** **Me line** = work + personal, one bar, same
  thickness, **color-coded** (work vs personal). **Person lines** = Ritza +
  Amelia, **very thin, above** the Me line, **color = person**, with draggable
  brackets; overlapping people-events **stack upward**. **Labels = event name,
  not person.**
- ✅ **Tap a day → expands ~3× in place, one day at a time** (period still fits,
  no scroll). Edit on Me line **and** person lines via existing brackets;
  quick-add + edge-drag + rapid naming; **Edit** button → full-screen detail.
- ✅ **Sat & Sun always shown in calendar mode**, hideable in timecard mode.
  **Timecard mode stays exactly as-is** (work-shareable, no Google).
- ✅ **Google = new secondary calendar on the same Gmail**, `calendar.app.created`
  scope (can't touch primary). No OAuth unless calendar mode + explicit connect.
- ✅ **Token-broker built up front** (durable auth, no hourly re-prompts; §1).
- ✅ **Per-person sub-calendars**, each wired per-person as **invite / shared /
  read-only** (§12). Default "event for both of us" = **invite the person as a
  guest** (lands on their calendar; app never writes to it). Read-only person
  lanes need them to share their calendar + the broader read scope.

Everything needed for **Phase 0** is settled. Open item is operational, not
blocking: when we reach Phase 4, you'll provide the family members' **emails**
(for invites) and decide each person's mode (invite vs shared vs read-only).

