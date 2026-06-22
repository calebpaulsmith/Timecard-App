# Release setup — GitHub Actions → TestFlight (dev quickstart)

**No Mac and no Xcode required** — GitHub's macOS runners build, sign, and upload
the app entirely in CI. All you do is click in a browser and run `gh`/workflow
commands. The long, explain-every-click runbook is [`CICD-SETUP.md`](CICD-SETUP.md).

> **One hard requirement: the paid Apple Developer Program ($99/yr).** TestFlight
> is free to *use*, but **uploading builds to it requires the paid program** — a
> free Apple account cannot create an App Store Connect API key, a distribution
> certificate, or push to TestFlight at all (a free account only allows 7-day
> on-device installs *from Xcode*, which doesn't apply here). Enroll at
> <https://developer.apple.com/programs/enroll/> if you haven't. That $99/yr is
> the only thing you must pay for; everything else below is free.

The pipeline is already written:
- `.github/workflows/ios-ci.yml` — tests on every `iOS/**` push/PR (no secrets). **Already green.**
- `.github/workflows/ios-bootstrap-signing.yml` — run **once**, creates + stores the signing cert/profile via `fastlane match`.
- `.github/workflows/ios-testflight.yml` — build Release + upload, on a `v*` tag or manual dispatch.

Bundle id is **`com.thegrandpipeline.timecard`** (matches `project.yml` + `fastlane/*`).

---

## 1. Apple-side, one time (web)

1. **App ID** — Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App →
   Explicit bundle id **`com.thegrandpipeline.timecard`**. No extra capabilities yet (App Groups land with widgets).
2. **App Store Connect record** — Apps → **+** → New App → iOS, bundle id `com.thegrandpipeline.timecard`,
   a store-unique name, any SKU. (No listing details needed for TestFlight.) *Required before the first
   upload — `pilot` needs the app to exist.*
3. **App Store Connect API key** — Users and Access → **Integrations** → App Store Connect API → **Team Keys** →
   Generate, role **App Manager**. Download the **`.p8` (once only)**; note the **Key ID** and **Issuer ID**.
4. **Team ID** — developer.apple.com/account → Membership → **Team ID** (10 chars).

## 2. Certs repo (web)

Create an empty **private** repo for `fastlane match`, e.g. `timecard-certificates`.
Invent a strong **match passphrase** (it encrypts the certs — store it in your password manager).

---

## 3. The seven secrets

Values:

| Secret | Where it comes from |
| --- | --- |
| `ASC_KEY_ID` | the API key's Key ID (step 1.3) |
| `ASC_ISSUER_ID` | Issuer ID, top of the Keys page (step 1.3) |
| `ASC_KEY_CONTENT` | **base64** of the `.p8` |
| `DEVELOPER_TEAM_ID` | Team ID (step 1.4) |
| `MATCH_GIT_URL` | HTTPS URL of the certs repo (`https://github.com/calebpaulsmith/timecard-certificates.git`) |
| `MATCH_PASSWORD` | the match passphrase you invented |
| `MATCH_GIT_BASIC_AUTHORIZATION` | **base64** of `your-username:PAT` (PAT with `repo` scope, to read/write the certs repo) |

Two of them are base64 blobs; the other five are plain strings. Set them on the
**code repo** (`calebpaulsmith/Timecard-App`) — `gh secret set NAME` reads the
value from stdin when you don't pass `-b`, so you can pipe the base64 straight in.

**Windows (PowerShell):**

```powershell
gh secret set ASC_KEY_ID            -b "ABCDE12345"
gh secret set ASC_ISSUER_ID         -b "11111111-2222-3333-4444-555555555555"
gh secret set DEVELOPER_TEAM_ID     -b "A1B2C3D4E5"
gh secret set MATCH_GIT_URL         -b "https://github.com/calebpaulsmith/timecard-certificates.git"
gh secret set MATCH_PASSWORD        -b "your-match-passphrase"

# base64 the .p8 and pipe it in
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\AuthKey_XXXXXXXXXX.p8")) | gh secret set ASC_KEY_CONTENT
# base64 of "username:PAT" (PAT needs `repo` scope)
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("calebpaulsmith:ghp_YOURPAT")) | gh secret set MATCH_GIT_BASIC_AUTHORIZATION
```

**macOS / Linux:**

```sh
gh secret set ASC_KEY_ID        -b 'ABCDE12345'
gh secret set ASC_ISSUER_ID     -b '11111111-2222-3333-4444-555555555555'
gh secret set DEVELOPER_TEAM_ID -b 'A1B2C3D4E5'
gh secret set MATCH_GIT_URL     -b 'https://github.com/calebpaulsmith/timecard-certificates.git'
gh secret set MATCH_PASSWORD    -b 'your-match-passphrase'
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_CONTENT
printf 'calebpaulsmith:ghp_YOURPAT' | base64 | gh secret set MATCH_GIT_BASIC_AUTHORIZATION
```

(No CLI? Do it in the browser: repo → Settings → Secrets and variables → Actions →
New repository secret. For the two base64 ones, paste the encoded string as the value.)

---

## 4. Bootstrap signing (once)

```sh
gh workflow run "iOS Bootstrap signing"
gh run watch
```

Creates the Apple Distribution cert + App Store profile and commits them (encrypted) to the certs repo.
Re-run only if a cert expires/gets revoked.

## 5. Ship a build

```sh
git tag v0.1.0 && git push origin v0.1.0      # or: gh workflow run "iOS TestFlight"
gh run watch
```

Builds a Release archive and uploads to TestFlight. `CURRENT_PROJECT_VERSION` is set to the GitHub run
number, so build numbers never collide; bump `MARKETING_VERSION` in `project.yml` for real version bumps.
After ~5–15 min of processing in App Store Connect → TestFlight, add yourself as an **Internal** tester
(no review needed) and install via the TestFlight app.

---

## Everyday loop

```sh
git push                       # CI runs tests
git tag vX.Y.Z && git push origin vX.Y.Z   # cuts a TestFlight build
```

## Gotchas

- **App record must exist** before the first `pilot` upload (step 1.2).
- Signing is **manual via match** — `fastlane/Fastfile`'s `beta` lane flips the generated project to the
  `match AppStore com.thegrandpipeline.timecard` profile, so don't enable automatic signing in CI.
- Runners pin `macos-15` + `xcode-version: latest-stable`; if a runner image breaks the build, pin a
  specific Xcode in the three workflow files.
- `.xcodeproj` is generated by XcodeGen in CI — never commit one.
