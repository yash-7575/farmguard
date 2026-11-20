# FarmGuard — Demonstration Guide (two-phone or single-phone)

Stage 10 physical-verification script. Everything in this guide is a **plan**:
nothing in it has been executed on real phones yet. That is the point of the
document — it is the checklist someone follows to produce the first real
end-to-end verification.

- Backend: Cloudflare Worker + D1 + R2 + FCM HTTP v1
  (`farmguard-backend/README.md`)
- Phone A: FarmGuard **Camera** app (Flutter, on-device YOLO26s detection)
- Phone B: FarmGuard **Farmer** app (Flutter, events + push notifications)

Where this guide says `https://farmguard-backend.yashsb-75.workers.dev`, substitute the deployed workers.dev
URL of the backend once `wrangler deploy` has been run. Today the URL does not
exist yet; both mobile apps still carry the placeholder constant
`https://farmguard-backend.example.workers.dev`
(see `farmguard_camera/lib/services/api_client.dart`,
`farmguard_farmer/lib/services/api/http_farmer_api.dart`).

---

## 0. Prerequisites (before anyone touches a phone)

| # | Requirement | Notes |
|---|-------------|-------|
| 1 | Android phone(s) with internet | One phone is enough (both APKs install side by side — see **§0b**); two phones give the classic simultaneous flow (§1–§5). Android 13+ for the notification-permission step |
| 2 | Backend deployed | `cd farmguard-backend && npx wrangler deploy`. Then record the URL as `https://farmguard-backend.yashsb-75.workers.dev` |
| 3 | D1 migrations applied remotely | `npx wrangler d1 migrations apply farmguard-db --remote` (documented in backend README, not yet run) |
| 4 | `AUTH_SECRET` set | `wrangler secret put AUTH_SECRET` |
| 5 | `FCM_SERVICE_ACCOUNT` set | Manual key download from Firebase console → project `project1-eaebc` → Project settings → Service accounts → Generate new private key, then `wrangler secret put FCM_SERVICE_ACCOUNT < ~/.secrets/farmguard-fcm-service-account.json` (full steps in `farmguard_farmer/README.md`). Without it the backend runs but **skips push silently** (`FCM not configured`) |
| 6 | Base URL constants updated | Replace the placeholder in both `api_client.dart` (camera) and `http_farmer_api.dart` (farmer) with `https://farmguard-backend.yashsb-75.workers.dev`, then rebuild |
| 7 | APKs built | `flutter build apk` in `farmguard_camera` and `farmguard_farmer`. Result: `build/app/outputs/flutter-apk/app-debug.apk` in each project. Build **after** the deploy step above so the URL constant is baked in |
| 8 | Firebase project ready | `project1-eaebc`; farmer package `com.example.farmguard_farmer` already registered (`farmguard_farmer/README.md`) |
| 9 | Health check passes | `curl https://farmguard-backend.yashsb-75.workers.dev/api/health` → `{"ok":true,"data":{"status":"ok","service":"farmguard-backend","time":"..."}}` (route: `farmguard-backend/src/routes/health.ts`) |

Sanity check with curl before the demo (proves deploy + auth work without any
phone):

```bash
curl -X POST https://farmguard-backend.yashsb-75.workers.dev/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"Demo","email":"demo@example.com","password":"password123"}'
# → 201 {"ok":true,"data":{"token":"…","farmer":{"id":"…","name":"Demo","email":"demo@example.com"}}}
```

---

## 0b. Single-phone mode (no second phone needed)

The two apps are **separate Android apps with different applicationIds** —
`com.example.farmguard_camera` and `com.example.farmguard_farmer` — so both
APKs install side by side on **one** phone with no conflict. One phone is
enough to run the entire demo.

**Adapted flow:**

1. Install both APKs (§1 step B1 and §3 step A1 on the same device).
2. Register the farmer account in the farmer app (§1 B2–B7).
3. Pair via the in-app code: farmer app → Cameras tab → **Pair a camera** →
   read the 6-digit code → switch to the camera app → **Pair this camera** →
   enter the code within 5 minutes (§2 and §3 A6–A8; works unchanged on one
   phone).
4. Run each camera scenario (§4) with the phone resting against an object,
   pointed at a doorway or a person — the phone does **not** need to be held;
   person detection works from a stationary camera.
