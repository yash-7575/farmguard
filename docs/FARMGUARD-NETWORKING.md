# FarmGuard — Computer Networks Course Documentation

This document maps the **actual, implemented FarmGuard system** onto the
Computer Networks syllabus. Every claim traces to source code (paths cited
inline). The backend is **deployed live** at
`https://farmguard-backend.yashsb-75.workers.dev` (2026-11-19), but no phone
has been tested yet — the demo guide (`FARMGUARD-DEMO-GUIDE.md`) is the plan
for that. Until the two-phone demo runs, this document describes how the
implemented code is *designed* to communicate.

---

## 1. System architecture

```
        Phone A (FarmGuard Camera, Flutter/Android)                Phone B (FarmGuard Farmer)
  ┌───────────────────────────────────────────────┐           ┌────────────────────────────────┐
  │  CameraX frames → YOLO26s TFLite (on-device)  │           │  Flutter UI (4 tabs)           │
  │  3-of-5 window @ ≥0.50 conf → 30 s cooldown   │           │  push taps → detail screen     │
  │            │ confirmed event + JPEG snapshot  │           │                                │
  │            ▼                                  │           │                                │
  │  Upload queue (persisted, exponential backoff)│           │                                │
  └───────────────┬───────────────────────────────┘           └───────────────▲────────────────┘
                  │  HTTPS / JSON  (TLS 1.x over TCP)                        │ HTTPS/JSON + FCM push
                  │  POST /api/v1/images (raw JPEG, ≤8 MiB)                  │
                  │  POST /api/v1/alerts  (JSON, idempotent)                 │
                  │  POST /api/v1/pairing/redeem                             │
                  ▼                                                          │
  ┌───────────────────────────────────────────────────────────┐              │
  │        Cloudflare Worker (TypeScript, fetch handler)      │              │
  │  auth: HMAC-SHA256 Bearer tokens (farmer 12h/camera 30d)  │              │
  │  rate limiting, 256 KB JSON cap, CORS, ownership scoping  │              │
  └───────┬──────────────────────────────┬────────────────────┘              │
          │ SQL                          │ object get/put                    │
          ▼                              ▼                                   │
  ┌────────────────┐            ┌──────────────────────┐      ┌──────────────┴───────────┐
  │  Cloudflare D1 │            │  Cloudflare R2       │      │  FCM HTTP v1             │
  │  (farmguard-db)│            │  farmguard-images    │      │  fcm.googleapis.com      │
  │  SQLite rows   │            │  PRIVATE bucket      │      │  OAuth: RS256 JWT →      │
  │  events,cameras│            │  events/<yyyy-MM>/   │      │  access token → send     │
  │  farmers,codes │            │  <uuid>.jpg          │      └──────────────┬───────────┘
  └────────────────┘            └──────────────────────┘                     │
                                                            Google's FCM    │
                                                            delivery service▼
                                                                     (device push)
```

Key structural facts (all from `farmguard-backend/README.md` and routes):

- Images are **never public**: the R2 bucket has no public access; every byte
  moves through the Worker's authenticated routes
  (`farmguard-backend/src/routes/images.ts`).
- The Worker is the *only* trusted component: it owns password hashing, token
  signing, ownership scoping, rate limiting, and the FCM service-account
  credentials. The phones hold only their own Bearer token.
- Push is fire-and-forget relative to the alert request: a push failure never
  delays or fails the camera's 201 (`src/routes/alerts.ts`,
  `src/services/fcm.ts` — "NOTHING in this module ever throws outward").

---

## 2. Layer-by-layer mapping

### 2.1 Application layer — HTTPS REST/JSON

The application protocol is HTTP(S) carrying JSON in a fixed envelope:

```json
// success
{ "ok": true,  "data": { … } }
// failure
{ "ok": false, "error": { "code": "not_found", "message": "…" } }
```

(Envelope implementation: `farmguard-backend/src/utils/http.ts`; parsing on
the Dart side: `farmguard_camera/lib/services/api_client.dart` `ApiEnvelope`.)

