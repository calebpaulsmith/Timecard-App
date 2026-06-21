# Timecard (native iOS)

Native SwiftUI rewrite of the Timecard PWA. Tracks a federal maxiflex
biweekly schedule (80 hrs / 14 days). Single-user, fully local.

This is a **monorepo**: the Timecard PWA is at the repo **root** (`../`), this
native app is in `iOS/`. See `../PLATFORM-STRATEGY.md` for the app map. A
clean-room rewrite — **not** a port and **not** a WebView wrapper — that carries
the proven domain logic forward into a tested Swift core. See `CLAUDE.md` for
architecture and the project plan.

## Building (requires a Mac)

iOS apps can only be built and run on **macOS with Xcode**. This repo is authored
to be Windows-friendly (no `.xcodeproj` checked in — it is generated), but the
actual build/run/test must happen on a Mac (physical, or a cloud Mac / GitHub
Actions `macos` runner).

```sh
# one-time
brew install xcodegen

# generate the Xcode project from project.yml
xcodegen generate

# open it
open Timecard.xcodeproj
```

Then pick an iOS 17+ simulator and Run (⌘R), or run the tests (⌘U).

### Run tests from the command line
```sh
xcodebuild test \
  -project Timecard.xcodeproj \
  -scheme Timecard \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Shipping to your iPhone (no Mac needed)

CI/CD is wired up: GitHub Actions builds on macOS runners and ships to
TestFlight. Tests run on every push; builds upload on a `v*` tag or a manual
workflow run. Full one-time setup runbook (Apple Developer account, App Store
Connect API key, secrets) is in [docs/CICD-SETUP.md](docs/CICD-SETUP.md).

## Status

- **Phase 0 — Scaffold:** ✅ project structure, XcodeGen spec, app shell.
- **Phase 1 — Domain port:** 🚧 `time.js` ported to `Domain/` with unit
  tests asserting parity with the PWA. `calendar.js` (recurrence/events ICS)
  still to come.
- Later phases (Store + CSV bridge, Timecard UI, Metrics, Calendar mode, native
  superpowers, widgets) are tracked in `CLAUDE.md` and the plan file.

## Layout

```
iOS/                   # the Timecard iOS app (XcodeGen project root)
  project.yml          # XcodeGen project spec (generates Timecard.xcodeproj)
  App/                 # @main (TimecardApp), routing, FeatureFlags
  Domain/              # pure logic ported from time.js / calendar.js
  Store/               # SwiftData models + repositories (Phase 2)
  Features/            # SwiftUI features (Phase 3+)
  Platform/            # widgets, notifications, EventKit, haptics (later)
  Resources/           # asset catalog
  TimecardTests/       # unit tests (Domain first)
```
