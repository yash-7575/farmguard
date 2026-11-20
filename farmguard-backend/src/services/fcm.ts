/**
 * Firebase Cloud Messaging (HTTP v1) push notifications (Stage 7).
 *
 * Implemented with Web Crypto only — the Firebase Admin SDK is incompatible
 * with the Workers runtime, so the service-account OAuth flow is done by hand:
 *
 *   1. Build a RS256 JWT signed with the service account's PKCS#8 private key
 *      (Web Crypto: importKey('pkcs8') + RSASSA-PKCS1-v1_5 / SHA-256).
 *   2. Exchange it at the service account's `token_uri` for an access token
 *      (grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer).
 *   3. POST the notification to
 *      https://fcm.googleapis.com/v1/projects/<projectId>/messages:send with
 *      `Authorization: Bearer <access_token>`.
 *
 * The access token is cached in module state (~50 min effective life; the
 * 1h token minus a 60s safety margin) and refreshed on a 401.
 *
 * Error contract: NOTHING in this module ever throws outward. Every failure
 * is logged at warn/info level (never logging secret content) and mapped to a
 * `FcmSendResult`:
 *   - 'sent'          → 2xx from FCM
 *   - 'invalid_token' → 404/410/UNREGISTERED (the FCM token is dead → caller
 *                       deletes the device row)
 *   - 'error'         → anything else (auth failure, 5xx, network, bad config)
 *   - 'skipped'       → FCM_SERVICE_ACCOUNT not configured (feature off)
 *
 * Test seam: the two outbound HTTP calls go through an injectable `fetchFn`
 * (parameter defaulting to the module transport, which defaults to global
 * fetch). Tests additionally use `setFcmTransportForTests` so the fake
 * transport applies when the send is triggered from a real route through
 * SELF.fetch. vitest runs each file in its own isolate, so the module state
 * stays per-file.
 */
import { Env } from '../types/env';

const FCM_SEND_ENDPOINT = 'https://fcm.googleapis.com/v1/projects';
const DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token';
const MESSAGING_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const JWT_LIFETIME_SECONDS = 3600;
/** Refresh the cached access token this long before its real expiry. */
const TOKEN_EXPIRY_MARGIN_MS = 60_000;

export type FcmSendResult = 'sent' | 'invalid_token' | 'error' | 'skipped';

export interface FcmNotificationPayload {
  title: string;
  body: string;
  /** FCM requires string values; `{event_id, camera_id}` for the tap deep link. */
  data: Record<string, string>;
}

/** Minimal event fields needed to build a notification. */
export interface FcmEventLike {
  id: string;
  farmer_id: string;
  camera_id: string;
  detected_at: string;
}

interface ServiceAccountJson {
  client_email: string;
  private_key: string;
  token_uri?: string;
  project_id?: string;
}

// ---------------------------------------------------------------------------
// Module state (token cache + test seam)
// ---------------------------------------------------------------------------

let cachedAccessToken: { token: string; expiresAtMs: number } | null = null;

interface FcmTestOverrides {
  fetchFn?: typeof fetch;
  /** Override (or explicitly null out) the service-account JSON for tests. */
  serviceAccountJson?: string | null;
}

let testOverrides: FcmTestOverrides | null = null;

/** Installs test-only transport/config overrides (never called in production). */
export function setFcmTransportForTests(overrides: FcmTestOverrides): void {
  testOverrides = overrides;
}

/** Clears the test seam AND the cached access token. */
export function resetFcmTransportForTests(): void {
  testOverrides = null;
  cachedAccessToken = null;
}

function resolveFetch(fetchFn?: typeof fetch): typeof fetch {
  return fetchFn ?? testOverrides?.fetchFn ?? fetch;
}

function resolveRawServiceAccount(
  env: Pick<Env, 'FCM_SERVICE_ACCOUNT'>,
): string | null {
  if (testOverrides && testOverrides.serviceAccountJson !== undefined) {
    return testOverrides.serviceAccountJson;
  }
  return env.FCM_SERVICE_ACCOUNT ?? null;
}