Endpoint table (from `farmguard-backend/README.md` and the route files):

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/health` (alias `/api/v1/health`) | none | Liveness probe: `{status:"ok", service:"farmguard-backend", time:<ISO>}` (`src/routes/health.ts`) |
| POST | `/api/v1/auth/register` | none | `{name, email, password}` → 201 `{token, farmer}`; duplicate email → 409 (`src/routes/auth.ts`) |
| POST | `/api/v1/auth/login` | none | `{email, password}` → 200 `{token, farmer}`; same 401 envelope whether or not the email exists |
| GET | `/api/v1/auth/me` | farmer | Current farmer |
| POST | `/api/v1/pairing/code` | farmer | 6-digit code → 201 `{code, expires_at}` (5-min TTL, only SHA-256 hash stored) |
| POST | `/api/v1/pairing/redeem` | none (rate-limited) | `{code, device_identifier, camera_name, location?}` → 201 `{token, camera, farmer}` (idempotent re-pairing; initial `status: "offline"`, `last_seen_at: null`) |
| GET | `/api/v1/cameras` | farmer | Own active cameras (`unpaired_at IS NULL`; `status` downgraded to `offline` if `last_seen_at` > 120 s old) |
| GET | `/api/v1/cameras/:id` | farmer | Own active camera (foreign/unpaired → 404; 120 s heartbeat freshness enforced) |
| GET | `/api/v1/cameras/me` | camera | Active camera session + masked farmer account `{paired:true, camera, farmer:{id, name, email_masked}}` |
| POST | `/api/v1/cameras/me/unpair` | camera | Camera self-disconnect (soft-unpairs, increments `token_version`, revokes token) |
| POST | `/api/v1/cameras/:id/heartbeat` | camera | Touch `last_seen_at`, optional status body (sent immediately on monitoring start + every 60 s) |
| PATCH | `/api/v1/cameras/:id/status` | camera | Set `offline`/`online`/`monitoring` |
| POST | `/api/v1/alerts` | camera | Idempotent event upload; duplicate id → `200 {event, duplicate:true}`; new LIVE event also triggers push |
| GET | `/api/v1/alerts` | farmer | Keyset pagination: `limit` (1–50, default 20), `before` (ISO), `camera_id`; returns `{events, next_before}` |
| GET | `/api/v1/alerts/:id` | farmer | `{event, camera:{id,name,location}}` |
| PATCH | `/api/v1/alerts/:id/viewed` | farmer | Idempotent mark-viewed → `{event, updated}` |
| DELETE | `/api/v1/alerts/:id` | farmer | `{deleted:true}`; R2 image delete is best-effort |
| DELETE | `/api/v1/cameras/:id` | farmer | Soft-unpair (`unpaired_at` set, `token_version` bumped, historical events & R2 images preserved) → `{deleted:true, unpaired:true, events_preserved:n}` |
| POST | `/api/v1/notifications/register-device` | farmer | `{fcm_token, platform?}` upsert → 201 `{device}` |
| DELETE | `/api/v1/notifications/unregister-device` | farmer | `{fcm_token}` → `{deleted}` (idempotent) |
| POST | `/api/v1/images/upload-url` | camera | Honest descriptor `{upload_url:'/api/v1/images', method:'POST', max_size_bytes:8388608, allowed_content_types:['image/jpeg']}` |
| POST | `/api/v1/images` | camera | Raw binary JPEG, 1 B–8 MiB → 201 `{object_key}` |
| GET | `/api/v1/images/:eventId` | farmer | Streams the event's image, `Cache-Control: private, no-store` |

**DNS.** Before the first request to `https://farmguard-backend.yashsb-75.workers.dev` (a `*.workers.dev`
hostname), Android's DNS resolution turns the hostname into Cloudflare edge
IPv4/IPv6 addresses. Workers' global anycast network means the phone is
routed to the nearest edge PoP; the Worker code runs on that edge machine, so
the Worker↔D1/R2 hops are also inside Cloudflare's network. (DNS itself is a
standard application-layer service over UDP/53 or DoH; the app code doesn't
touch it — `package:http` → OS resolver → Cloudflare anycast.)

