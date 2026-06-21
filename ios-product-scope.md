# iOS Product Scope — now vs. deferred

Purpose: decide what to **finish now** vs. **defer**, in service of one stated
goal:

> A **focused, sellable, super-intuitive iOS timecard app** with native
> widgets and notifications.

This is a planning/strategy doc. The behavioral source of truth stays
`REQUIREMENTS.md` + `CLAUDE.md`. The companion research brief is
`research/deep-research-prompt.md`.

---

## The strategic crux: FOCUS

The codebase has grown into **three different products sharing one shell**:

1. **Timecard** — the work-hours record. Pay-period math, OT (both modes),
   holidays, default schedule, metrics, CSV, validation deadline. **Mature,
   stable, "byte-for-byte protected," zero network.** This is the calm,
   shareable work view.
2. **Calendar mode** — a personal time-management layer (events, recurrence,
   drag, backlog, events `.ics`). Opt-in, gated. Mostly built.
3. **Discover / Invites + LLM connectors** — pull local events from sources,
   curate with a BYO LLM, surface them as "invites." Newest, **partly built**
   (engine/proxy/data/Invites-lane/add-source-form done; LLM layer pending).
   Explicitly Chicago-specific and single-user ("the user is both the ad
   network and the audience").

**The sellable product is #1 — the focused timecard.** #2 and #3 are a
*personal* exploration the repo itself already calls "really a second app."
They are powerful but they are **sprawl** relative to "focused and sellable":
single-user, location-specific, and dependent on a CORS proxy + the user's own
LLM key. Trying to sell all three at once produces an unfocused app that's hard
to position, price, or support.

**Recommendation:** treat the timecard as the product to ship and sell. Keep
calendar/Discover/LLM as a separate personal track (or a much later, clearly
separate offering). Every "now vs. defer" call below follows from that.

> The biggest open question — *what exactly is the sellable timecard, and for
> whom* (the underserved **federal-maxiflex / flexible-schedule** niche vs. a
> general project-time tracker) — is the subject of `research/deep-research-prompt.md`.
> Resolve that before committing the iOS feature set.

---

## NOW — finish in the PWA (the cheap medium)

Do these here, where iteration is free (no Mac, no build, push-to-deploy),
because they're **logic / spec / UX decisions that the native app will port**.
Settling them now means porting a *frozen* target once instead of re-porting a
moving one.

- **Lock the timecard spec & data model.** The core is already stable —
  formally declare a "logic freeze" for: pay-period math, OT (both modes),
  holidays, lunch/rounding/forgotten-clockout, default schedule, validation
  deadline, CSV format. These are what port to Swift (the `Maxiflex` domain
  layer already mirrors them).
- **Decide Projects (planned, not built).** Per-entry project/accounting-code
  tagging (`REQUIREMENTS.md` → "Projects"). This is plausibly the single most
  *sellable* timecard feature (clients/projects + reports is what paid
  competitors charge for). **Decision needed:** is it in the focused MVP? If
  yes, build it in the PWA now to validate the UX cheaply before the Swift
  rebuild. (Let the research inform this.)
- **Finalize the design system & UX rules** (they're conceptual, so they carry
  to SwiftUI): semantic color tokens by meaning, the one-tap/big-button/
  quarter-hour/undo-not-confirm principles, the timeline interaction model.
- **(Optional) Validate the niche** — the PWA is still a handy artifact to test
  whether the focused timecard resonates, but as of the 2026-06-21 decision this
  is **no longer a gate on the native build.** The app gets built regardless;
  any r/fednews/waitlist validation runs *in parallel* as distribution work.

**Do NOT** pour effort into PWA *visual polish* — the UI is rebuilt from scratch
in SwiftUI, so pixel-polishing the web UI is throwaway. Lock *behavior*, not
*chrome*.

---

## NATIVE-ONLY — deferred to the iOS build by necessity

These are the *reasons to go native* and cannot be done (well) in the PWA. They
belong in the Swift app, not here:

- **Home/Lock-Screen widgets** (WidgetKit) — hours-this-period, days-left, pace.
- **Live Activity / Dynamic Island** — a running clock session while clocked in
  (a standout, very "intuitive" timecard moment).
- **Reliable local notifications** — "you've been clocked in 9h, forgot to clock
  out?", "pay period ends tomorrow, you're X short", validation-deadline nudge.
- **Durable storage** (SwiftData) — fixes the PWA's IndexedDB eviction risk.
- **Siri / App Intents** — "Hey Siri, clock me in"; Shortcuts automations.
- **Haptics, native pickers, share sheet, Apple Watch** (later).
- **Monetization** — App Store, pricing/IAP/subscription, paywall. (Research
  brief covers the model.)

The Swift domain port + CI/CD pipeline for this already exist, **parked**, in the
separate `Maxiflex` project (see "Native port status" below).

---

## DEFER / EXCLUDE from the focused sellable product

- **Calendar mode** (events, recurrence, drag, backlog). Keep it in the PWA for
  personal use; **exclude from the sellable timecard MVP.** It's the "personal"
  layer, not the work record, and it doubles the surface area to design, build
  natively, and support. Revisit only as a deliberate, separate later product.
- **Discover / Invites + LLM connectors** (the whole v23–v25 track + the pending
  LLM layer). This is a **personal, Chicago-specific, proxy-and-key-dependent
  experiment.** It is the opposite of "focused and sellable." Keep iterating it
  in the PWA if it's fun, but it should **not** gate, bloat, or define the iOS
  product. (If it ever becomes a product, it's its own app.)
- **Theme menu** — nice-to-have; tokens are theme-ready but no picker. Defer.
- **Google sync** (long-deferred already) — out of scope for the timecard.

---

## Design & UX rules to CARRY INTO iOS (preserve these)

From `maxiflex-tracker-spec.md` and `REQUIREMENTS.md` — these are the "feel"
rules that made the app good and must survive the rebuild:

- **One-tap primary actions** (clock in/out, leave ±) — never more than a tap away.
- **Big, thumb-sized buttons; used in a rush.**
- **Quarter-hour input only** — never a 60-minute wheel (native picker must
  enforce 15-min granularity; this is why the PWA avoids `<input type=time>`).
- **No confirmation modals for routine actions — undo toasts instead.**
- **Glanceable hero number** (hours left) + small supporting stats, not clutter.
- **Lands on the pay-period view**, compact enough that the work week fits one
  screen; weekends hidden behind reveals.
- **Semantic color system**: calm blue = regular work, **ember/gold = overtime**
  (deliberately flashier), teal = leave, pink = holiday. Dark mode native.
- **Local-first / private / no account** — a genuine selling point, not just an
  implementation detail.

---

## Native port status (parked, intact)

The Swift rewrite lives in the separate `..\Scripts\Maxiflex` project (its own
git repo). Already done and **parked pending the logic freeze above**: the pure
domain layer ported from `time.js` (+ tests) and a full GitHub Actions →
Fastlane → TestFlight pipeline. Resume porting once the timecard spec + the
Projects decision are locked. (`calendar.js` was intentionally **not** ported —
it's the WIP/excluded layer.)

---

## Decisions (settled — no longer gating the iOS build)

As of **2026-06-21** the build is **greenlit unconditionally** — none of the
below blocks starting the native app (decision recorded in `CLAUDE.md` and
`timecard-mvp-decision.md`):

1. **Positioning:** **federal-maxiflex / flexible-schedule niche-first** (general
   project-time tracker is the later expansion). → `timecard-mvp-decision.md`.
2. **Projects in the MVP?** **OUT** of the niche MVP; parked as the expansion
   lever. → `timecard-mvp-decision.md` §4.
3. **Monetization:** one-time **$9.99–$14.99** Pro unlock, **shipped as a bonus,
   not the driver** — the app exists whether or not anyone pays. No subscription.
4. **Confirmed:** calendar/Discover/LLM stay **OUT** of the sellable product.
5. **WTP validation gate: dropped.** Don't wait on r/fednews/waitlist demand
   proof before building — it's optional parallel distribution work.