function parseServiceAccount(raw: string): ServiceAccountJson | null {
  try {
    const parsed = JSON.parse(raw) as Partial<ServiceAccountJson> | null;
    if (
      parsed &&
      typeof parsed.client_email === 'string' &&
      typeof parsed.private_key === 'string'
    ) {
      return {
        client_email: parsed.client_email,
        private_key: parsed.private_key,
        token_uri: parsed.token_uri,
        project_id: parsed.project_id,
      };
    }
    return null;
  } catch {
    return null;
  }
}

/** project_id field, else the Firebase default suffix of the client_email. */
export function resolveProjectId(sa: ServiceAccountJson): string | null {
  if (sa.project_id) return sa.project_id;
  const at = sa.client_email.indexOf('@');
  if (at > 0) {
    const domain = sa.client_email.slice(at + 1);
    const dot = domain.indexOf('.');
    if (dot > 0) return domain.slice(0, dot);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Encoding helpers (Web Crypto only)
// ---------------------------------------------------------------------------

/** '-----BEGIN PRIVATE KEY-----' PEM → raw PKCS#8 bytes. */
export function pemToBytes(pem: string): Uint8Array {
  const base64 = pem
    .replace(/-----BEGIN [^-]+-----/, '')
    .replace(/-----END [^-]+-----/, '')
    .replace(/\s+/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function toBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const encoder = new TextEncoder();

export interface JwtParts {
  header: Record<string, unknown>;
  claims: Record<string, unknown>;
  signature: Uint8Array;
}

/** Builds the RS256 JWT the OAuth endpoint expects (exported for unit tests). */
export async function buildServiceAccountJwt(
  sa: ServiceAccountJson,
): Promise<{ jwt: string; parts: JwtParts }> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: sa.client_email,
    scope: MESSAGING_SCOPE,
    aud: sa.token_uri ?? DEFAULT_TOKEN_URI,
    iat: now,
    exp: now + JWT_LIFETIME_SECONDS,
  };
  const encodedHeader = toBase64Url(encoder.encode(JSON.stringify(header)));
  const encodedClaims = toBase64Url(encoder.encode(JSON.stringify(claims)));
  const signingInput = `${encodedHeader}.${encodedClaims}`;

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToBytes(sa.private_key) as BufferSource,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      key,
      encoder.encode(signingInput) as BufferSource,
    ),
  );
  return {
    jwt: `${signingInput}.${toBase64Url(signature)}`,
    parts: { header, claims, signature },
  };
}

// ---------------------------------------------------------------------------
// OAuth access token (cached in module state)
// ---------------------------------------------------------------------------

async function getAccessToken(
  sa: ServiceAccountJson,
  fetchFn: typeof fetch,
): Promise<string | null> {
  const nowMs = Date.now();
  if (cachedAccessToken && cachedAccessToken.expiresAtMs > nowMs + TOKEN_EXPIRY_MARGIN_MS) {
    return cachedAccessToken.token;
  }
  try {
    const { jwt } = await buildServiceAccountJwt(sa);
    const grantType = 'urn:ietf:params:oauth:grant-type:jwt-bearer';
    const response = await fetchFn(sa.token_uri ?? DEFAULT_TOKEN_URI, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: `grant_type=${encodeURIComponent(grantType)}&assertion=${encodeURIComponent(jwt)}`,
    });
    if (!response.ok) {
      cachedAccessToken = null;
      console.warn('FCM token exchange failed with HTTP', response.status);
      return null;
    }
    const json = (await response.json()) as { access_token?: unknown; expires_in?: unknown };
    if (typeof json.access_token !== 'string' || json.access_token.length === 0) {
      cachedAccessToken = null;
      console.warn('FCM token exchange returned no access_token');
      return null;
    }
    const expiresIn = Number(json.expires_in) || JWT_LIFETIME_SECONDS;
    cachedAccessToken = {
      token: json.access_token,
      expiresAtMs: nowMs + Math.max(60, expiresIn) * 1000,
    };
    return json.access_token;
  } catch (error) {
    cachedAccessToken = null;
    console.warn('FCM token exchange failed:', error instanceof Error ? error.message : error);
    return null;
  }
}

// ---------------------------------------------------------------------------
// FCM send (HTTP v1)
// ---------------------------------------------------------------------------

/**
 * Sends one notification to one FCM token. Never throws.
 * `fetchFn` is injectable for tests (defaults to the module transport).
 */
