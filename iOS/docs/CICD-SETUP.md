# CI/CD setup — GitHub Actions → TestFlight

This pipeline lets you ship the app to your iPhone **without ever touching a
Mac**. GitHub's macOS runners build it; Apple's TestFlight delivers it.

```
push code ──► CI workflow (runs tests)
tag / click ─► TestFlight workflow ──► build on macOS runner ──► upload ──► TestFlight ──► your iPhone
```

Everything in this repo (`fastlane/`, `.github/workflows/`) is already written.
What's left is **account setup + secrets** — all done in a web browser. Do these
once, in order. Budget ~1–2 hours of clicking plus waiting on Apple's enrollment
approval (can take a few hours to ~2 days).

> **Already shipped another app this way?** If you have an existing app under the
> **same Apple Developer account + GitHub account**, most account-level secrets
> (Team ID, the App Store Connect API key, and the `fastlane match` certs repo)
> are reusable — see the short-path runbook in
> [`CICD-SETUP-REUSE.md`](./CICD-SETUP-REUSE.md), which skips enrollment and API-
> key creation and reuses the certs repo.

---

## What you'll end up with

- **CI workflow** — runs the domain unit tests on every push/PR. Works the
  instant you push the repo (no secrets needed). Validates the Swift port for
  the first time.
- **Bootstrap-signing workflow** — run once; creates and stores your signing
  certificate + profile.
- **TestFlight workflow** — build + upload, triggered manually or by a `v*` tag.

---

## Prerequisites / costs

- A **paid Apple Developer Program** membership — **$99/year**. TestFlight is
  NOT available on a free Apple account. This is the only hard cost.
- A GitHub account (you have `calebpaulsmith`). Free tier includes macOS Actions
  minutes; heavy use may need a paid plan, but a few builds/week is fine.

---

## Step 1 — Enroll in the Apple Developer Program  (web, then wait)

1. Go to <https://developer.apple.com/programs/enroll/>.
2. Sign in with your Apple ID (enable 2FA if not already).
3. Enroll as an **Individual** (simplest) and pay the $99.
4. Wait for the approval email. **You can't do steps 4–8 until this clears.**

Once approved, note your **Team ID**: <https://developer.apple.com/account> →
Membership details → "Team ID" (a 10-character string like `A1B2C3D4E5`).
→ This becomes the secret **`DEVELOPER_TEAM_ID`**.

---

## Step 2 — Register the App ID  (web)

1. <https://developer.apple.com/account/resources/identifiers/list>
2. **+** → **App IDs** → **App** → Continue.
3. Description: `Timecard`. Bundle ID: **Explicit** =
   `com.calebsmith.timecard` (must match `project.yml` exactly).
