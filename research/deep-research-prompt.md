# Deep research prompt — a focused, sellable iOS timecard app

Paste the brief below into a deep-research tool (or run the `deep-research`
skill with it). It is written to be self-contained.

---

## CONTEXT (for the researcher)

I'm a solo indie developer. I have a working, polished **timecard PWA** that
tracks a **federal "maxiflex" biweekly schedule** (80 hours over 14 days) — it
handles clock in/out with quarter-hour rounding, auto lunch deduction, overtime
(two modes), federal holidays, a customizable default schedule, pay-period
naming/paydate/YTD math, metrics/charts, and CSV backup. It is **local-first,
private, no account, no backend**. I'm rebuilding it as a **native iOS app**
(SwiftUI/SwiftData) and I want to **sell it**.

My goal: the **best, most focused, most intuitive iOS timecard app** — leaning
on native **widgets, Live Activities, and notifications** — that a real person
will pay for. I need to decide *positioning, MVP feature set, differentiation,
and monetization* grounded in evidence, not vibes.

## THE CORE QUESTIONS

1. **Market & competition.** Map the current (2026) iOS time-tracking / timecard
   landscape. Profile the main competitors (e.g. HoursTracker, Hours, Timery,
   Timing, ATracker, Tyme, Toggl Track, Clockify, Time Clock / work-hour
   trackers, and any maxiflex/federal-specific tools). For each: target user,
   pricing/monetization model, App Store rating & rough review volume, standout
   strengths, and the **most common complaints** (mine App Store reviews and
   forums). Where are the real gaps a focused new entrant could win?

2. **Niche vs. general positioning.** Evaluate two directions and recommend one
   (or a wedge-then-expand path):
   - **(a) The underserved niche:** a timecard built specifically for **federal
     employees on maxiflex / flexible / compressed schedules** (and similar:
     alt-work-schedule, 9/80, comp-time, credit-hours users). How many such
     users exist? Where do they congregate (subreddits, Facebook groups, forums,
     federal-employee communities)? What do they use today and hate? Would they
     pay? Are there compliance/timekeeping-system specifics (e.g. WebTA, GSA,
     OPM rules) worth knowing? Any competitors already serving them?
   - **(b) The general focused tracker:** a simpler, more intuitive
     project/shift time tracker for the broader market. Bigger TAM, more
     competition — is there room for a focused, beautifully-native entrant?
   Give a clear recommendation with reasoning and the riskiest assumption in it.

3. **What makes a time tracker feel "super intuitive."** Synthesize UX/UI best
   practices specifically for time tracking: friction-minimizing clock in/out,
   glanceability, editing past entries, onboarding, the "I forgot to clock out"
   problem, multiple jobs/projects, and Apple Human Interface Guidelines
   patterns that fit. Cite concrete examples of apps doing this well/badly.

4. **Native iOS capabilities as differentiators.** Which Apple platform features
   most improve a timecard, and which competitors exploit them?
   - **WidgetKit** home/lock-screen widgets (hours this period, pace, days left).
   - **Live Activities / Dynamic Island** for a running clock session.
   - **App Intents / Siri / Shortcuts** ("clock me in"), Control Center controls,
     Action Button, StandBy, Apple Watch app/complication, Focus filters.
   - **Local notifications** done tastefully (forgot-to-clock-out, pay-period
     ending, validation-deadline). What's the state of the art vs. the gap?

5. **Monetization (be specific and realistic).** For a **solo indie iOS utility**
   in 2026: one-time purchase vs. subscription vs. freemium-with-IAP vs.
   paid-up-front. What actually converts for utility/productivity apps at this
   scale? Typical price points and trial structures. Tooling (StoreKit 2,
   RevenueCat) and App Store economics (commission, Small Business Program).
   Give a **realistic revenue range** for a focused indie timecard and what
   drives it. Recommend a model + price for each positioning in Q2.

6. **Feature differentiation & willingness to pay.** Which features do users
   actually pay for in this category (reports/CSV-PDF export, payroll/period
   summaries, multiple jobs, project/client tags, overtime rules, geofenced or
   automatic clock-in, rounding rules, invoicing, backups/sync)? Rank them by
   (value to user) × (effort to build), for my local-first, no-backend stance.
   Is "local-first / private / no account" a sellable advantage or a liability
   (no sync) — and how do successful private apps handle backup/sync without a
   backend (iCloud/CloudKit)?

7. **Launch & App Store optimization.** Category choice, keyword/ASO strategy
   for this niche, screenshot/preview best practices, and realistic **first-100-
   users** channels for an indie (the niche communities from Q2, Product Hunt,
   Reddit, content, etc.). What does a credible indie launch look like in 2026?

8. **Risks & compliance.** Accuracy/trust expectations if people lean on it for
   payroll; privacy positioning; anything legal/marketing-sensitive about
   targeting federal employees or implying official timekeeping compliance.

## WHAT I WANT BACK (deliverables)

- A **competitive teardown table** (app · audience · price/model · rating ·
  top strength · top complaint · gap).
- A **clear positioning recommendation** (niche vs. general) with the reasoning
  and the single riskiest assumption to test next.
- A **recommended MVP feature set** (must-have vs. later), explicitly noting
  which native features (widget / Live Activity / notifications / Watch / Siri)
  make the cut and why.
- A **monetization recommendation** — model + price + trial — with a realistic
  revenue range and the evidence behind it.
- A **prioritized differentiation list** (value × effort) tuned to a solo,
  local-first, SwiftUI/SwiftData build.
- A short **go-to-market / first-100-users plan**.
- **Cite sources** for every non-obvious claim (App Store listings, review
  excerpts, pricing pages, dev/indie reports, Apple docs). Flag low-confidence
  or dated findings.

## CONSTRAINTS / ASSUMPTIONS

- Solo developer, SwiftUI + SwiftData, iOS 17+, no backend by default
  (iCloud/CloudKit acceptable if justified). Windows dev machine shipping via
  GitHub Actions → TestFlight (Mac-free).
- "Focused" is a hard requirement: I will cut scope to win one user type well.
  Do not recommend a sprawling all-in-one.
- Out of scope for THIS product (don't include): the personal "discover local
  events / LLM-curated invites" calendar features — that's a separate experiment.
