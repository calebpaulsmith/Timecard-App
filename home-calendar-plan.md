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
| **3. OAuth read/write to a dedicated calendar** | App pushes pay periods + events two-way into a calendar **it creates and solely owns** ("Maxiflex / Home"). Walled off from your main calendar by scope + by only ever editing events it created (tagged with a private property). This is "add the current PP to Google and keep it updated." | Yes | Moderate, contained |

**Recommendation:** Build Tier 0 + Tier 1 first (zero login, immediate value).
Add Tier 2 (read-only, can't hurt anything) when you want auto-import. Only add
Tier 3 — and only against a dedicated calendar — once you've lived with the
read-only version and trust it. You can stop at any rung.

**Decision (chosen):** Go with **Tier 3 OAuth read/write to a dedicated
calendar**. Because every credential lives only in your own browser and there's
no server in the middle, the exposure surface is small and contained — and Tier
3 is also exactly the bridge the Skylight needs (see §12). Tiers 0/1 still ship
first as the offline baseline, then Tier 3.

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
- **If even those edges annoy you, the fix is a tiny serverless token-broker**
  (e.g., a free Cloudflare Worker) that holds the client secret + a long-lived
  **refresh token** and hands the app fresh access tokens on demand. That makes
  auth durable across restarts, immune to Safari ITP, and is actually *more*
  secure (the secret and refresh token never touch the browser). It's the one
  place a sliver of backend earns its keep — optional, addable later without
  changing the app's data model.
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

**Calendar Mode toggle:** a new setting `calendarMode` (bool, default `false`).
Setting it `true` is sticky. When on, `body` gets a `data-mode="calendar"`
attribute (alongside the existing `data-view`), which CSS uses to reskin:
event lanes appear on day cards, the day-tap gesture switches to inline expand,
the full-screen editor shows event controls, etc. Timecard-only chrome (OT pill,
80-hr stat strip) can be de-emphasized but stays reachable, since the days are
the same days.

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

## 6. Color coding ("very extremely easily")

- A fixed **palette of ~8 named tokens** (blue, green, red, orange, purple,
  teal, pink, gray) defined as CSS custom properties, with light/dark variants —
  mirroring how `--ot`/`--holiday` already work.
- The editor shows the palette as a **row of tappable swatches** — one tap sets
  the color. No nested menus.
- **Automatic memory:** `eventHistory.defaultColor` means once you color "Soccer"
  green, re-adding "Soccer" is green by default. That's the "automatic, not
  manual" feel applied to color.
- Optional later: map Google's `colorId` ↔ our palette so colors survive sync.

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

**Default scale + linear mode.** Set the default window to 7:30 AM–10:00 PM and,
in calendar mode, switch the timeline to a **linear** minute scale (the current
non-linear core compression is timecard-specific). The bar engine already
positions children by `dataset.leftMin`/`widthMin`, so events drop in with no
structural rewrite.

**Multi-color event lanes.** Today a day card draws work/leave/lunch bars. Add a
small stack of **event lanes** beneath (or above) them — one thin colored line
per event, in its palette color, positioned by start/end minute. Overlapping
events get packed into separate lanes so nothing hides behind anything. All-day
events render as a full-width pill.

**Tap a day → inline expand.** In calendar mode, tapping a day card toggles an
**accordion** under it listing that day's events (color dot · name · time),
plus work/leave summary. (Currently a tap opens the full editor — that moves
behind an explicit **Edit** button.)

**Edit → full-screen editor.** The existing Day Editor view becomes the
full-screen day editor: add / edit / delete events, set recurrence, pick color,
plus the existing timecard entry + leave controls (shown contextually). The
add/edit modal grows: title field (with the type-ahead list), all-day toggle,
start/end quarter-hour pickers (reuse the existing `<select>` pickers — they
exist specifically to dodge iOS `<input type=time>` rounding), color swatches,
recurrence picker, notes.

**No regressions.** Timecard mode (calendar mode off) looks and behaves exactly
as it does today.

---

## 10. Phased roadmap (suggested PR sequence)

Each phase is independently shippable and reviewable.

- **Phase 0 — Data foundations.** Dexie v2 (`events`, `eventHistory`),
  `calendar.js` skeleton, color palette CSS vars, `calendarMode` setting +
  sticky toggle in Settings. No visible UI yet beyond the toggle.
- **Phase 1 — Calendar UI core.** Calendar-mode reskin; 7:30–22:00 linear scale;
  event color lanes on day cards; tap-to-expand day accordion; full-screen day
  editor with event add/edit/delete + color swatches. (Single events only.)
- **Phase 2 — Recurrence, memory, backlog.** RRULE engine + occurrence
  expansion + exceptions; `eventHistory` type-ahead (prefix, newest-first,
  deletable, remembered color); "need to schedule" list.
- **Phase 3 — `.ics` + CSV (no login).** RFC-5545 `.ics` export for a pay period
  / date range incl. recurrence; `.ics` import; `EVENTS`/`EVENT_HISTORY` CSV
  sections.
- **Phase 4 — Google sync, opt-in & tiered.** Tier 2 read-only import first;
  then Tier 3 write to a dedicated app-owned calendar; connect/disconnect +
  revoke UI; conflict handling (last-write-wins keyed on `updatedAt`, never
  deleting Google events the app didn't create).

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

- **Per-person color-coded sub-calendars.** Skylight color-codes by
  person/calendar. Map the app's color tokens (§6) to per-member Google
  sub-calendars so colors survive onto the wall automatically.
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

## 13. Open questions to settle before Phase 1

1. **Month/week view now or later?** Pay-period-only to start, or add a month
   grid in Phase 1? (Affects the UI scope.)
2. **Calendar-mode home screen.** When calendar mode is on, should the app open
   on the current *week*, or jump to a *month* overview?
3. **Color palette size** — is ~8 colors enough, or do you want a freeform color
   picker too?
4. **Event lanes vs. the work bar.** On a day you both worked and have events,
   how much vertical space should the card give events before it scrolls?
5. **Which Google account / calendar** would Tier 3 write to — a brand-new
   dedicated calendar (recommended) or an existing one?
6. **Token-broker now or later?** Ship with browser-only silent refresh first
   and add the serverless broker only if Safari/iOS re-prompts become annoying,
   or build the broker up front for rock-solid auth? (See §1.)
7. **Per-person calendars** — how many family members map to Skylight colors, so
   the sub-calendar layout matches the wall?

