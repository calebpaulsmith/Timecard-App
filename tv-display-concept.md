# TV Home Dashboard — Concept

A glanceable, zero-interaction **morning-briefing dashboard on the living-room
(or bedroom) TV**: it turns on when you walk in and turn the lights on, and
shows today's calendar, the to-dos due this week, and the grocery list. The
value is *ambient and effortless* — you don't open an app, the info is just
there on the wall.

This is a **separate personal-track product**, not part of the sellable iOS
timecard. It shares *data* with the calendar app (via Google), not code. See
`CLAUDE.md` for how the personal track is fenced off from the timecard MVP.

## JTBD

> "When I start my day, I want the things I need to act on — what's on my
> calendar, what I have to do this week, and what we need from the store — to be
> *already on the wall*, without me reaching for a phone or opening anything."

The mental model is a **fridge whiteboard that updates itself**: passive,
always-current, no interaction required. Reading-only on the TV — you manage the
underlying lists elsewhere (your phone / the calendar app / Google directly).

## Platform decision (DECIDED)

**Android TV / Google TV box + smart plug**, dashboard rendered as a **web view**.

Picked over Apple TV and Raspberry Pi because it has the best magic-to-effort
ratio: native Google, auto-launch on boot, and **web-code reuse** (no native
rewrite). Comparison that drove the call:

| Platform | Auto-show MY app? | Wake method | UI | Google |
| --- | --- | --- | --- | --- |
| **Android/Google TV box** (chosen) | **Yes** — `BOOT_COMPLETED` auto-launch + foreground | smart plug boots it; app sends CEC | **web view (reuse code)** | native |
| Apple TV | No — relies on "Return to Home: Never" trick | HomeKit powers it on | native SwiftUI rewrite | device-flow OAuth |
| Raspberry Pi | Yes — kiosk browser | plug/cron boots it | web page (full reuse) | plain HTTP |
| Smart-TV built-in (Tizen/webOS) | **No** — locked down | — | — | — |

Smart-TV native apps (Samsung Tizen, LG webOS, generic "smart TV" apps) are a
dead end: their background/auto-launch is locked down, so a custom app can't
self-wake into the foreground. Excluded.

## The wake mechanism

The "turns on when the lights go on" magic is a **smart plug + a boot-on-power
device**:

1. A smart plug (HomeKit / Home Assistant / the box's own ecosystem) is wired to
   the TV box's power.
2. **When the living-room lights turn on, between set hours (e.g. 6–9am), the
   plug turns on.** (Bedroom = a second automation on a second plug/box, or the
   same box if co-located.)
3. The Android/Google TV box **boots automatically when power is restored** (most
   cheap boxes and Fire TV sticks do).
4. On boot, the app launches itself via Android's `BOOT_COMPLETED` broadcast and
   takes the foreground.
5. The app sends an **HDMI-CEC** "power on + active source" so the TV powers on
   and switches to the box's input.
6. Off side: the lights-off automation (or a time condition) cuts the plug. The
   app can send a CEC standby first if a graceful path is wanted.

### Costs / caveats of the plug approach
- **Boot delay:** ~20–40s between power-on and the dashboard appearing. Acceptable
  for a wall display; not instant.
- **Boot-on-power is device-dependent** — verify the specific box boots (rather
  than sitting in standby) when power is restored *before* committing to it. This
  is the #1 thing to test on real hardware.
- **Don't** pair a plug with an Apple TV or a smart TV — those go to standby, not
  a full boot, so power-restore won't land you in the app.
- Keep the screen awake while shown (`FLAG_KEEP_SCREEN_ON` / disable screensaver)
  so the dashboard doesn't dim out.

## Google backend

The TV reads everything directly from Google, which is what makes the dashboard
**fully decoupled** from the calendar app — they meet only at the Google account.

- **Auth:** standard Google OAuth. On Android TV, Google sign-in is native; the
  device/limited-input (TV) flow is the fallback. **Read-only scopes only** — the
  TV never writes.
- **Calendar:** Google Calendar API (read-only) → today's agenda + a week strip.
- **To-dos AND groceries:** **Google Tasks API** (read-only), using two task
  lists ("To-dos" and "Groceries"). *Not Google Keep* — Keep has no official
  public API.
- Everything is display-only, so the auth surface stays minimal.

### Decoupling = ship the TV app standalone
Because the TV only *reads* Google:
- You do **not** need the calendar app's deferred Google *write*-sync built first.
- For now, manage events/to-dos/groceries directly in Google (Calendar app on the
  phone, Google Tasks). The TV reflects them.
- Later, the PWA's Phase-4 Google sync can *write* into the same account; the TV
  picks it up for free. No coupling either way.

## Data model (on the TV)

The TV app is essentially **stateless** beyond auth tokens and a cache:
- OAuth tokens (refresh token in secure storage).
- A short-lived cache of the last good Calendar + Tasks fetch (so a flaky network
  on boot still shows *something* immediately, then refreshes).
- No local database of truth — Google is the source.

Groceries map to a Google Tasks list; "to-dos due this week" = Tasks with a due
date in the current week (plus, optionally, calendar app backlog items once the
PWA writes them to Tasks).

## UI

- Big type, dark background, high contrast — readable across the room.
- Sections: **Today's agenda** + a **week strip**, **To-dos due this week**,
  **Grocery list**. (Weather/photos deferred.)
- **Auto-refresh** every few minutes; keep-screen-on; no interactive controls
  (it's a display, not an app you navigate).
- Optional: a small "last updated" timestamp and an unobtrusive auth-needed state
  if the token expires.

## MVP scope

**In:**
1. Android/Google TV app (web view shell) that **auto-launches on boot** and
   sends **CEC power-on + active-source**.
2. Google OAuth (read-only) + **Calendar** and **Tasks** reads.
3. Dashboard UI: today's agenda + week strip, to-dos due this week, grocery list;
   auto-refresh; keep-screen-on; offline-cache last fetch.
4. The household wiring: smart plug + lights automation (6–9am window),
   documented as a setup contract.

**Deferred:**
- Weather, photos/ambient background, multi-person color lanes.
- Any editing *from* the TV (stays read-only).
- The PWA → Google *write* sync (TV works without it).
- Bedroom as a second unit (same design, second plug/box).
- Graceful CEC standby on lights-off (vs. just cutting the plug).

## Open questions / riskiest assumptions

1. **Does the chosen box actually boot-on-power-restore?** Test on real hardware
   before anything else — the whole wake mechanism depends on it.
2. **Is the boot delay (~20–40s) acceptable**, or do we want a keep-it-on +
   CEC-only path (box always powered, plug stays on, app just CEC-wakes the TV)?
   The always-powered + CEC route avoids the delay and SD-card wear at the cost of
   the box drawing standby power.
3. **One box, two rooms?** Living room and bedroom likely want separate units.
4. **Token longevity** — confirm the Google refresh token survives long enough on
   a device that power-cycles daily; re-auth UX on a TV is painful, so this needs
   to be solid.
5. **Groceries source** — Google Tasks list is the plan; confirm that's where the
   grocery list will actually live (vs. Keep/another app you'd have to migrate).