5. Check the results in the farmer app (§5).

**The sequential-rhythm rule.** Because both apps share one phone, the demo is
*sequential*: complete a camera-side scenario first, then switch to the farmer
app to check the results. This is a designed behavior, not a bug — the camera
app's lifecycle guard pauses/stops monitoring when the app leaves the
foreground (backgrounding releases the camera, see §4.6). Nothing is lost in
the switch: confirmed events are persisted locally and uploaded before you
leave the camera app. Bonus for the demo: the switch itself demonstrates
camera release on backgrounding (§4.6), live.

**Split-screen note.** Android split-screen (camera top / farmer bottom) can
show both apps at once, **but** when the farmer half takes focus the camera
half may report "inactive" and pause monitoring. Treat split-screen as a
nice-to-have visual; sequential switching is the reliable mode.

**Push on the same phone.** FCM push works in single-phone mode too: the same
device receives the push notification for the events its own camera created,
and tapping it opens the farmer app on that event. Push depends on the
`FCM_SERVICE_ACCOUNT` secret (§0 requirement 5 — not duplicated here). Without
that secret, events still appear in the farmer app's feed (pull path); you
just get no notification.

> **What you lose vs two phones:** simultaneity (you can't watch the camera
> preview and the farmer feed at the same instant), and the "watch the
> notification arrive on another device" moment — on one phone the
> notification lands on the device you're already holding. Nothing else
> changes: **all 8 scenarios in §4 and the §6 edge demos remain runnable.**

---

## 1. Phone B — Farmer app setup

> This and §3–§5 describe the classic **two-phone** flow (Phone A = camera,
> Phone B = farmer). Demoing on a single phone? See **§0b** first.

| Step | Action | Expected result |
|------|--------|-----------------|
| B1 | Install `farmguard_farmer/build/app/outputs/flutter-apk/app-debug.apk`, allow install from unknown sources | App installed |
| B2 | Launch | First run: "Checking your session…" → login screen (brand shield icon, "Sign in to watch over your farm") |
| B3 | Tap "New to FarmGuard? Create an account" | Form gains a **Name** field |
| B4 | Enter name, email, password (≥ 8 chars) and submit ("Create account") | `POST /api/v1/auth/register`; app enters the main shell |
| B5 | Notification permission prompt appears (Android 13+) | Tap **Allow**. Declining does not break the app — it only skips push registration silently (`farmguard_farmer/lib/services/messaging/push_session.dart`) |
| B6 | Open the **Cameras** tab | Honest empty state: "No cameras yet" ("When a camera is added to your farm, it will appear here…") — `farmguard_farmer/lib/screens/main_shell.dart` |
| B7 | Open **Settings** → Account | Shows the name/email just registered; "Log out" button present |

> Note: the Home and History tabs also show six pre-seeded demo records
> labelled **DEMO** (`MockData`, `farmguard_farmer/lib/data/mock_data.dart`,
> ids FG-0184 … FG-0169, plus four demo cameras).
> These are retained deliberately and labelled; live events appear above them.

---

## 2. Pairing — generating a code (in-app)

On **Phone B**, open the **Cameras tab**:

1. Tap **Pair a camera** (a tonal button in the title row; also shown inside
   the "No cameras yet" empty state).
2. A dialog opens, calls `POST /api/v1/pairing/code`
   (`farmguard-backend/src/routes/pairing.ts`) with the logged-in farmer's
   Bearer token, and shows the **6-digit code large**, with a live
   **mm:ss countdown to expiry** (`farmguard_farmer/lib/widgets/pairing_code_dialog.dart`).
3. Read the code to the Phone A operator. Keep the dialog open — the code is
   only valid **5 minutes** and is **single-use**.
4. If it expires mid-demo, the dialog flips to an expired state with
   **Generate new code** as the primary action — tap it and continue.
   You can also regenerate at any time while a code is showing.

- Only the SHA-256 hash of the code is stored server-side.
- Generating codes has no rate limit; only *redemption* is limited
  (20 attempts / 10 min per IP and per device, checked before any code lookup).

Curl fallback (laptop, if you prefer showing the raw API call during the
Computer Networks demo):

