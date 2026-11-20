# farmguard-backend

Cloudflare Worker (TypeScript, plain fetch handler) backing the FarmGuard
two-phone system: receives confirmed person-detection events from the
Camera app, stores event metadata in D1 and photographs in a private R2
bucket, and serves them to the Farmer app. Push notifications are sent
via Firebase Cloud Messaging (HTTP v1).

## Stack

- **Runtime**: Cloudflare Workers (Wrangler 4 config, `wrangler.jsonc`)
- **Language**: TypeScript, strict mode, no framework
- **Database**: Cloudflare D1 (binding `DB`, database `farmguard-db`)
- **Images**: Cloudflare R2, private bucket (binding `IMAGES`, Stage 4)
- **Push**: FCM HTTP v1 via service-account OAuth (Stage 7)
- **Tests**: vitest + `@cloudflare/vitest-plugin` (real workerd via Miniflare)

## Commands

Requires Node.js ≥ 22 (Wrangler 4).

```bash
npm install          # install dependencies
npm run dev          # local dev server (Miniflare) on :8787
npm test             # run Worker tests against Miniflare
npm run typecheck    # strict TypeScript check
wrangler deploy      # production deploy (only with explicit approval)
```

## D1 database & migrations

`wrangler.jsonc` binds D1 as `DB` (`database_name: farmguard-db`,
`migrations_dir: migrations`). Schema lives in
`migrations/0001_initial_schema.sql` — farmers, cameras, detection_events,
push_devices, pairing_codes (all ids TEXT UUIDv4, all timestamps ISO-8601
UTC TEXT) — and `migrations/0002_rate_limit.sql` adds
`rate_limit_windows` (Stage 8, global pairing-redemption limiter).

```bash
# Local (this is what local dev and tests use):
npx wrangler d1 migrations apply farmguard-db --local

# Remote (documented, NOT run yet — a later stage applies this):
npx wrangler d1 migrations apply farmguard-db --remote
```

In tests, migrations are read by `vitest.config.ts`
(`readD1Migrations` from `@cloudflare/vitest-plugin`), injected as a
`TEST_MIGRATIONS` binding, and applied by the `test/apply-migrations.ts`
setup file via `applyD1Migrations()` from `cloudflare:test`.

## Auth design

Two token types, both HMAC-SHA256 signed with `AUTH_SECRET`
(`base64url(payloadJson).base64url(sig)`, Web Crypto only):

- **Farmer token** — payload `{ sub: farmerId, typ: 'farmer', iat, exp }`,
  12h TTL. Issued by `register`/`login`, used by all farmer-app routes.
- **Camera token** — payload `{ sub: cameraId, cid: cameraId, typ: 'camera',
  iat, exp }`, 30d TTL. Issued once at pairing; camera-app routes verify the
  token **and** re-read the camera's owner from D1, so a deleted camera loses
  access immediately.

Passwords are PBKDF2-SHA256 (100 000 iterations, 16-byte salt, 32-byte key)
stored as `pbkdf2-sha256$<iterations>$<salt_b64>$<hash_b64>`; verification
uses a constant-time comparison. Login returns the same 401 envelope
whether the email exists or not. Every protected route validates signature,
expiry, token type (`typ`) and, for cameras, `cid` — a valid token of the
wrong type gets 403, an invalid/expired token gets 401.

`AUTH_SECRET` is a Wrangler secret (`wrangler secret put AUTH_SECRET`);
local dev uses `.dev.vars` (gitignored). It is never committed.

## Image storage design (Stage 4)

Event photographs live in the private R2 bucket `farmguard-images`
(binding `IMAGES` in `wrangler.jsonc`). The bucket must **never** be made
public and no public-access/domain settings may ever be enabled on it —
all image traffic flows through the Worker's authenticated routes:

