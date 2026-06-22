# CI/CD setup (reusing an existing app's secrets) — GitHub Actions → TestFlight

This is the **short path** of `CICD-SETUP.md`, for when you already shipped
another app this way (here: "Amelia's Playground") under the **same Apple
Developer account** and the **same GitHub account**. Almost everything
account-level is already done — you only do the per-app pieces.

> If the other app is on a *different* Apple ID/team or a *different* GitHub
> owner, the account-level secrets won't transfer — use the full `CICD-SETUP.md`
> instead.

```
push code      → iOS CI runs tests (already green, no secrets needed)
tag v* / click → TestFlight workflow → build on macOS runner → upload → TestFlight → iPhone
```

> ⚠️ **GitHub secrets can't be read back out.** Once saved, GitHub never shows a
> secret value again. So "reuse the secrets" means **reuse the original source
> values** — the `.p8`, the Team ID, the match passphrase, the GitHub token —
> from wherever you saved them (password manager / Downloads). If a value only
> ever lived inside the other repo's secrets, you must regenerate it. The API
> key and token are free to regenerate; the **match passphrase is the one you
> cannot lose** — without it the certs repo can't be decrypted.

---

## What you reuse vs. what's new

| Thing | Reuse? | Why |
| --- | --- | --- |
| Apple Developer enrollment ($99/yr) | ✅ reuse | account-wide |
| `DEVELOPER_TEAM_ID` | ✅ reuse | same Apple team |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_CONTENT` | ✅ reuse | the API Team Key is account-wide; signs all apps |
| `MATCH_GIT_URL` / `MATCH_PASSWORD` / `MATCH_GIT_BASIC_AUTHORIZATION` | ✅ reuse | match holds many apps in one certs repo; the distribution cert is account-wide |
| **Bundle ID / App ID** | ✅ already exists | `com.thegrandpipeline.timecard` is already registered on the account |
| **App Store Connect app record** | ✅ already exists | the "Timecard" record already exists for this bundle ID |
| GitHub Actions secrets *in this repo* | ❌ must re-add | secrets don't cross repos — same values, new home |

---

## Step 1 — Skip enrollment ✅
Already done. Confirm you can sign in at <https://developer.apple.com/account>
and the membership is active.

## Step 2 — App ID  ✅ already registered
`com.thegrandpipeline.timecard` is already an App ID on the account (confirm at
<https://developer.apple.com/account/resources/identifiers/list>). It must match
`project.yml` exactly — it does. If for some reason it's missing: **+** → **App
IDs** → **App** → Explicit = `com.thegrandpipeline.timecard`, defaults, Register.

## Step 3 — App Store Connect record  ✅ already exists
The "Timecard" app record for `com.thegrandpipeline.timecard` already exists in
App Store Connect (Apps list). Nothing to create. If it were missing: Apps →
**+** → **New App** → iOS, that bundle ID, a store-unique name, any SKU.

## Step 4 — Skip API key creation ✅
Reuse the existing App Store Connect API key. You need the saved values: the
**Key ID**, the **Issuer ID**, and the base64 of the `.p8`. If you saved the
base64 already, reuse it verbatim; if you only have the `.p8`, re-encode it
(PowerShell):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\AuthKey_XXXXXXXXXX.p8"))
```

## Step 5 — Code + CI already done ✅
The iOS app is already in `iOS/` and the iOS CI workflow has run green on `main`.
Check anytime: repo **Actions** tab → **iOS CI**. No secrets needed for CI.

## Step 6 — Reuse the certs repo ✅
Don't create a new one. Point at the existing match repo. `fastlane match` adds a
new provisioning profile for `com.thegrandpipeline.timecard` alongside the existing
ones — the distribution certificate is shared account-wide. You need three saved
values:
- `MATCH_GIT_URL` — the same certs-repo HTTPS URL.
- `MATCH_PASSWORD` — the **same passphrase** (this is the one you cannot lose).
- `MATCH_GIT_BASIC_AUTHORIZATION` — base64 of `user:token` with `repo` scope.
  Reuse the same token, or mint a fresh one if you don't have it:

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("calebpaulsmith:ghp_YOURTOKEN"))
```

## Step 7 — Add the 7 secrets to THIS repo  (web)
Even though the values are reused, GitHub secrets are per-repo. In
**Timecard-App**: **Settings → Secrets and variables → Actions → New repository
secret**. Add all seven with the same values the other app uses:

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | (reused) Key ID |
| `ASC_ISSUER_ID` | (reused) Issuer ID |
| `ASC_KEY_CONTENT` | (reused) base64 `.p8` |
| `DEVELOPER_TEAM_ID` | (reused) 10-char Team ID |
| `MATCH_GIT_URL` | (reused) certs repo URL |
| `MATCH_PASSWORD` | (reused) match passphrase |
| `MATCH_GIT_BASIC_AUTHORIZATION` | (reused) base64 `user:token` |

> Tip: if both repos are in an **org**, promote these to **org-level** secrets
> and grant both repos access — then you set them once instead of per repo. For
> two personal repos, paste them into each.

## Step 8 — Bootstrap signing  (one click)
**Actions** tab → **Bootstrap signing** → **Run workflow**. Because the
distribution cert already exists in the shared repo, this just **creates and
stores the new App Store provisioning profile for `com.thegrandpipeline.timecard`**.
Finishes green in a couple minutes.

## Step 9 — Ship your first build  (one click or a tag)
```powershell
git tag v0.1.0
git push origin v0.1.0
```
…or **Actions → TestFlight → Run workflow**.

## Step 10 — Review on your iPhone
1. Build appears in App Store Connect → **TestFlight** after ~5–15 min
   "Processing".
2. TestFlight tab → **Internal Testing** → create a group → add your Apple ID
   (no Apple review for internal testers).
3. Install **TestFlight** on the iPhone, sign in with the same Apple ID, accept
   the invite, install.

---

### Net difference from the full doc
Skip **Step 1 (enroll)** and **Step 4 (API key creation)**, and **reuse** rather
than create the certs repo in Step 6. The genuinely new work is just **Step 2
(App ID)**, **Step 3 (app record)**, **Step 7 (paste the reused secrets into this
repo)**, then **bootstrap + ship**.