```bash
# 2.1 Login (or reuse the register response from §1)
TOKEN=$(curl -s -X POST https://farmguard-backend.yashsb-75.workers.dev/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"demo@example.com","password":"password123"}' \
  | jq -r '.data.token')

# 2.2 Generate a pairing code
curl -s -X POST https://farmguard-backend.yashsb-75.workers.dev/api/v1/pairing/code \
  -H "Authorization: Bearer $TOKEN"
# → 201 {"ok":true,"data":{"code":"123456","expires_at":"2026-11-18T22:47:00.000Z"}}
```

---

## 3. Phone A — Camera app setup and pairing

| Step | Action | Expected result |
|------|--------|-----------------|
| A1 | Install `farmguard_camera/build/app/outputs/flutter-apk/app-debug.apk` | App installed |
| A2 | Launch | Home screen: leaf icon, "FarmGuard Camera / Smart Farm Surveillance", **Start Monitoring** button, Cloud status card showing "Not paired" with a **Pair this camera** button |
| A3 | Tap **Start Monitoring** | Android camera permission dialog → tap **Allow** |
| A4 | First run only: model download | Progress card: "Downloading model… N%" — official `yolo26s_w8a32.tflite`, 10,086,793 bytes (~9.6 MB), downloaded once from the Ultralytics pinned release and cached in the app documents directory (`farmguard_camera/README.md`). **Needs network once**; then "Loading model…" while the native view initializes |
| A5 | Monitoring starts | Live preview with a red-dot "Monitoring" chip; stats bar below: "YOLO26s · W8A32 · People: 0 · X.X FPS · X.X ms"; inference runs on-device |
| A6 | Tap **Pair this camera** | "Pair camera" dialog: 6-digit code field (digits only), camera name prefilled "Farm Camera", optional location field |
| A7 | Enter the code from §2, adjust name (e.g. "Gate"), optionally add location, tap **Pair** | Button shows "Pairing…"; `POST /api/v1/pairing/redeem` runs; on 201 the dialog closes |
| A8 | Check the status card | Paired row now shows the camera name with a filled camera icon |

Server-side pairing guards to be aware of (`farmguard-backend/src/routes/pairing.ts`):

| Situation | Result |
|-----------|--------|
| Unknown code | 404 `not_found`, message "This pairing code is not valid." |
| Already-consumed code | Same 404 (reuse is indistinguishable from unknown) |
| Expired (> 5 min) | 410 `code_expired` "This pairing code has expired." |
| 6th failed attempt on one code | 429 `too_many_attempts` |
| Device already paired | 409 `device_already_paired` |
| > 20 redemption attempts / 10 min per IP or device | 429 `too_many_requests`, checked **before** any code lookup |

The dialog renders the server's own message inline on failure
(`farmguard_camera/lib/widgets/pairing_dialog.dart`).

---

## 4. Detection test scenarios (Phone A, with Phone B watching)

Run each scenario with both phones in the same room; Phone A pointed at a
doorway or table edge so a person can enter/leave the frame. (Single-phone
mode per §0b: the same scenarios run on one device, sequentially.)

### 4.1 Empty scene