- **Upload (camera app)** — `POST /api/v1/images/upload-url` (camera
  token) returns an honest direct-upload descriptor
  `{upload_url: '/api/v1/images', method: 'POST', max_size_bytes: 8388608,
  allowed_content_types: ['image/jpeg']}`. It is deliberately **not** a
  presigned S3 URL: the camera then POSTs the raw binary JPEG bytes to
  `POST /api/v1/images` with its camera token. The route reads the body
  directly (no JSON envelope), requires `Content-Type: image/jpeg`
  (parameters like `; charset=…` are tolerated), and enforces a
  1 byte–8 MiB size window (400 `invalid_content_type` / empty body,
  413 `payload_too_large`). Bytes are stored under a non-guessable key
  `events/<UTC yyyy-MM>/<UUIDv4>.jpg` with `image/jpeg` recorded as R2
  httpMetadata, and 201 returns `{object_key}` — the key the camera then
  references in `POST /api/v1/alerts` (`image_object_key`).
- **Retrieval (farmer app)** — `GET /api/v1/images/:eventId` (farmer
  token) selects the event **scoped to the caller's farmer_id** (a
  foreign event answers 404, same as the alert routes, so existence is
  never leaked), streams the object from R2 with the event's stored
  content type (fallback `image/jpeg`) and `Cache-Control: private,
  no-store`. No image → 404 `no_image`.
- **Security properties** — object keys live only in D1 and are never
  exposed as URLs; the mobile apps never receive S3/R2 credentials or
  public links; every byte crosses the Worker through token
  authentication and ownership checks.

### Orphan-image retention

An image uploaded to `POST /api/v1/images` but never referenced by a
detection event (`image_object_key` never attached in
`POST /api/v1/alerts`) is an **orphan**: nothing currently deletes it.
Known clean-up options for a later stage (intentionally not implemented
now): a scheduled Worker that lists `events/<month>/` prefixes older
than N days and deletes keys absent from `detection_events`, or a
reference-counted deletion when events are pruned.

## Push notifications (FCM HTTP v1, Stage 7)

When a **new** confirmed LIVE detection event arrives through
`POST /api/v1/alerts` (source_type is forced server-side to `LIVE`; DEMO
events are never insertable through this route), the Worker sends one
push to every FCM device registered by the owning farmer:

- **Trigger and guards** — only a genuinely new insert fires a push. An
  idempotent retry (same client UUID → `200 {event, duplicate: true}`)
  never re-sends; a farmer with zero registered devices gets no send and
  no error; a failure anywhere in the push path is swallowed and can
  never fail or delay the alert's 201 response.
- **Content** — title `Person detected on your farm`, body
  `<camera_name> · <detected_at formatted as UTC, e.g. 2026-11-18 22:41
  UTC>` (no locale guessing), and a `data` payload
  `{event_id, camera_id}` for the farmer app's tap-to-detail deep link
  (farmer-app side is a separate task).
- **Runtime** — implemented with Web Crypto only (the Firebase Admin SDK
  is incompatible with the Workers runtime): `src/services/fcm.ts`
  builds an RS256 JWT from the service account's PKCS#8 private key,
  exchanges it at `token_uri` for an OAuth access token (cached ~50
  minutes in module state, refreshed on 401), and POSTs to
  `https://fcm.googleapis.com/v1/projects/<projectId>/messages:send`.
  `projectId` comes from the service-account JSON's `project_id`, or is
  derived from the `client_email` domain suffix.
- **Dead-token cleanup** — an FCM answer of 404, 410 or `UNREGISTERED`
  means the device token is permanently invalid; the Worker deletes
  that `push_devices` row so subsequent events don't retry a dead
  token. The device returns automatically when the app re-registers
  (`POST /api/v1/notifications/register-device`). Any other FCM error
  (e.g. 5xx) is logged at warn level and left untouched.

### Production setup (deploy time)

```bash
wrangler secret put FCM_SERVICE_ACCOUNT
# → paste the service-account key JSON:
#   {"client_email": "...", "private_key": "...", "token_uri": "...", "project_id": "..."}
```

The value is the full Firebase service-account key JSON (never committed,
never printed in logs; the Worker only logs `FCM not configured` /
non-secret status lines). For local dev the same JSON string may go into
`.dev.vars` as `FCM_SERVICE_ACCOUNT=<the service-account JSON>` —
`.dev.vars` is gitignored and must never contain a real production value
while the repo is shared. When the secret is unset, the Worker responds
normally to every request and simply skips push (`FCM not configured`
at info level) — the feature is off, not broken.

