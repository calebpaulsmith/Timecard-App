# Maxiflex Time Tracker

A personal, iPhone-and-Android-friendly Progressive Web App for tracking hours on a federal maxiflex biweekly schedule (80 hours / 2 weeks). Installs to your home screen, works offline, stores everything locally on the device.

No accounts. No backend. No sync.

## What it does

- **Clock in / clock out** with one tap (rounded to the nearest 15 min; auto-deducts 30 min for lunch if the shift is ≥ 4 hours).
- **Headline number**: hours left to hit 80 this pay period, plus pacing (hrs/day needed, "ahead / on pace / behind" badge).
- **Leave hours**: one-tap "+1 hour" per day for any leave that counts toward the 80.
- **14-day pay-period view**: every day as a card, tap to edit.
- **Day editor**: add/edit/delete time entries with a quarter-hour picker, adjust leave with +/−.
- **Forgotten clock-out guard**: entries open > 16 hours are flagged incomplete (contribute 0 hrs) until you fix them manually.
- **8-hour shift mode** (optional toggle in Settings): any hours worked past 8 on a single day are tracked as overtime. Lunch is still deducted for shifts ≥ 4h, so a 9-to-5:30 shift (8.5 hrs clocked) counts as 8.0 paid hours with 0 OT. Anything beyond that tips into OT.
- Respects system dark mode. Haptic feedback on clock in/out (where supported).

## Hosting — you need HTTPS

PWAs require HTTPS (or `localhost`) to install and run the service worker. Pick one:

### Option A: GitHub Pages (free, easiest)
1. Create a new GitHub repo (public).
2. Upload every file in this folder (`index.html`, `styles.css`, `app.js`, `db.js`, `time.js`, `sw.js`, `manifest.json`, `icons/`) to the repo root.
3. Repo → **Settings → Pages** → **Source: Deploy from branch** → branch `main` / folder `/ (root)` → Save.
4. Wait ~1 minute. GitHub gives you `https://<user>.github.io/<repo>/` — open that URL on your phone.

### Option B: Netlify Drop (no git, free)
1. Go to https://app.netlify.com/drop
2. Drag this entire folder onto the page.
3. Netlify gives you an `https://<random-name>.netlify.app` URL — open that on your phone.

### Option C: Cloudflare Pages / Vercel
Same deal — any static-file host that provides HTTPS works.

### Option D: Local testing only (desktop)
```
cd "Timecard App"
python -m http.server 8000
```
Then open http://localhost:8000 in Chrome/Edge. Service workers are allowed on `localhost` without HTTPS, so the PWA installs from Chrome devtools → Application. (You can't install to a phone this way — the phone needs to reach your computer over HTTPS.)

## Install on iPhone

1. Open the hosted URL in **Safari** (not Chrome — iOS only installs PWAs from Safari).
2. Tap the **Share** button (square with arrow up, at the bottom of the screen).
3. Scroll down and tap **Add to Home Screen**.
4. Confirm the name ("Maxiflex") and tap **Add**.
5. The app appears on your home screen. Tap to open — it runs fullscreen with no Safari chrome.

Notes:
- iOS 16.4+ recommended. Older iOS still works but with fewer PWA features.
- Data is stored in Safari's IndexedDB for this site. Clearing Safari website data will wipe it.

## Install on Android

1. Open the hosted URL in **Chrome**.
2. Chrome usually shows an "Install app" banner at the bottom. Tap it.
3. If not, tap the **⋮ menu** (top right) → **Install app** (or **Add to Home screen**).
4. Confirm. The app appears on your home screen / app drawer.

## First-time setup

1. Launch the app. It'll prompt you to set a **pay period anchor date** in Settings.
2. Pick **any Sunday** that was the first day of a pay period you know about. All other pay periods are computed as 14-day windows from that date. (If you pick a non-Sunday the app rejects it.)
3. Optionally flip on **8-hour shift mode** if you want daily OT tracking.
4. Hit the **back arrow** to return home. You're ready to clock in.

## How the math works

- **Rounding**: clock-in/out rounds to the nearest quarter hour (0, 15, 30, 45 min).
- **Lunch**: if clock-in to clock-out span is ≥ 4 hrs, 30 minutes is automatically deducted. < 4 hrs, no deduction.
- **Forgotten clock-out**: if an entry stays open > 16 hrs, it's marked "incomplete" and counts as 0 until you manually fix the times.
- **Pace**: average hrs/remaining day to reach 80. Badge shows "Ahead" if > 2 hrs above expected, "Behind" if > 2 hrs below, else "On pace."
- **Projected clock-out** (when currently clocked in): tells you when to end this entry so today's total hits 8 hrs, accounting for the lunch deduction.
- **8-hour mode (OT)**: per-day split. Worked hours ≤ 8 count as regular; anything over 8 is OT. A typical 8.5-hr clocked shift = 8.0 paid = 0 OT. A 9.5-hr clocked shift = 9.0 paid = 1.0 OT.

## Data / privacy

- Everything lives in IndexedDB on the device (via Dexie). Nothing is sent anywhere.
- No analytics, no tracking.
- To back up, manually export via browser devtools or copy the site data. (CSV export is a v2 feature.)

## File layout

```
index.html       app shell + all 4 views
styles.css       iOS-style theme with dark-mode support
app.js           UI, event handlers, rendering
db.js            Dexie schema + data access
time.js          pure date/pay-period/pacing/OT helpers
sw.js            service worker (offline cache)
manifest.json    PWA manifest
icons/           192 + 512 png app icons
```

Pure vanilla JS. No build step. Edit any file, refresh, done.
