# Timecard MVP — decision brief (research-backed)

Settles the three gating questions from `ios-product-scope.md` ("Open decisions
for you"): **positioning, the Projects in/out call, and monetization.** Backed by
a 5-angle deep-research pass (competition, federal niche, UX + native iOS, indie
monetization, willingness-to-pay/sync/ASO/compliance) run 2026-06-20. Confidence
flags: [H] high, [M] medium, [L] low/inferred. This is a strategy doc; behavioral
source of truth stays `REQUIREMENTS.md` + `CLAUDE.md`.

---

## TL;DR — the calls

1. **Positioning: niche-first — the federal maxiflex / AWS timecard.** Wedge there
   (near-zero competition, motivated buyers, a moat generic apps can't copy), keep
   a general-tracker expansion in your back pocket. [H on the gap, M on the size]
2. **Projects: OUT of the niche MVP.** Per-entry project/accounting-code tagging is
   a *general-tracker* feature; the niche moat is the maxiflex math, not tags.
   Keep the `REQUIREMENTS.md` design parked as the lever for the later
   general-market expansion. [H]
3. **Monetization: one-time purchase (lifetime unlock), ~$9.99–$14.99**, honest and
   visible. The category's loudest complaint is subscription resentment — a
   one-time model is itself a *marketed* differentiator. Small Business Program →
   15% from day one. [H]
4. **~~Validate demand BEFORE the heavy native build.~~ SUPERSEDED — owner
   decision 2026-06-21: BUILD NOW, regardless.** The one unproven assumption is
   still willingness-to-pay (the federal workforce is shrinking under 2025–26
   RIFs), but the owner is building this for its own sake and has chosen **not to
   gate the native build on measured demand.** Payment is a **bonus**, not the
   reason to build. The landing-page waitlist + r/fednews problem-probe remain a
   cheap, *optional* distribution experiment to run **in parallel** — never a
   prerequisite. The analysis below is kept as honest expectation-setting (revenue
   is modest upside, not a livelihood), not as a blocker.

---

## 1. Positioning — niche-first, recommended

**The federal/maxiflex niche is genuinely unserved on iOS.** Repeated App Store +
web searches found **no consumer-facing native app** purpose-built for the 80-hrs/
14-day maxiflex schedule, credit hours, comp time, or federal pay-period math. The
de-facto competitor is **the agency web portal (webTA / GovTA / GSA HR Links) plus
a personal Excel spreadsheet** — reporting tools, not personal planning tools. You
are beating a spreadsheet, not HoursTracker. [M-H: a low-ASO app can't be 100%
ruled out; the one candidate to investigate directly is "G2Flex" id6467872117,
unconfirmed.]
- OPM maxiflex rules: <https://www.opm.gov/policy-data-oversight/pay-leave/work-schedules/fact-sheets/maxiflex-work-schedules/>
- Credit-hours caps (24 carryover, 15-min increments, 80-hr floor): <https://www.opm.gov/policy-data-oversight/pay-leave/work-schedules/fact-sheets/credit-hours-under-a-flexible-work-schedule/>

**Why the niche beats "general focused tracker":**
- The general market is saturated and trust-poisoned (see §2). The niche has a
  precise, rules-driven JTBD a focused app does *well* and a spreadsheet does
  *poorly*: self-track toward exactly 80, don't forfeit credit hours past the
  24-hr cap, reconcile 15-min increments, holiday/OT math. [H]
- "Credit hours vs. comp time" is documented as "the most misunderstood concept in
  the federal system" — even supervisors get it wrong. That confusion *is* the
  product wedge. <https://www.nationalsecuritylawfirm.com/time-and-attendance-misconduct-non-awol-the-complete-2025-guide-for-federal-employees/> [M]

**The single riskiest assumption (NOT a blocker — see TL;DR #4):** that these
users will *pay*. The owner has chosen to build regardless and treat revenue as a
bonus, so this is expectation-setting, not a go/no-go gate.
Demand is *inferred* from the rule structure (forfeitable credit hours, GSA even
ships a "comp-time cap calculator"), not *measured* — no survey/pre-order/review
evidence surfaced, and OPM publishes no AWS headcount. The serviceable market is a
defensible "few hundred thousand to ~1M" feds touching a flexible/credit-hour/
comp-time arrangement (synthesis, not a cited figure), but the workforce is
**shrinking** under 2025–26 RIFs, which dampens both size and discretionary spend.
[L on size, H that this is the assumption to validate]
- Federal workforce ~2.29M, declining: <https://ourpublicservice.org/blog/new-fedscope-data-2025-opm-federal-workforce-changes-doge-trump-administration/>

**Wedge-then-expand:** ship the maxiflex niche app; the general-tracker market (and
Projects, multi-job) is the *expansion*, not the entry. Don't fight Toggl/Clockify
for the broad market on day one.

---

## 2. Competitive teardown

| App | Audience | Price / model | Rating (vol) | Top strength | Top complaint | Gap it leaves |
|---|---|---|---|---|---|---|
| **HoursTracker** | Hourly workers (pay calc) | Freemium→sub; ~$3.99–6.99/mo | 4.8★ (~55k) | Powerful pay/OT/geofence math | Sub shift locks logged data; flaky geofence | No fixed-salary/federal schedule model |
| **Hours** | Freelancers | Was one-time → sub | 4.5★ (~7k) | Beautiful timeline UI | Paywall bricked features; **iOS abandoned (2020)** | Vacated "beautiful + maintained" slot |
| **Timery** | Toggl power-users | Freemium sub; $9.99/yr | 4.8★ (~1.1k) | Best-in-class Shortcuts/widgets/Watch | **Rents on Toggl; needs account + internet** | Standalone, offline-first |
| **Timing** | Mac freelancers | Sub only ~$9–20/mo | 4.8★ (~140 Capterra) | Automatic passive tracking | One-time backlash; **Mac-only** | No iOS; no one-time option |
| **ATracker** | Personal productivity | Freemium + **$4.99 one-time** | 4.7★ (~3.2k) | One-tap switching; liked one-time unlock | Shallow reports | Deep reporting; structured schedules |
| **Tyme** | Apple freelancers | Sub (was one-time) | 4.5★ (~51, low-conf) | Polished native UI | **Forced sub off one-time license** | One-time / no-rent option |
| **Toggl Track** | Solo + teams | Freemium; $9–18/user/mo | 4.7★ Capterra | Most intuitive UI | Paywalled billing; **mobile sync** | Strong native mobile; non-team simplicity |
| **Clockify** | Freelancers + teams | Freemium; $4.99–14.99/user/mo | 4.6★ (~3.7k) | Cheapest tiers | **Mobile weak; free tier gutted (2026)** | Reliable native mobile |
| **Generic "Time Clock"** | Hourly/shift | Weekly "trap" subs / ad-funded | ~4.5★ | Cheap, findable | **Bait-and-switch; data harvesting** | Honest, calm, trust-first app |
| **DOL-Timesheet** | FLSA hourly | Free (gov) | 3.1★ (~50) | Official, free | No holiday/weekend/maxiflex; buggy | **The federal flexible-schedule gap** |
| **Federal / maxiflex** | US feds | — (no consumer iOS app) | — | — | Stuck on webTA/Quicktime + Excel | **THE open niche** |

**Three structural openings:** (1) the federal/maxiflex niche is empty; (2)
**subscription resentment is the loudest cross-market complaint** — apps punished
in reviews for going sub, worst when they *lock users out of data already
entered*; (3) **polished native + offline-first iOS is itself uncontested** (giants
are weak on mobile, Timing is Mac-only, Hours is abandoned, Timery is tethered to
Toggl). Note the **DOL ships its own free timesheet app** but it explicitly does
*not* do holiday/weekend/maxiflex pay (3.1★) — validates the gap and warns: stay
clearly unofficial. <https://apps.apple.com/us/app/dol-timesheet/id433638193>

---

## 3. MVP feature set

**Must-have (the focused core — most already built in the PWA, port to Swift):**
- The maxiflex engine: 80/14 pay-period math, both OT modes, holidays, lunch/
  rounding/forgotten-clockout, default schedule, validation deadline, paydate/YTD.
  This is the moat — freeze the logic (see `ios-product-scope.md`). [H]
- **CSV + PDF export of a pay period** and a **pay-period summary**. These are the
  exact features the market already paywalls; export is the #1 upgrade trigger
  across competitors. <https://apps.apple.com/us/app/atwork-timesheet/id857189697> [H]
- **SwiftData + CloudKit (private DB) backup/sync.** The *only* real local-first
  liability is "I'll lose my data," not "no account." CloudKit fixes it with zero
  backend. **Design the model for its constraints now** (retrofitting is "incredibly
  painful"): no `@Attribute(.unique)`, every property optional/defaulted, all
  relationships optional + unordered, private DB only.
  <https://www.hackingwithswift.com/quick-start/swiftdata/how-to-sync-swiftdata-with-icloud>
  · <https://fatbobman.com/en/snippet/rules-for-adapting-data-models-to-cloudkit/> [H]

**Native features that make the cut (table stakes among the *best*, absent
elsewhere — your differentiation is wiring them to maxiflex-native glances):**
- **WidgetKit** home/lock-screen widget: **hrs/80, pace (ahead/behind), days-left,
  OT $.** No competitor surfaces pay-period metrics in a widget — this is the
  unique glanceable payload. [H opportunity]
- **App Intents** for `ClockIn`/`ClockOut`/`AddLeave` — build once, and Siri,
  Shortcuts, Spotlight, interactive widgets, and Control Center come nearly free.
  <https://developer.apple.com/videos/play/wwdc2024/10210/> [H]
- **Control Center control + Action Button "Clock In/Out"** — a near-empty space in
  the timecard niche; one physical-button press to the core action. [M-H opportunity]
- **State-triggered local notifications** — forgot-to-clock-out fires off *state*
  ("still clocked in past 16h"), not a fixed daily blast; pay-period-ending /
  validation-deadline nudges, few and consequential. [M]

**Later (post-validation):**
- **Live Activity / Dynamic Island** running clock. Wanted, but design around a
  platform gotcha: iOS 18+ throttles Live Activity refresh — use a system-ticked
  `Text(timerInterval:)` activity, verify against current ActivityKit docs before
  relying on a live-ticking display. [M, verify]
- Apple Watch complication (hrs/80 + pace), StandBy.

**Onboarding win you already have:** local/no-auth skips account creation (the
biggest onboarding-friction source). Let the user *clock in before* finishing the
anchor/schedule setup — value first, configuration progressive. [M]

---

## 4. Projects — decision: OUT of the niche MVP

The full Projects design sits ready in `REQUIREMENTS.md` ("Projects — planned").
**Recommendation: do not build it for the federal-niche launch.**
- Multiple-jobs / project-client tags *are* proven paid features — but in the
  **general** tracker market, not the federal niche. The federal buyer's JTBD is
  "hit 80, don't forfeit credit hours," not "bill project X." [H]
- It doubles design/build/support surface against the "focused" hard requirement.
- It's the natural **expansion lever**: when/if you broaden to the general
  project-time market, Projects is the headline feature. Keep the design parked.
- If you instead chose *general* positioning, Projects flips to must-have — build
  it in the PWA first to validate the UX cheaply. (You did not choose that path.)

---

## 5. Monetization

**Model: one-time purchase / lifetime unlock, ~$9.99–$14.99, honest & visible —
shipped as a *bonus*, not the driver** (owner decision 2026-06-21: the app exists
whether or not anyone pays; the unlock is cheap to include and a clean ask).
- The category has *trained users to distrust subscriptions* — "predatory,"
  hidden post-trial charges, and "locked out of data I already entered" recur
  across HoursTracker/Hours/Tyme/Timing reviews. A one-time model is a *marketed*
  wedge (apps like "Time Squared" position explicitly on "no subscription"). [H]
- One-time/lifetime is also a structural rising trend (6.4%→10.3% of monetization
  2023→2025) and matches a "set-and-forget" work-record utility better than a sub.
  <https://adapty.io/state-of-in-app-subscriptions-report/> [M]
- Higher price converts *better*, not worse (9.8% vs 4.3% download-to-paid for
  high- vs low-priced) — don't race to $0.99.
  <https://www.revenuecat.com/state-of-subscription-apps-2025/> [H]
- **Economics:** Small Business Program = **15% commission from day one** (new
  devs auto-qualify; <$1M proceeds). $99/yr developer program. StoreKit 2 alone is
  enough for a single lifetime unlock (RevenueCat only if you want paywall A/B or
  go cross-platform). <https://developer.apple.com/app-store/small-business-program/> [H]
- **Optional later:** a cheap sub *only if* you ship genuinely recurring value
  (cross-device sync as a service) — but the niche resists subs, so lead with the
  one-time unlock. [M]

**Realistic revenue:** a single niche utility is a **hundreds-to-low-thousands of
dollars/year** product (e.g. 1k downloads × 5% × $9.99 × 0.85 ≈ $425/yr; 5k × 6% ×
$12.99 ≈ $3.3k/yr). The binding constraint is **downloads/marketing, not price**.
The niche specificity is simultaneously the moat (motivated buyers) and the ceiling
(small TAM). Set expectations: portfolio piece + modest income, not a livelihood,
unless distribution is actively worked. [H that marketing is the constraint]

---

## 6. Differentiation — value × effort (solo, local-first, SwiftUI/SwiftData)

| Feature | Value | Effort | Verdict |
|---|---|---|---|
| Maxiflex engine (done in PWA) | ★★★★★ | low (port) | **Core moat** |
| CSV/PDF export + period summary | ★★★★★ | low-med | **Must-have (proven WTP)** |
| Pay-period widget (hrs/80, pace, days-left, OT$) | ★★★★★ | med | **Top differentiator** |
| SwiftData+CloudKit backup/sync | ★★★★☆ | med | **Must-have (kills the no-sync objection)** |
| App Intents (clock in/out) | ★★★★☆ | low-med | **High leverage (unlocks Siri/CC/widgets)** |
| Control Center / Action Button clock-in | ★★★★☆ | low | **Cheap, near-empty niche space** |
| State-triggered notifications | ★★★★☆ | med | **Must-have (forgot-to-clock-out)** |
| Live Activity / Dynamic Island | ★★★☆☆ | med-high | Later (refresh-throttle gotcha) |
| Apple Watch complication | ★★★☆☆ | med-high | Later |
| Projects / multi-job tags | ★★☆☆☆ (niche) | high | **Defer (expansion lever)** |
| Geofenced auto clock-in | ★★☆☆☆ | high | Skip (B2B feature; reliability liability) |

---

## 7. Go-to-market — first 100 users

- **(Optional, parallel — NOT a build gate):** stand up a one-page **waitlist** +
  post a problem-probe in **r/fednews** (359k+ members, the dominant fed hub) and
  credit-hours/AWS threads to convert inferred pain → measured demand + WTP. Per
  the 2026-06-21 decision this runs *alongside* the native build, not before it.
  Worth doing for distribution; never a prerequisite. Also investigate the lone
  possible incumbent **G2Flex**.
  <https://www.newsweek.com/reddit-fednews-popularity-donald-trump-federal-workers-2027592> [H this is the cheapest next step]
- **Launch channels:** federal-employee communities first (r/fednews, r/govfire,
  agency/union groups), niche newsletters — **not** Product Hunt (feds don't live
  there; a one-day spike at best). [M, anecdotal]
- **ASO:** **Utilities** category (matches the DOL app precedent). Spend the
  near-zero-competition long-tail — *maxiflex, federal, biweekly, pay period,
  paydate, credit hours, GS, overtime calculator* — in the title/subtitle/keyword
  field. Screenshots: **Value → Flow → Trust**, lead with the 80-hr period at a
  glance, *not* a settings screen. A federal-themed Custom Product Page now ranks
  organically. [M-H]

---

## 8. Risks & compliance

- **Stay clearly unofficial.** No DOL/agency branding or logos; don't imply
  endorsement or "official timekeeping." Executive-branch employees are *prohibited
  from endorsing products* in their official capacity — so no "Agency X uses our
  app" testimonials. Market as a **personal planning/double-check tool** you use
  *before* entering hours into the mandated webTA/GovTA system. [H]
  <https://www.doi.gov/ethics/strengthening-your-ethics-muscle-few-exceptions-endorsements-are-prohibited>
- **Add a disclaimer:** "informational/personal tracking only, not your agency's
  official system of record, accuracy not guaranteed." A personal timecard can
  become *evidence* in a wage/hour dispute (either direction), so don't claim
  payroll/compliance authority. [H]
- **Privacy is a genuine, defensible claim:** local-first/no-account = no server to
  breach, no account to leak. Pair with the "no subscription server, you own your
  data" story. Keeps the compliance surface small (work hours are payroll-type
  records, not regulated sensitive data). [M]

---

## Confidence summary & what to verify next

- **Strong:** the empty niche, the rule structure (the JTBD), subscription
  resentment, native-iOS gap, CloudKit as the sync answer, the marketing
  guardrails.
- **Weak / validate:** AWS *headcount* (OPM publishes none), *intensity* of the
  tracking pain (inferred from rules, not live threads), and **willingness to pay**
  (no direct evidence). The 2025–26 RIF climate is a real headwind.
- **Next action (per the 2026-06-21 decision):** declare the timecard **logic
  freeze** and **resume the parked Swift port now** against the frozen target —
  the native build is greenlit and does **not** wait on demand validation.
  Projects stays parked as the expansion lever.
- **Optional, in parallel:** waitlist + r/fednews problem-probe to measure
  demand/WTP, and investigate G2Flex — useful distribution signal, not a gate.