4. Capabilities: leave defaults for now (we'll add App Groups when widgets land).
5. Register.

---

## Step 3 — Create the app record in App Store Connect  (web)

1. <https://appstoreconnect.apple.com> → **Apps** → **+** → **New App**.
2. Platform: iOS. Name: a **store-unique** name (e.g. `Timecard` or a variant if
   `Timecard` is taken — the on-device name is "Timecard", set in the app via
   `INFOPLIST_KEY_CFBundleDisplayName`). SKU: anything, e.g. `timecard-001`.
   Bundle ID: pick `com.calebsmith.timecard`. Create.

You don't need to fill in store listing details for TestFlight.

---

## Step 4 — Create an App Store Connect API key  (web)

This key lets CI sign and upload without your password.

1. App Store Connect → **Users and Access** → **Integrations** tab →
   **App Store Connect API** → **Team Keys**.
2. **Generate API Key**. Name: `github-ci`. Access: **App Manager**.
3. **Download the `.p8` file — you can only download it once.** Keep it safe.
4. Note the **Key ID** (next to the key) and the **Issuer ID** (top of the page).
   → secrets **`ASC_KEY_ID`** and **`ASC_ISSUER_ID`**.

Convert the `.p8` to base64 for the secret (run in **PowerShell** on Windows):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\AuthKey_XXXXXXXXXX.p8"))
```

Copy the output → secret **`ASC_KEY_CONTENT`**.

---

## Step 5 — Code is already on GitHub + CI is already green  ✅ (nothing to do)

This is now a **monorepo**: the iOS app lives in `iOS/` of
`calebpaulsmith/Timecard-App` and is **already pushed**. The **iOS CI workflow
has already run green on `main`** — i.e. the Swift domain port has compiled and
its unit tests have passed on a real macOS runner. The foundation is verified;
you do **not** need the old separate `Maxiflex` repo or any `gh auth refresh`
dance referenced by earlier drafts of this doc.

Check it yourself any time: repo **Actions** tab → **iOS CI**. It runs
automatically on any push/PR that touches `iOS/**` — no secrets needed.

---

## Step 6 — Create the certificates repo  (web + CLI)

`fastlane match` stores your signing cert + profile, encrypted, in a **separate
private repo**.

1. Create an empty **private** repo, e.g. `timecard-certificates` (no README).
   → its HTTPS URL is secret **`MATCH_GIT_URL`**
   (`https://github.com/calebpaulsmith/timecard-certificates.git`).
2. Invent a strong passphrase (store it in your password manager). It encrypts
   the certs. → secret **`MATCH_PASSWORD`**.

CI needs read/write access to that private repo. Create a token:

3. <https://github.com/settings/tokens> → **Generate new token (classic)** →
   scope **`repo`** → generate, copy it.
4. Base64-encode `username:token` (PowerShell):

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("calebpaulsmith:ghp_YOURTOKEN"))
```

Copy the output → secret **`MATCH_GIT_BASIC_AUTHORIZATION`**.

---

## Step 7 — Add the GitHub Actions secrets  (web)

In the **Timecard-App** code repo: **Settings → Secrets and variables → Actions →
New repository secret**. Add all seven:

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | Key ID from Step 4 |
| `ASC_ISSUER_ID` | Issuer ID from Step 4 |
| `ASC_KEY_CONTENT` | base64 of the `.p8` (Step 4) |
| `DEVELOPER_TEAM_ID` | 10-char Team ID (Step 1) |
| `MATCH_GIT_URL` | certs repo HTTPS URL (Step 6) |
| `MATCH_PASSWORD` | your match passphrase (Step 6) |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 `user:token` (Step 6) |

---

## Step 8 — Bootstrap signing  (one click)

**Actions** tab → **Bootstrap signing** → **Run workflow**. This creates the
distribution certificate + App Store provisioning profile and stores them
(encrypted) in the certs repo. Should finish green in a couple minutes. Re-run
only if a cert expires or is revoked.

---

## Step 9 — Ship your first build  (one click or a tag)

Either:

```powershell
git tag v0.1.0
git push origin v0.1.0
```

…or **Actions → TestFlight → Run workflow**. It builds a Release archive and
uploads it.

---

## Step 10 — Review on your iPhone

1. After the workflow succeeds, the build appears in App Store Connect →
   **TestFlight** after ~5–15 min of "Processing".
2. Add yourself as a tester: TestFlight tab → **Internal Testing** → create a
   group → add your Apple ID. (Internal testers need no Apple review.)
3. Install **TestFlight** from the App Store on your iPhone, sign in with the
   same Apple ID, accept the invite, install the build.

---

## The everyday loop, once it's set up

1. Edit code on Windows, commit, `git push`.
2. CI runs the tests automatically — watch the Actions tab.
3. When you want to see it on your phone: push a tag (`git tag v0.1.1 && git
   push origin v0.1.1`) or click Run on the TestFlight workflow.
4. New build lands in TestFlight; open it on your phone.

No Mac, ever. The only recurring cost is the $99/yr Apple membership and GitHub
Actions minutes.

---

## Notes / troubleshooting

- **Runner image & Xcode version**: workflows run on `macos-15` with
  `xcode-version: latest-stable`. If a future runner image breaks the build, pin
  a specific `xcode-version` and/or bump `runs-on` in the three workflow files.
  iOS 17 deployment target only needs Xcode ≥ 15.
- **Simulator name**: `ios-ci.yml` tests on `iPhone 16`. If a runner image drops
  it, change the `-destination` name to one the image provides.
- **App name taken**: the App Store *listing* name must be globally unique; the
  on-device name comes from `INFOPLIST_KEY_CFBundleDisplayName` in `project.yml`
  and can differ.
- **Build numbers**: each TestFlight upload gets `CURRENT_PROJECT_VERSION` =
  the GitHub run number (monotonic), so uploads never collide. The marketing
  version (`0.1.0`) lives in `project.yml`; bump it for real releases.
- **Costs of a wrong key**: if you ever rotate the API key or token, just update
  the corresponding secret — no code change needed.