**FCM as an application-layer service.** Push delivery is not one of our
endpoints: the Worker acts as an FCM *client*, POSTing JSON to
`https://fcm.googleapis.com/v1/projects/<projectId>/messages:send` with a
Bearer access token obtained by exchanging an RS256 JWT at Google's OAuth
token endpoint (`src/services/fcm.ts`). The phone runs the FCM SDK client,
which maintains its own long-lived connection to Google's services (out of
our control — a third-party application-layer service).

### 2.2 Transport layer — TCP

- Every app↔backend exchange rides in **TCP streams** (HTTPS), requested
  through Dart's `package:http` client on the phones and the Workers runtime
  on the server side. Neither side uses UDP or raw sockets.
- **Connection reuse:** `package:http` pools connections per `http.Client`
  instance; the farmer app keeps one lazy client per session
  (`farmguard_farmer/lib/services/api/http_farmer_api.dart`), so the
  login → events → cameras → images sequence reuses the TCP+TLS session
  instead of re-handshaking per request. The camera app's API client likewise
  uses a single `http.Client` for both JSON calls and raw-byte image uploads
  (`farmguard_camera/lib/services/api_client.dart`).
- **Why application-level retry exists alongside TCP:** TCP guarantees
  reliable delivery *only between endpoints of an established connection*.
  It cannot cover: the phone losing Wi-Fi mid-request (connection dies),
  the server answering 5xx (TCP delivered it — the *request* still failed),
  rate-limit 429, or a request that reached the server but whose response
  was lost. Hence the camera's upload queue classifies failures itself:
  network errors, 5xx and 429 → **transient** (retry with backoff); other
  4xx → **permanent** (`api_client.dart` `TransientUploadException` /
  `PermanentUploadException`).
