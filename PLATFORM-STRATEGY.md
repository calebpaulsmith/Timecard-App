# PLATFORM-STRATEGY.md — managing the apps in this one repo

> This repo is a **monorepo** that holds **more than one app**. This file is the
> map: what lives where, which app is which, and the rules that keep them from
> stepping on each other. **Read this before making changes — and confirm with
> the user which app(s) a change targets** (see "Working rule" below).

## The apps in this repo

| # | App / edition | Where | Tech | What it is |
|---|---|---|---|---|
| 1 | **Timecard PWA** | repo **root** (`index.html`, `app.js`, `time.js`, `db.js`, `calendar.js`, `connectors.js`, `google.js`, `styles.css`, `sw.js`, …) | vanilla JS PWA | The live web app on GitHub Pages. Also the **cheap prototyping medium** + the **personal playground** (calendar/Discover/LLM/Google sync live here, gated). |
| 2 | **Timecard iOS** | `iOS/` | Swift / SwiftUI / SwiftData | The **sellable native product**. One codebase, **two faces** (below). |

App #2 has **two faces from one codebase** (build configs + a feature flag, NOT
forks):

| Face | Scheme | Config | Includes | Audience |
|---|---|---|---|---|
| **Production (pay)** | `Timecard` | Debug (dev) / **Release (App Store)** | Timecard core + Pro IAP only | Customers |
| **Personal** | `Timecard Personal` | Personal | core + **calendar / life-timecard / tax-from-LES** exploration | You |

> Naming note: the product identity is unified on **"Timecard"** — the Xcode
> target / scheme / module, the on-device display name, the bundle identifier,
> and the reserved App Group use `com.thegrandpipeline.timecard`
> (`group.com.thegrandpipeline.timecard`) — the App ID already registered on the
> Apple Developer account (alongside the owner's other `com.thegrandpipeline.*`
> apps), with a matching "Timecard" record in App Store Connect. "maxiflex" now
> survives only as the federal *schedule* term in the domain logic.

## The mental model (why this stays sane)

```
                 LOGIC-FREEZE.md   (the shared behavioral contract)
                        │
        ┌───────────────┴───────────────────┐
   Timecard PWA (web)                  Timecard iOS (Swift)
   • prototyping + personal web        • the sellable product
   • calendar/Discover/LLM/Google      • ONE codebase, TWO faces via flag:
     gated behind `calendarMode`           ├─ Timecard          → core + Pro (App Store)
                                           └─ Timecard Personal → + calendar/life/tax
```

1. **Two platforms share a SPEC, not code.** JS and Swift can't share source.
   They stay aligned because **core behavior is decided in `LOGIC-FREEZE.md`
   first** (cheap to prototype in the PWA), then ported to Swift. The spec is the
   contract; the PWA's `time.js`/`calendar.js` are the porting oracle.
2. **Variants are FLAGS, not branches or forks.** The personal face is the same
   binary with extra modules switched on by the `PERSONAL` compile flag
   (`iOS/App/FeatureFlags.swift`). A core fix benefits both faces automatically —
   that's what keeps "personal vs production-for-pay" synced. **Never** create a
   long-lived "personal" branch — that's merge hell.
3. **The gating rule (both platforms):** anything outside the sellable timecard
   core sits behind a flag (`FeatureFlags.personalEnabled` on iOS;
   `state.calendarMode` on the PWA), **defaults OFF in production**, and **never
   changes core timecard/pay math.** Build new exploratory features behind their
   flag from day one.
4. **App Store hygiene:** the production build must not contain dormant
   calendar/LLM/Google code (App Store 2.3 + the legal notes in
   `research/RESEARCH-ios-timecard.md`). The `PERSONAL` flag compiles it out of
   Release, which satisfies this.

## Working rule (IMPORTANT — for every change)

Because there are multiple apps here, **before editing, establish and confirm
scope:** *which app(s)/edition(s) does this change touch?*

- **PWA only** (root files) — does not affect iOS.
- **iOS only** (`iOS/`) — does not affect the PWA.
- **Both** — e.g. a behavioral/spec change: update `LOGIC-FREEZE.md`, then both
  implementations.
- **Production vs Personal** (iOS) — is this core (ships to App Store) or
  personal-only (behind `PERSONAL`)?

If it's not explicit from the request, **ask the user which app/edition before
proceeding.** Also still in force: the PWA's **timecard mode stays
network-free / byte-for-byte** (calendar/Google code is gated), and the iOS
**Domain layer is the protected core** (see `iOS/CLAUDE.md`).

## Branching & CI

- **Trunk-based:** `main` always (a) deploys the PWA via GitHub Pages and (b)
  builds the iOS app. Short-lived feature branches → PR → merge.
- **GitHub Pages** serves the PWA from the repo root and **ignores `iOS/`**, so
  the web app keeps deploying unaffected.
- **CI lives at the repo root** (`.github/workflows/`, GitHub only runs workflows
  from there):
  - `ios-ci.yml` — domain unit tests (the `Timecard` scheme) on macOS; runs only
    when `iOS/**` changes (PWA-only changes don't spin a macOS runner).
  - `ios-testflight.yml` — Release archive → TestFlight; manual or on a `v*` tag.
  - `ios-bootstrap-signing.yml` — one-time signing setup. Needs secrets (see
    `iOS/docs/CICD-SETUP.md`).
  - All iOS workflows `cd` into `iOS/` via `defaults.run.working-directory`.

## iOS implementation path (the plan)

- **Phase 0 — gates:** ✅ logic freeze (`LOGIC-FREEZE.md`). ✅ **WTP validation
  gate removed (decision 2026-06-21) — build proceeds unconditionally; payment is
  a bonus, not a prerequisite** (see `CLAUDE.md` → "Decisions from the 2026-06
  research"). r/fednews validation/waitlist is now optional parallel distribution
  work. Projects stays the Pro anchor (parked as the expansion lever).
- **Phase 1 — core (free tier):** finish the Swift domain port → SwiftData store
  + **iCloud/CloudKit sync** + **CSV import** (PWA→native migration) → SwiftUI UI
  (period carousel, day editor, clock in/out, settings, schedule).
- **Phase 2 — native superpowers:** WidgetKit (pay-period widget), Live Activity
  / Dynamic Island (running clock), local notifications (incl. validation-deadline).
- **Phase 3 — Pro + paywall:** StoreKit 2, one-time **$9.99** unlock,
  **Projects/accounting codes + reports/CSV-PDF export** (the Pro anchor).
- **Phase 4 — calendar (Personal face / Pro bonus, gated):** EventKit sync; built
  behind `PERSONAL`, shipped last.
- **Phase 5 — ship:** TestFlight → App Store via the CI pipeline.

The research behind these calls (positioning, price, native bets, legal
guardrails, the open WTP question) is in `research/RESEARCH-ios-timecard.md`.
The federal-niche product calls + creative-latitude policy are in `CLAUDE.md`.