export async function sendFcmNotification(
  env: Pick<Env, 'FCM_SERVICE_ACCOUNT'>,
  payload: FcmNotificationPayload,
  fcmToken: string,
  fetchFn?: typeof fetch,
): Promise<FcmSendResult> {
  try {
    const raw = resolveRawServiceAccount(env);
    if (raw === null) return 'skipped';
    const sa = parseServiceAccount(raw);
    if (!sa) {
      console.warn('FCM_SERVICE_ACCOUNT is set but is not valid service-account JSON');
      return 'error';
    }
    const projectId = resolveProjectId(sa);
    if (!projectId) {
      console.warn('FCM service account has no resolvable project id');
      return 'error';
    }

    const fetchImpl = resolveFetch(fetchFn);
    const sendOnce = (accessToken: string): Promise<Response> =>
      fetchImpl(
        `${FCM_SEND_ENDPOINT}/${encodeURIComponent(projectId)}/messages:send`,
        {
          method: 'POST',
          headers: {
            authorization: `Bearer ${accessToken}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            message: {
              token: fcmToken,
              notification: { title: payload.title, body: payload.body },
              data: payload.data,
            },
          }),
        },
      );

    let accessToken = await getAccessToken(sa, fetchImpl);
    if (!accessToken) return 'error';
    let response = await sendOnce(accessToken);

    // The cached token may be revoked/expired on Google's side → refresh
    // once and retry before giving up.
    if (response.status === 401) {
      cachedAccessToken = null;
      accessToken = await getAccessToken(sa, fetchImpl);
      if (!accessToken) return 'error';
      response = await sendOnce(accessToken);
    }

    if (response.ok) return 'sent';
    if (response.status === 404 || response.status === 410) return 'invalid_token';
    // FCM also reports dead tokens as 400 with status UNREGISTERED.
    const bodyText = await response.text().catch(() => '');
    if (bodyText.includes('UNREGISTERED')) return 'invalid_token';
    console.warn('FCM send failed with HTTP', response.status);
    return 'error';
  } catch (error) {
    console.warn('FCM send failed:', error instanceof Error ? error.message : error);
    return 'error';
  }
}

// ---------------------------------------------------------------------------
// Farmer notification fan-out
// ---------------------------------------------------------------------------

/** detected_at ISO string → '2026-11-18 22:41 UTC' (UTC, no locale guessing). */
export function formatDetectedAtUtc(isoTimestamp: string): string {
  const date = new Date(isoTimestamp);
  if (Number.isNaN(date.getTime())) return isoTimestamp;
  const pad = (value: number): string => String(value).padStart(2, '0');
  return (
    `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}` +
    ` ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())} UTC`
  );
}

/**
 * Sends one push per registered device of the event's farmer. Deletes
 * invalid-token device rows, swallows every failure, returns the count of
 * devices that were sent a notification (0 when not configured/no devices).
 */
export async function notifyFarmerOfEvent(
  env: Env,
  event: FcmEventLike,
  cameraName: string,
): Promise<number> {
  if (resolveRawServiceAccount(env) === null) {
    console.info('FCM not configured');
    return 0;
  }
  try {
    const { results } = await env.DB.prepare(
      'SELECT id, fcm_token FROM push_devices WHERE farmer_id = ?',
    )
      .bind(event.farmer_id)
      .all<{ id: string; fcm_token: string }>();
    const devices = results ?? [];
    if (devices.length === 0) return 0;

    const payload: FcmNotificationPayload = {
      title: 'Person detected on your farm',
      body: `${cameraName} · ${formatDetectedAtUtc(event.detected_at)}`,
      data: { event_id: event.id, camera_id: event.camera_id },
    };

    let sent = 0;
    for (const device of devices) {
      const result = await sendFcmNotification(env, payload, device.fcm_token);
      if (result === 'sent') {
        sent++;
      } else if (result === 'invalid_token') {
        // Dead FCM token → remove the device row (re-register repairs it).
        await env.DB.prepare('DELETE FROM push_devices WHERE id = ?')
          .bind(device.id)
          .run();
      }
    }
    return sent;
  } catch (error) {
    console.warn('FCM notification failed:', error instanceof Error ? error.message : error);
    return 0;
  }
}