> **Status: delivery NOT yet verified.** Tests exercise the full flow
> against a fake transport; real end-to-end push delivery (a physical
> device receiving the notification) is deferred to Stage 10 physical
> testing, and the Firebase project config (service-account key creation,
> project id) is still pending.

## Pairing flow

1. Farmer taps "Add camera" → `POST /api/v1/pairing/code` → a 6-digit code
   (crypto-random, no modulo bias) valid for **5 minutes**. Only the
   SHA-256 hex hash of the code is stored.
2. Farmer enters the code in the Camera app.
3. Camera calls `POST /api/v1/pairing/redeem` with
   `{code, device_identifier, camera_name, location?}` → the code is
   consumed **atomically** (`UPDATE … SET consumed_at = ? WHERE …
   consumed_at IS NULL AND expires_at > ?`, decided by the affected-row
   count) and a camera row is created → the camera receives a 30d camera
   token.
4. Guards: unknown code → 404 `not_found`; a consumed code also answers 404
   (reuse is indistinguishable from unknown); expired → 410 `code_expired`
   (counts as a failed attempt); more than 5 failed attempts per code → 429
   `too_many_attempts`; an already-paired `device_identifier` → 409
   `device_already_paired`; and on top of all of these a global rate limit
   (see *Rate limits* below) answers 429 `too_many_requests` before any code
   lookup is made.

## Security & operations (Stage 8)

### Image retention

Events and their images live until the farmer deletes them — there is no
automatic expiry:

- **DELETE `/api/v1/alerts/:id`** removes the event row **and** its R2 image
  object (the image delete is best-effort: a missing or un-deletable object
  never blocks the row deletion).
- **DELETE `/api/v1/cameras/:id`** (unpairing) permanently removes the
  camera, all of its detection events (D1 FK `ON DELETE CASCADE`), and those
  events' R2 image objects — unpairing is a full data wipe for that camera,
  by design (privacy-first: a stolen/resold camera's entire history can be
  destroyed from the farmer app in one action).
- **Orphaned uploads**: an image uploaded to `POST /api/v1/images` but never
  attached to an event (`image_object_key` never referenced in
  `POST /api/v1/alerts`) is never deleted today. Future cleanup options
  (intentionally not implemented yet): a scheduled Worker that lists old
  `events/<month>/` prefixes and deletes keys absent from
  `detection_events`, or reference-counted deletion. The same gap applies to
  an image whose R2 delete failed after its event was deleted (logged at
  warn level, row still removed).

### Token handling

- **Farmer tokens**: 12 h TTL. There is no refresh token — expiry means
  re-login. No server-side token store: revocation of a *farmer* account is
  not implemented (see below).
- **Camera tokens**: 30 d TTL, issued once at pairing. They die instantly on
  unpair — every camera-authenticated request re-reads the `cameras` table,
  so the deleted row makes the very next request answer 401 even though the
  JWT itself is not yet expired. Rotation = unpair + re-pair (no in-place
  token rotation endpoint).
- No server-side token store is needed for either type; the only
  server-side truth is the `cameras` row (existence) and token expiry.

### Account / device revocation

- **Per camera**: unpair (`DELETE /api/v1/cameras/:id`) — full wipe as above;
  re-pair with a fresh code to bring the same physical device back.
- **Farmer account deletion is NOT implemented.** Deleting a farmer's rows
  would cascade cameras/events (FK) but the farmer's R2 objects would need
  the same best-effort sweep unpair performs, and there is no
  authentication way to "delete me" today. Documented limitation; future
  work would add an authenticated account-deletion endpoint that unpair-
  wipes every camera first, then removes the farmer row.

### Rate limits

- **Pairing redemption** (`POST /api/v1/pairing/redeem`): 20 attempts /
  10 minutes per client IP **and** 20 / 10 min per `device_identifier`
  (whichever trips first). Every attempt counts — success and failure
  alike — and the check runs **before** any code lookup, so a saturated
  caller gets 429 `too_many_requests` and learns nothing about code
  validity. Keys are stored SHA-256-hashed (`ip:<addr>`, `dev:<device>`) in
  the `rate_limit_windows` D1 table — D1, not per-isolate memory, because
  Worker isolates are ephemeral and multi-instance. This closes the gap the
  per-code 5-attempt counter cannot: a brute-forcer spraying random 6-digit
  codes never matches a stored row, so only the global counters can see it.