- **Do:** leave the scene empty, watch the preview + stats bar.
- **Expected:** live FPS and inference-ms values updating; "People: 0"; no
  bounding boxes; no events; cloud card "Idle", "Last sync: Never" until the
  first upload succeeds (60 s heartbeats run but don't change last-sync).

### 4.2 Person enters (the core path)

- **Do:** walk into the frame and stay briefly, then leave.
- **Expected on Phone A:**
  1. Green bounding box with "Person" label and confidence rendered by
     YOLOView while the person is in frame.
  2. After **3 of the last 5 frames** contain a person at confidence ≥ 0.50
     (`detection_config.dart`: `confirmationWindow 5`, `confirmationMinimum 3`,
     `confidenceThreshold 0.50`) an event confirms.
  3. Cloud card flips to "Uploading" (pending ≥ 1), then back to "Idle" with
     "Last sync: Just now" once the upload is confirmed. "Pending" count
     returns to 0.
- **Expected on Phone B:** push notification arrives — title
  **"Person detected on your farm"**, body **`<camera name> · <YYYY-MM-DD
  HH:MM UTC>`** (e.g. "Gate · 2026-11-18 22:41 UTC"), no locale guessing
  (`farmguard-backend/src/services/fcm.ts`, `formatDetectedAtUtc`). History
  gains one event with a **LIVE** chip and **New** badge.

### 4.3 Continuous presence (no event spam)

- **Do:** stay in frame for 2–3 minutes.
- **Expected:** exactly one event at confirmation, then nothing until the
  **30 s cooldown** elapses and presence re-confirms (at most ~1 event per
  30 s of continuous presence). No flood, no duplicate rows — the cooldown is
  `DetectionConfig.defaultCooldown = Duration(seconds: 30)`
  (`farmguard_camera/lib/config/detection_config.dart`).

### 4.4 Wi-Fi off mid-monitoring

- **Do:** confirm one event normally, then turn Phone A's Wi-Fi off and let a
  second event confirm.
- **Expected:** the cloud card keeps state "Uploading" (a pending count > 0
  forces "Uploading" in `_cloudState()`) and shows "1 pending" (or more) —
  note the card's "Offline" state appears only when **unpaired**; a paired
  camera with a failing network reads as "Uploading" with a stuck pending
  count. The event itself is persisted immediately to app storage
  (`<appDocuments>/farmguard/pending/<eventId>.json` + `.jpg`,
  `farmguard_camera/lib/services/file_pending_store.dart`) and retried with
  exponential backoff — never lost.

### 4.5 Wi-Fi back (retry succeeds)

- **Do:** turn Wi-Fi back on, wait.
- **Expected:** the queue's 5 s processing timer retries the pending event
  (`upload_queue.dart` `start(interval: 5 s)`); server answers 201; cloud card
  returns to "Idle", pending 0, "Last sync: Just now". The event id is a
  client-generated UUIDv4 that doubles as the idempotency key, so a retry
  after an ambiguous network failure answers `200 {event, duplicate: true}`
  and still counts as confirmed (`farmguard_camera/lib/services/api_client.dart`).

Backoff constants (all in `detection_config.dart`): first retry after
**1500 ms**, ×**2.0** per further failure, capped at **60 s**, plus up to
**0.5×** the computed delay as random jitter; **8 attempts max** before the
event is marked permanently failed and kept (never silently deleted) — a
"**N failed — kept on this device**" row with a **Retry now** button appears
in the cloud card in that case.

### 4.6 App backgrounded and resumed

- **Do:** home button during monitoring, then return to the app.
- **Expected:** backgrounding releases the camera (phase → idle; on-device
  privacy behavior); returning to the foreground **automatically restarts
  monitoring** because it was active before the interruption
  (`_resumeOnAppResume`, `farmguard_camera/lib/screens/home_screen.dart`).
  Queued events survive because they were persisted.

### 4.7 Stop / Start Monitoring

- **Do:** tap **Stop Monitoring**, then **Start Monitoring** again.
- **Expected:** stop returns to the idle placeholder and releases the camera
  instantly; start re-runs permission (already granted → no dialog) → model
  **loads from cache (no re-download)** → back to monitoring within seconds.
  Events confirmed during the stopped window don't exist — monitoring is off.

### 4.8 Invalid pairing code path

- **Do:** unpair isn't needed; simply open the pairing dialog on a fresh
  device (or after clearing app data) and type a wrong 6-digit code.
- **Expected:** inline red error "This pairing code is not valid." (404
  envelope). The dialog stays open; nothing is stored. (On a real server the
  global limiter also applies: after 20 attempts in 10 minutes the message
  becomes "Too many redemption attempts. Try again later.")

---

## 5. Phone B verification (the farmer side)

| Step | Action | Expected result |
|------|--------|-----------------|
| V1 | (With Phone B backgrounded) trigger an event on Phone A | System notification tray shows **"Person detected on your farm"** with the camera name + UTC time |
| V2 | Tap the notification | App opens the **DetectionDetailScreen** for that exact event (tap carries `data {event_id, camera_id}`; `MainShell` fetches `GET /api/v1/alerts/:id` and pushes the detail route) |
| V3 | Inspect the detail screen | The **REAL captured image** from Phone A (fetched via `GET /api/v1/images/:eventId`, Bearer-authenticated); **LIVE** chip in the app bar; **New** badge; green bounding-box overlay drawn from the event's normalized coordinates; fact rows: Time, Camera, Location (or "—"), Confidence (percent + progress bar), Event ID |
| V4 | Navigate back, open the **History** tab | The event is listed with the **LIVE** chip; the **New** badge is gone (it became **Viewed** — opening the detail fired `PATCH /api/v1/alerts/:id/viewed`, and `MainShell` also flips the local flag) |
| V5 | Open **Settings** | Account section shows the farmer name + email from the session; App information rows |
| V6 | Tap **Log out** | Device FCM token is unregistered **first** (`DELETE /api/v1/notifications/unregister-device`), then the session clears and the login screen returns. Push for the next event must **not** arrive on Phone B |
| V7 | Log back in | Permission prompt is not repeated if already granted; device re-registers (`POST /api/v1/notifications/register-device`); History still shows the earlier LIVE events (each login issues a fresh 12 h farmer token — there is no refresh token by design) |

---

## 6. Failure / edge demos (optional but valuable)

| # | Scenario | Expected result |
|---|----------|-----------------|
| E1 | Re-enter a pairing code that was already used | Phone A: inline "This pairing code is not valid." — a consumed code answers the same 404 as an unknown one by design |
| E2 | Curl an alert with a farmer token | `POST /api/v1/alerts` rejects farmer tokens with **403** (camera-only route) — demonstrates route-level authorization |
| E3 | Curl any farmer route with no/garbage token | **401** invalid-token envelope |
| E4 | Image too large (hard to trigger naturally; simulate by POSTing > 8 MiB raw bytes with the camera token via curl) | 413 `payload_too_large`; the camera app's response to a permanent image failure is to **drop the image and still upload the event imageless** — Phone B then shows the detail with a muted "**No image**" placeholder instead of a frame (`farmguard_farmer/lib/widgets/event_image.dart`) |
| E5 | Foreign farmer tries to read an event | Register a second farmer, curl `GET /api/v1/alerts/:id` / `GET /api/v1/images/:eventId` for the first farmer's event → **404**, indistinguishable from nonexistent (ownership scoping never leaks existence) |
| E6 | Kill Phone A's app mid-upload (force-stop between image POST and alert POST) | On relaunch the queue restores persisted events; the already-obtained R2 object key was persisted **before** the alert POST, so the image is not re-uploaded; the alert retry completes with the cached key |

---

## 7. What this guide verifies vs what automated tests already covered

Automated test suites (counts verified by counting `test(`/`testWidgets(`
declarations in each repo's test directory):

| Suite | Test cases | What they prove |
|-------|-----------|-----------------|
| `farmguard-backend` (vitest, real workerd via Miniflare) | **104** | Route logic, envelope shape, auth boundaries, pairing/re-pairing guards, token-version revocation, `/cameras/me`, 120 s heartbeat freshness, soft-unpair history preservation, idempotency, push fan-out |
| `farmguard_camera` (Flutter) | **153** | Detection window/cooldown math, upload queue/backoff, `camera_name`/`name`/farmer parsing, production token provider, bounded preview layout, native readiness gate + 20 s watchdog, heartbeat 401 unpair handling, Connection Details UI |
| `farmguard_farmer` (Flutter) | **98** | Auth gate, repositories, 120 s camera online freshness, Remove Camera confirmation/delete/refresh flow, shell tabs, tap routing, push session |

That is **355 automated cases** proving *logic*. What they cannot prove — and
what executing this guide on hardware does:

- REAL on-device detection (YOLO26s running on actual camera frames at usable
  FPS/latency)
- REAL upload over a real network from the phone to the deployed Worker
- REAL FCM push delivery to a physical device (server-side push was tested
  against a fake transport only; the Firebase service-account secret was not
  even configured at the time of writing)
- REAL image display (the private R2 → Worker → farmer-app image path)
- REAL pairing UX on real phones, including the 5-minute code expiry pressure

**None of the above is claimed done until it has been executed on hardware.**
When you run the demo, tick the scenario numbers in §4–§6 and record the
actual numbers (FPS, ms, sync delay) — those measurements feed the latency
section of `FARMGUARD-NETWORKING.md`.