- **Idempotency on reconnect:** because a retry may hit a server that already
  stored the event (the first attempt's response was lost), every alert
  carries a client-generated UUIDv4 as `id`, used as the D1 primary key with
  `ON CONFLICT (id) DO NOTHING`. A true duplicate answers
  `200 {event, duplicate:true}` — success from the queue's point of view —
  and **never triggers a second push**
  (`src/routes/alerts.ts`). This is exactly the "at-least-once delivery +
  idempotent receiver" pattern from the reliability lecture, implemented for
  real.

### 2.3 Network layer — IP routing

The phone's packets are routed from the farm's private network through the
ISP to a Cloudflare anycast edge address; replies route back. Two
network-layer realities worth naming in a viva:

- **NAT:** the farm's Wi-Fi router NATs the phone's private IP (e.g.
  192.168.x.x) onto the ISP's public IP. All FarmGuard traffic is
  client-initiated (phones always dial out; the backend never dials the
  phone), so no port forwarding is needed. The one "server→phone" channel —
  push — is actually the phone's own long-lived connection to Google's FCM
  infrastructure, again outbound-initiated.
- **The camera heartbeat as reachability evidence:** the camera POSTs
  `/api/v1/cameras/:id/heartbeat` every 60 s while monitoring
  (`home_screen.dart`, `_heartbeatInterval = Duration(seconds: 60)`); the
  Worker stamps `last_seen_at` (`src/routes/cameras.ts`). Absence of
  heartbeats is the only "camera offline" signal — a classic property of
  stateless IP: the network itself keeps no per-camera state.

### 2.4 Data link + physical — the typical farm path (described honestly)

This is the generic deployment path, not something the code controls:

1. **Phone A's Wi-Fi radio** (802.11n/ac) ↔ **farm router** — data link
   frames addressed by MAC, WPA2/WPA3 encryption at this hop. Farm buildings
   often mean weak signal; this hop is the most likely real-world failure
   point, which is exactly what the offline-queue scenarios in the demo guide
   exercise.
2. **Router ↔ ISP uplink** — typically wired (Ethernet/fiber) or LTE/4G
   backhaul; the source IP becomes the ISP's public address via NAT.
3. **ISP → Cloudflare edge** — routed across the public Internet to the
   anycast edge.

The apps cannot see any of this; they only see the socket. The demo's
"Wi-Fi off / Wi-Fi on" scenario is the physical+data-link layer failing and
the layers above recovering.

### 2.5 TLS — where it really sits (and where it doesn't)

Precisely stated, because this is a common exam trap:

- **HTTPS = HTTP running over a TLS-secured TCP connection.** TLS is its own
  protocol layer sitting between TCP and the application protocol — it is
  **not** "the OSI presentation layer", and it is not part of HTTP. The
  application code in this project never encrypts anything itself: it writes
  plaintext HTTP (headers, JSON, even raw JPEG bytes), and the TLS record
  layer underneath encrypts and authenticates *everything* — URLs' path,
  headers, bodies — before it touches the wire. (Note: the hostname does
  leak via DNS + the TLS SNI extension; the request path does not.)
- **Certificate validation:** on the first handshake the phone receives the
  server's certificate chain for `*.workers.dev` and validates it against
  trusted CAs (Android system trust store) plus hostname match. This is what
  stops a man-in-the-middle on the farm's Wi-Fi from impersonating
  `https://farmguard-backend.yashsb-75.workers.dev`. The Dart HTTP stack and the Workers runtime both do this
  by default; the project adds no custom pinning.
- **Handshake in brief:** client hello (supported ciphers, key share) →
  server hello + certificate chain → key agreement (ECDHE, so sessions get
  forward secrecy) → both sides derive the same symmetric session keys →
  **record layer**: every subsequent byte is encrypted with those symmetric
  keys and covered by AEAD integrity checks. Token exchange, pairing codes,
  alert JSON, and image bytes all ride inside those encrypted records.
- **One hop TLS does not cover:** Worker → D1/R2 is Cloudflare-internal; the
  Worker → FCM and Worker → OAuth calls are separate HTTPS connections with
  their own TLS sessions. And TLS protects the *channel* — it says nothing
  about *who* is authorized, which is why the system also needs the Bearer
  token layer (§6).

---

## 3. Request/response walkthroughs (the real flows)

All four flows below are the implemented behavior, step by step.

### 3.1 Pairing redemption (two parties, one code)

```
Farmer (in-app "Pair a camera" button      Backend                     Phone A (camera app)
        in the farmer app, or curl)                                       │
        │  POST /api/v1/pairing/code      │                            │
        ├────────────────────────────────▶│  generate 6-digit code     │
        │◀────────────────────────────────┤  store SHA-256 hash only   │
        │  201 {code:"483920",            │  expires_at = now+5 min    │
        │       expires_at:"…"}           │                            │
        │        (code typed into Phone A's dialog)                    │
        │                                 │   POST /api/v1/pairing/redeem
        │                                 │   {code, device_identifier,│
        │                                 │    camera_name, location?} │
        │                                 │◀───────────────────────────┤
        │                                 │  1. global rate limit      │
        │                                 │     (20 / 10 min per IP &  │
        │                                 │      per device) — BEFORE  │
        │                                 │     any code lookup        │
        │                                 │  2. hash lookup            │
        │                                 │  3. atomic single-use claim:│
        │                                 │     UPDATE pairing_codes   │
        │                                 │     SET consumed_at=?      │
        │                                 │     WHERE id=? AND         │
        │                                 │     consumed_at IS NULL    │
        │                                 │     AND expires_at > ?     │
        │                                 │     → winner decided by the│
        │                                 │     affected-row count     │
        │                                 │  4. INSERT cameras row     │
        │                                 │  5. sign 30d camera token  │
        │                                 ├───────────────────────────▶│
        │                                 │  201 {token, camera}       │
        │                                 │  token → secure storage    │
        │                                 │  (Android Keystore)        │
```

What makes this a *networked* coordination problem: two actors who never talk
to each other directly share a secret through the server; the server must
enforce single use **atomically** — the code comment in
`src/routes/pairing.ts` explains that the `UPDATE … WHERE consumed_at IS
NULL` affected-row count decides the winner of a concurrent redemption race.
The 6-digit space is small, so the defense-in-depth stack matters: global
per-IP and per-device limiters in D1 (`rate_limit_windows`, keys stored
SHA-256-hashed) run *before* any code lookup, so a brute-forcer spraying
random codes learns nothing.

### 3.2 Detection upload (camera → Worker), image first, metadata second

```
Phone A upload queue                                     Backend
   │ (event confirmed; snapshot captured via capturePhoto) │
   │ 1. persist event JSON + JPEG locally (atomic write)   │
   │ 2. POST /api/v1/images                                │
   │    Content-Type: image/jpeg                           │
   │    Authorization: Bearer <camera token>               │
   │    body: raw JPEG bytes (no JSON envelope)            │
   ├──────────────────────────────────────────────────────▶│ verify token + camera row exists;
   │                                                       │ Content-Type image/jpeg (params tolerated);
   │                                                       │ 1 B ≤ size ≤ 8 MiB else 400/413;
   │                                                       │ key = events/<UTC yyyy-MM>/<uuid>.jpg
   │                                                       │ IMAGES.put(key, bytes)
   │◀──────────────────────────────────────────────────────┤ 201 {object_key}
   │ 3. persist object_key BEFORE the alert POST (crash    │
   │    between the two → retry never re-uploads the image)│
   │ 4. POST /api/v1/alerts                                │
   │    Authorization: Bearer <camera token>               │
   ├──────────────────────────────────────────────────────▶│ INSERT … ON CONFLICT(id) DO NOTHING
   │                                                       │ RETURNING id  (idempotency)
   │                                                       │ farmer_id from the TOKEN (never the body)
   │                                                       │ source_type forced 'LIVE'
   │                                                       │ [new event] → FCM fan-out (flow 3.4)
   │◀──────────────────────────────────────────────────────┤ 201 {event}   (or 200 {event, duplicate:true})
   │ 5. server confirmed → delete local copies             │
```

Representative alert body (from `farmguard_camera/lib/services/api_client.dart`
`_alertBody`; box is normalized 0..1, exactly one box entry — the triggering
frame's best person detection):

```json
{
  "id": "6f1c2a48-9f3e-4c22-8b1a-2e5d90c4f7aa",
  "confidence": 0.83,
  "bounding_box": [{"left": 0.31, "top": 0.22, "width": 0.25, "height": 0.61}],
  "image_object_key": "events/2026-11/9d2f…e1.jpg",
  "image_content_type": "image/jpeg",
  "image_size": 143206,
  "detected_at": "2026-11-18T22:41:07.512Z"
}
```

And the response event (server adds ownership and timestamps):

```json
{ "ok": true, "data": { "event": {
  "id": "6f1c2a48-…", "farmer_id": "…", "camera_id": "…",
  "detection_type": "person", "confidence": 0.83,
  "image_object_key": "events/2026-11/9d2f…e1.jpg",
  "image_content_type": "image/jpeg", "image_size": 143206,
  "bounding_box": [{"left": 0.31, "top": 0.22, "width": 0.25, "height": 0.61}],
  "source_type": "LIVE", "detected_at": "2026-11-18T22:41:07.512Z",
  "created_at": "2026-11-18T22:41:08.1Z", "viewed_at": null,
  "idempotency_key": "6f1c2a48-…" }, "duplicate": false } }
```

The two-request split is a deliberate ordering choice: image first, because
the alert references the image by key — the metadata row is only useful once
its image exists (and if the image is permanently rejected — 413/400 — the
camera drops the image and still uploads the metadata: imageless events are
first-class).

### 3.3 Farmer fetch sequence (Phone B reads)

```
Phone B                                        Backend
  │ GET /api/v1/alerts?limit=20                     │
  │ Authorization: Bearer <farmer token 12h>        │
  ├────────────────────────────────────────────────▶│ scope: WHERE farmer_id = ?
  │                                                 │ ORDER BY created_at DESC LIMIT 21
  │                                                 │ (one extra row → is there a next page?)
  │◀────────────────────────────────────────────────┤ 200 {events:[…20], next_before:"<ts>"|null}
  │ GET /api/v1/alerts/<eventId>                    │   (on tap / detail open)
  ├────────────────────────────────────────────────▶│ JOIN cameras for name/location
  │◀────────────────────────────────────────────────┤ 200 {event, camera:{id,name,location}}
  │ PATCH /api/v1/alerts/<eventId>/viewed           │   (fire-and-forget on detail open)
  ├────────────────────────────────────────────────▶│ UPDATE … WHERE viewed_at IS NULL (idempotent)
  │◀────────────────────────────────────────────────┤ 200 {event, updated:true|false}
  │ GET /api/v1/images/<eventId>                    │   (detail screen renders the frame)
  ├────────────────────────────────────────────────▶│ own-scope check; R2.get(object_key)
  │◀────────────────────────────────────────────────┤ 200 raw bytes
  │   content-type: image/jpeg                      │
  │   cache-control: private, no-store              │
```

Notes that connect to course topics:

- **Keyset pagination** (`before` = last seen `created_at`, strict `<`):
  offset pagination breaks when rows are inserted while paging (pages skip or
  repeat); keyset pagination stays correct — relevant whenever new LIVE
  events land while the farmer scrolls History
  (`src/routes/alerts.ts` `handleListAlerts`).
- **`Cache-Control: private, no-store`** on image responses: correctness over
  speed — the event list may be stale after a delete/unpair, and re-fetching
  costs one request. An HTTP cache would be a *correctness* hazard here
  (deleted images resurfacing), so the app also keeps only a tiny in-process
  LRU of 12 frames (`farmguard_farmer/lib/data/repositories/event_repository.dart`).
- **Ownership scoping everywhere:** every farmer query filters by
  `farmer_id`, and a foreign id answers 404 — indistinguishable from
  nonexistent — so the API never confirms that a resource exists
  (`alerts.ts`, `images.ts`, `cameras.ts`).

### 3.4 Push sequence (Worker → FCM → Phone B)

```
[inside the alert POST handling, only for a NEW event]
Worker                                         Google OAuth          FCM                   Phone B
  │ fetch push_devices rows for the farmer          │                │                     │
  │ for each device:                                │                │                     │
  │  1. build RS256 JWT (iss=client_email,          │                │                     │
  │     scope=firebase.messaging, exp=3600 s)       │                │                     │
  │  2. POST token_uri  grant_type=jwt-bearer ─────▶│ verify sig     │                     │
  │◀────────────────────────────────────────────────┤                │                     │
  │  access_token (cached ~50 min: 1 h − 60 s       │                │                     │
  │  margin; refreshed on 401)                      │                │                     │
  │  3. POST /v1/projects/<projectId>/messages:send ────────────────▶│ route by            │
  │  { message: { token, notification:{title, body},│                │ fcm_token           │
  │             data:{event_id, camera_id} } }      │                ├────────────────────▶│ system tray:
  │◀────────────────────────────────────────────────┤◀───────────────────── (own long-lived    │
  │  2xx → 'sent'; 404/410/UNREGISTERED → delete    │                │ Google connection)  │ "Person detected
  │  dead device row; other errors → warn & ignore  │                │                     │  on your farm"
```

The notification content, exactly as implemented (`src/services/fcm.ts`):

- JWT scope sent to OAuth: `https://www.googleapis.com/auth/firebase.messaging`
  (shorthand `firebase.messaging` in the diagram above); JWT lifetime
  `exp − iat` = 3600 s; access token cached with a 60 s expiry margin and
  refreshed on a 401 retry.

- `title`: `Person detected on your farm`
- `body`: `<camera_name> · <detected_at as UTC "YYYY-MM-DD HH:MM UTC">`
- `data`: `{event_id, camera_id}` — the tap deep link the farmer app resolves
  via `GET /api/v1/alerts/:id`

Architecture point: the Worker holds the service-account **private key** as a
Wrangler secret; phones hold only their FCM token. Nobody but the Worker can
send pushes that look like they come from this project — the RS256 JWT is
signed with a key that never leaves the secret store.

---

## 4. Reliability

### 4.1 Why TCP guarantees are not enough

| Failure | TCP's answer | FarmGuard's answer |
|---------|--------------|--------------------|
| Packet loss/corruption | retransmission, checksums — invisible to the app | — |
| Wi-Fi drops mid-request | connection reset | queue classifies `network` → transient → retry later (`api_client.dart`) |
| Server 5xx / 429 | TCP delivered the error just fine | transient → retry with backoff |
| Response lost after server stored the event | connection error, outcome unknown | **idempotency**: same UUID → `200 {event, duplicate:true}`, no double push, no double row |
| App killed mid-upload | connection dies | event persisted locally first; queue restored on next launch, object key already cached → no re-upload of image bytes |
| Ambiguous partial state (image uploaded, alert not) | — | object key persisted **before** the alert POST; alert retry uses the cached key (`upload_queue.dart` + `api_client.dart`) |

### 4.2 Exponential backoff with jitter — exact constants

From `farmguard_camera/lib/config/detection_config.dart` and
`upload_queue.dart` (`_backoffDelay`):

| Parameter | Value |
|-----------|-------|
| Processing timer | every 5 s (`start(interval: Duration(seconds: 5))`) |
| Max attempts per event | 8 |
| First retry delay | 1500 ms |
| Multiplier | 2.0 (delayₙ = 1500 ms × 2ⁿ, zero-based) |
| Cap | 60 s before jitter |
| Jitter | actual delay × (1 + 0.5 × random()), i.e. up to +50 % |

Why jitter: if a farm's router reboots, every queued event would otherwise
retry on the same beat and hammer the recovering server in lockstep
(thundering herd); randomizing each delay by up to +50 % desynchronizes the
retries. After 8 attempts the event is marked **permanently failed but kept**
(displayed as "N failed — kept on this device" with a manual **Retry now**
button, `cloud_status_card.dart`) — nothing is deleted silently.

### 4.3 Queue persistence across restarts

`FilePendingEventStore` writes one `<eventId>.json` (+ optional `.jpg`) per
event under `<appDocuments>/farmguard/pending/`, atomically (temp file +
rename), tolerating corrupt files by skipping them
(`file_pending_store.dart`). On app start `UploadQueue.restore()` reloads
them; an event persisted without a schedule is made due immediately so a
restart cannot strand it (`upload_queue.dart`).

---

## 5. Latency & throughput measurement (during the demo)

Nothing below has been measured yet — this is the measurement *plan* tied to
the demo guide's scenarios.

| Metric | How to measure | Where it shows |
|--------|----------------|----------------|
| On-device inference latency | The camera app's own stats bar shows smoothed per-frame processing ms and FPS (`detection_stats_bar.dart`) | Phone A screen, live |
| End-to-end upload latency | adb logcat with timestamps, or note wall-clock between event confirmation and the cloud card's "Last sync: Just now" | Phone A |
| Push latency | Wall-clock between "Last sync" on Phone A and the notification arriving on Phone B (Phone B backgrounded) | Both phones |
| Server response time (objective baseline) | `curl -w` timing against the deployed URL, e.g. `curl -o /dev/null -s -w 'dns:%{time_namelookup} tcp:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer} total:%{time_total}\n' https://farmguard-backend.yashsb-75.workers.dev/api/health` | Laptop |
| Alert POST (with image) timing | Same `curl -w` on a scripted alert POST, or read `time_starttransfer` which bundles TLS + server processing | Laptop |

Expected shape of the numbers (stated as design expectations, **not**
results): on-device inference dominates per-frame cost and the 15 FPS
streaming cap exists to keep the UI thread responsive — results are delivered
to Flutter at most 15×/s (`YOLOStreamingConfig.throttled(maxFPS: 15)`,
`home_screen.dart`) while the native analyzer runs at its own cadence. The
detection *window* (3-of-5 frames) adds confirmation latency too: an event
cannot confirm before 3 qualifying frames have been processed, so the delay
is ≥ 3 frame periods (≈ 0.2 s at the 15 results/s cap, more if the device's
processing rate is lower). Cloud RTT to a Cloudflare edge is typically tens
of ms on broadband; the 60 s margin in the FCM token cache and the inline
`await` of the push (documented as "the camera client tolerates ~200 ms",
`src/routes/alerts.ts`) show the server-side budget the design assumed.

`curl -w` breakdown is itself a networks lesson: `time_namelookup` is DNS,
`time_connect` is TCP, `time_appconnect` is the TLS handshake, and the gap
between `appconnect` and `starttransfer` is server processing + first byte —
the same layer stack as §2, visible in timestamps.

---

## 6. Security summary (mapped to the course)

| Control | Implementation | Course concept |
|---------|----------------|----------------|
| Encryption in transit | Every hop HTTPS/TLS (phones↔Worker, Worker↔FCM/OAuth) | TLS layer between TCP and application |
| Authentication | Bearer tokens: HMAC-SHA256 signed `base64url(payload).base64url(sig)`; farmer `{sub, typ:'farmer', exp}` 12 h, camera `{sub, cid, typ:'camera', exp}` 30 d (`README.md` auth design) | Shared-secret authentication at application layer |
| Authorization split by token type | Camera-only routes reject farmer tokens with **403**; invalid/expired tokens get **401** (`src/middleware/auth.ts` semantics described in README) | Authentication ≠ authorization |
| Password storage | PBKDF2-SHA256, 100 000 iterations, 16-byte salt, 32-byte key; constant-time compare; login 401 identical whether the email exists | Password hashing, timing side-channels |
| Ownership scoping | Every farmer query filters `farmer_id`; foreign ids → 404 (existence never leaked) | Principle of least privilege; information leakage |
| Rate limiting | Pairing redemption 20 / 10 min per IP **and** per device, checked before code lookup, counters in D1 (not isolate memory — Workers isolates are ephemeral/multi-instance); per-code 5-attempt counter; alert/JSON bodies capped 256 KB; images 1 B–8 MiB | DoS resistance; brute-force defense |
| Single-use secrets | Pairing code stored only as SHA-256 hash, atomically consumed, reuse answers the same 404 as unknown | Password/OTP storage, TOCTOU/races |
| Private storage | R2 bucket never public, no presigned URLs, object keys random UUIDs living only in D1; images streamed only through authenticated, ownership-checked GET with `Cache-Control: private, no-store` | Access control on data at rest |
| Client-side secret hygiene | Phones hold only their own Bearer token (camera token in Android Keystore via flutter_secure_storage); the FCM service-account key and `AUTH_SECRET` exist only as Worker secrets; no credentials in clients or repo | Trust boundaries, key management |
| Data minimisation | Presence-only detection (no face recognition / re-identification); stored fields limited to detection metadata + the one photograph; no location beyond the optional camera label | Privacy by design |
| Revocation | Camera token dies instantly on unpair — every camera-auth request re-reads the `cameras` table; dead FCM tokens (404/410/UNREGISTERED) are deleted server-side | Token lifecycle |

---

## 7. Honest limitations

Stated plainly, each traceable to code or README:

1. **Single-account scale.** One farmer account, a handful of cameras — no
   pagination tuning beyond the 1–50 limit, no multi-tenant load handling.
   Rate limits protect the pairing route only; alert flood control is a
   client-side cooldown (30 s), not a server-side cap.
2. **Orphaned uploads.** An image POSTed to `/api/v1/images` but never
   referenced by an alert is never deleted today; likewise an image whose R2
   delete fails after its event is deleted (warn-logged, row still removed).
   Cleanup options are documented but intentionally unimplemented
   (`farmguard-backend/README.md`, *Orphan-image retention*).
3. **No farmer account deletion.** Unpairing a camera wipes its data fully,
   but there is no authenticated "delete my account" path
   (backend README, *Account / device revocation*).
4. **Foreground push handling is minimal.** In-foreground FCM messages are
   intentionally ignored; only taps (background resumption / cold start) are
   routed (`farmguard_farmer/README.md`, *Tap routing*). Foreground banners
   and data-only background handling are future work.
5. **Settings toggles are placeholders.** The farmer app's four notification
   switches (person-detection alerts, camera-offline alerts, daily summary,
   quiet hours) are local state only — none is wired to the backend
   (`settings_screen.dart`).
6. **Pairing-code UI is new and untested on hardware.** The farmer app's
   "Pair a camera" button (`pairing_code_dialog.dart`) and the full pairing
   flow have passed automated tests but not yet a real two-phone run.
7. **Manual thermal/memory observation.** Long-session memory and device
   temperature during continuous monitoring have no instrumentation in the
   app; observing them is a manual step during the demo.
8. **Physical two-phone verification in progress.** The backend is deployed and
   smoke-tested via curl (health, auth, pairing-code issue, redeem, `/cameras/me`,
   heartbeat, soft-unpair, 401 checks), and automated test counts
   (backend 104, camera 153, farmer 98 = **355 automated tests**)
   prove logic under fakes. The demo guide exists precisely because live camera
   detection, cloud upload, and push delivery require hardware verification.