- **Alert POST** (`POST /api/v1/alerts`): request body capped at 256 KB
  (413 beyond that), shared with all JSON endpoints.
- **Images** (`POST /api/v1/images`): raw JPEG body, 1 byte–8 MiB
  (413 beyond that).

### Data minimisation

Privacy-conscious defaults only: the system detects **presence** of a
person, never identity — no face recognition, no person re-identification,
no biometric processing. Stored data is limited to detection metadata
(type, confidence, bounding box, timestamps), the photograph the camera
chose to send, and farmer account fields (name, email, password hash).
No location data beyond the optional, farmer-chosen camera location label.


## API envelope

Every endpoint returns the same JSON shape:

```json
{ "ok": true,  "data": { ... } }
{ "ok": false, "error": { "code": "not_found", "message": "..." } }
```

CORS: `OPTIONS` preflights get 204; all responses carry
`Access-Control-Allow-Origin: *` with `Content-Type`/`Authorization`
allowed for `GET/POST/PATCH/DELETE`. CORS is a browser policy, **not**
authentication. Request bodies are capped at 256 KB (413 beyond that);
the raw image upload (`POST /api/v1/images`) has its own 8 MiB limit.

## Endpoints

| Method | Path | Auth | Description |
| ------ | ---- | ---- | ----------- |
| GET | `/api/health` (alias `/api/v1/health`) | none | Liveness probe |
| POST | `/api/v1/auth/register` | none | Create farmer → 201 `{token, farmer}` (dup email → 409) |
| POST | `/api/v1/auth/login` | none | Login → 200 `{token, farmer}` (wrong creds → 401) |
| GET | `/api/v1/auth/me` | farmer | Current farmer → `{farmer}` |
| POST | `/api/v1/pairing/code` | farmer | Generate 6-digit code → 201 `{code, expires_at}` |
| POST | `/api/v1/pairing/redeem` | camera app | Redeem code, register camera → 201 `{token, camera}` |
| GET | `/api/v1/cameras` | farmer | Own cameras only |
| GET | `/api/v1/cameras/:id` | farmer | Own camera (foreign → 404) |
| POST | `/api/v1/cameras/:id/heartbeat` | camera | Touch `last_seen_at`, status (default `online`) |
| PATCH | `/api/v1/cameras/:id/status` | camera | Set `offline`/`online`/`monitoring` |
| POST | `/api/v1/alerts` | camera only | Idempotent event upload (client UUID id; retry → 200 `{event, duplicate:true}`); new LIVE events fan out one FCM push per registered farmer device |
| GET | `/api/v1/alerts` | farmer | Own events, keyset pagination (`limit` 1–50, `before`, `camera_id`) |
| GET | `/api/v1/alerts/:id` | farmer | Event + its camera |
| PATCH | `/api/v1/alerts/:id/viewed` | farmer | Mark viewed (idempotent) |
| DELETE | `/api/v1/alerts/:id` | farmer | Delete event + its R2 image (own else 404) → `{deleted: true}` |
| DELETE | `/api/v1/cameras/:id` | farmer | Unpair camera: row + cascaded events + their images removed → `{deleted: true, events_removed: n}`; device token dies immediately |
| POST | `/api/v1/notifications/register-device` | farmer | Upsert FCM token (unique per token) |
| DELETE | `/api/v1/notifications/unregister-device` | farmer | Remove FCM token (idempotent) |
| POST | `/api/v1/images/upload-url` | camera | Direct-upload descriptor (`{upload_url, method, max_size_bytes, allowed_content_types}`) |
| POST | `/api/v1/images` | camera only | Raw binary JPEG upload → 201 `{object_key}` (8 MiB max) |
| GET | `/api/v1/images/:eventId` | farmer | Stream the event's image (own events only, foreign → 404) |

## Secrets policy

No secrets live in this repository or in `wrangler.jsonc`. Worker secrets
(`AUTH_SECRET`, `FCM_SERVICE_ACCOUNT`) are set with
`wrangler secret put <NAME>` (remote) or `.dev.vars` (local dev,
gitignored) and are never printed or committed.
