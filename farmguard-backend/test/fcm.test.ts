// Stage 7: FCM push notifications for confirmed LIVE detection events.
//
// Route-level tests drive the real POST /api/v1/alerts flow through SELF.fetch
// with a fake FCM transport installed via the module test seam
// (setFcmTransportForTests). Unit tests exercise the OAuth/JWT plumbing
// directly with an injected fetchFn.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  api,
  pairCamera,
  readEnvelope,
  registerFarmer,
  testEnv,
  type CameraFixture,
  type FarmerFixture,
} from './helpers';
import {
  buildServiceAccountJwt,
  resetFcmTransportForTests,
  sendFcmNotification,
  setFcmTransportForTests,
} from '../src/services/fcm';

// --- fixtures --------------------------------------------------------------

/**
 * Generates a throwaway RSA PKCS#8 private key PEM in the Workers runtime for
 * the fake service-account JSON. Not a real credential — exists only for this
 * test file and is regenerated every run.
 */
async function generateTestPrivateKeyPem(): Promise<string> {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', keyPair.privateKey);
  let base64 = '';
  const bytes = new Uint8Array(pkcs8);
  for (const byte of bytes) base64 += String.fromCharCode(byte);
  const wrapped = (btoa(base64).match(/.{1,64}/g) ?? []).join('\n');
  return `-----BEGIN PRIVATE KEY-----\n${wrapped}\n-----END PRIVATE KEY-----\n`;
}

/** client_email domain suffix → project id 'test-farmguard'. */
const TEST_SERVICE_ACCOUNT = {
  client_email: 'firebase-adminsdk-abc123@test-farmguard.iam.gserviceaccount.com',
  token_uri: 'https://oauth2.googleapis.com/token',
};
const FAKE_ACCESS_TOKEN = 'fake-access-token-xyz';

async function makeTestServiceAccountJson(): Promise<string> {
  const pem = await generateTestPrivateKeyPem();
  return JSON.stringify({ ...TEST_SERVICE_ACCOUNT, private_key: pem });
}

// --- fake FCM transport ----------------------------------------------------

interface RecordedRequest {
  url: string;
  authorization: string | null;
  /** Parsed JSON for send calls, raw string for token calls. */
  body: string;
  status: number;
}

interface FakeHandlers {
  onToken?: (callIndex: number) => { status: number; body?: string };
  /** Decides the response from the parsed send request body. */
  onSend?: (body: Record<string, unknown>, callIndex: number) => { status: number; body?: string };
}

function createFcmFake(handlers: FakeHandlers = {}): {
  fetchFn: typeof fetch;
  tokenCalls: RecordedRequest[];
  sendCalls: RecordedRequest[];
} {
  const tokenCalls: RecordedRequest[] = [];
  const sendCalls: RecordedRequest[] = [];
  const fetchFn = (async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input);
    const authorization = new Headers(init?.headers).get('authorization') ?? null;
    const rawBody = typeof init?.body === 'string' ? init.body : '';
    const respond = (spec: { status: number; body?: string }, record: RecordedRequest): Response => {
      record.status = spec.status;
      return new Response(spec.body ?? '{}', { status: spec.status });
    };

    if (url.includes('/token')) {
      const record: RecordedRequest = { url, authorization, body: rawBody, status: 0 };
      tokenCalls.push(record);
      return respond(handlers.onToken?.(tokenCalls.length - 1) ?? {
        status: 200,
        body: JSON.stringify({ access_token: FAKE_ACCESS_TOKEN, expires_in: 3600 }),
      }, record);
    }

    if (url.includes('/messages:send')) {
      const parsed = JSON.parse(rawBody) as Record<string, unknown>;
      const record: RecordedRequest = { url, authorization, body: rawBody, status: 0 };
      sendCalls.push(record);
      return respond(handlers.onSend?.(parsed, sendCalls.length - 1) ?? { status: 200, body: '{}' }, record);
    }

    return new Response('unexpected URL', { status: 500 });
  }) as typeof fetch;
  return { fetchFn, tokenCalls, sendCalls };
}

// --- seeding ---------------------------------------------------------------

async function seedWithDevices(deviceTokens: string[]): Promise<{
  farmer: FarmerFixture;
  cam: CameraFixture;
}> {
  const farmer = await registerFarmer(`fcm-${crypto.randomUUID().slice(0, 8)}@example.com`);
  const cam = await pairCamera(farmer.token, `fcm-${crypto.randomUUID().slice(0, 8)}`);
  for (const fcmToken of deviceTokens) {
    const res = await api('POST', '/api/v1/notifications/register-device', {
      token: farmer.token,
      body: { fcm_token: fcmToken },
    });
    expect(res.status, 'device registration').toBe(201);
  }
  return { farmer, cam };
}

function alertBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: crypto.randomUUID(),
    confidence: 0.92,
    detected_at: '2026-11-18T17:11:22.000Z',
    ...overrides,
  };
}

async function deviceCount(fcmToken: string): Promise<number> {
  const row = await testEnv.DB.prepare(
    'SELECT COUNT(*) AS n FROM push_devices WHERE fcm_token = ?',
  )
    .bind(fcmToken)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

beforeEach(() => {
  // Clears the seam AND the module token cache so every test starts clean.
  resetFcmTransportForTests();
});
afterEach(() => {
  resetFcmTransportForTests();
});

describe('POST /api/v1/alerts → FCM push fan-out', () => {
  it('sends one notification per registered device with the correct shape', async () => {
    const saJson = await makeTestServiceAccountJson();
    const liveToken = 'fcm-live-token-aaaaaaaaaaaaaaaa-1';
    const otherToken = 'fcm-live-token-aaaaaaaaaaaaaaaa-2';
    const { farmer, cam } = await seedWithDevices([liveToken, otherToken]);
    const fake = createFcmFake();
    setFcmTransportForTests({ fetchFn: fake.fetchFn, serviceAccountJson: saJson });

    const body = alertBody();
    const res = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body });
    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{ event: { id: string } }>(res);

    expect(fake.tokenCalls.length).toBe(1);
    expect(fake.tokenCalls[0]!.authorization).toBeNull();
    // grant_type is the JWT-bearer flow; the assertion is the signed JWT.
    expect(fake.tokenCalls[0]!.body).toContain('grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer');
    expect(fake.tokenCalls[0]!.body).toContain('assertion=');

    expect(fake.sendCalls.length).toBe(2);
    for (const call of fake.sendCalls) {
      expect(call.url).toBe(
        `https://fcm.googleapis.com/v1/projects/test-farmguard/messages:send`,
      );
      expect(call.authorization).toBe(`Bearer ${FAKE_ACCESS_TOKEN}`);
      const message = (JSON.parse(call.body) as { message: Record<string, unknown> }).message;
      expect([liveToken, otherToken]).toContain(message['token']);
      expect(message['notification']).toEqual({
        title: 'Person detected on your farm',
        body: `${cam.deviceIdentifier.replace('device-', 'Camera ')} · 2026-11-18 17:11 UTC`,
      });
      expect(message['data']).toEqual({
        event_id: body['id'],
        camera_id: cam.cameraId,
      });
    }
    // Both device tokens got exactly one send call each.
    expect(fake.sendCalls.map((c) => (JSON.parse(c.body) as { message: { token: string } }).message.token).sort())
      .toEqual([liveToken, otherToken].sort());
    expect(farmer.farmerId).toBeTruthy();
    expect(data!.event.id).toBe(body['id']);
  });

  it('does NOT re-send on an idempotent retry (duplicate:true)', async () => {
    const saJson = await makeTestServiceAccountJson();
    const deviceToken = 'fcm-dup-token-aaaaaaaaaaaaaaaa';
    const { cam } = await seedWithDevices([deviceToken]);
    const fake = createFcmFake();
    setFcmTransportForTests({ fetchFn: fake.fetchFn, serviceAccountJson: saJson });

    const body = alertBody();
    const first = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body });
    expect(first.status).toBe(201);
    expect(fake.sendCalls.length).toBe(1);

    const retry = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      body: alertBody({ id: body['id'] }),
    });
    expect(retry.status).toBe(200);
    const retryData = await readEnvelope<{ duplicate?: boolean }>(retry);
    expect(retryData.data?.duplicate).toBe(true);
    // No additional token exchange or send on the duplicate path.
    expect(fake.sendCalls.length).toBe(1);
    expect(fake.tokenCalls.length).toBe(1);
  });

  it('sends nothing (no error) when the farmer has no registered devices', async () => {
    const saJson = await makeTestServiceAccountJson();
    const { cam } = await seedWithDevices([]);
    const fake = createFcmFake();
    setFcmTransportForTests({ fetchFn: fake.fetchFn, serviceAccountJson: saJson });

    const res = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body: alertBody() });
    expect(res.status).toBe(201);
    expect(fake.tokenCalls.length).toBe(0);
    expect(fake.sendCalls.length).toBe(0);
  });

  it('deletes a device row answered 404 UNREGISTERED, keeps the other', async () => {
    const saJson = await makeTestServiceAccountJson();
    const deadToken = 'fcm-dead-token-aaaaaaaaaaaaaaaa';
    const liveToken = 'fcm-live-token-aaaaaaaaaaaaaaaa-3';
    const { cam } = await seedWithDevices([deadToken, liveToken]);
    const fake = createFcmFake({
      onSend: (parsed) => {
        const token = (parsed['message'] as { token?: string })['token'] ?? '';
        if (token === deadToken) {
          return {
            status: 404,
            body: JSON.stringify({
              error: { code: 404, message: 'Requested entity was not found.', status: 'UNREGISTERED' },
            }),
          };
        }
        return { status: 200, body: '{}' };
      },
    });
    setFcmTransportForTests({ fetchFn: fake.fetchFn, serviceAccountJson: saJson });

    const res = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body: alertBody() });
    expect(res.status).toBe(201);

    expect(fake.sendCalls.length).toBe(2);
    expect(await deviceCount(deadToken)).toBe(0); // deleted
    expect(await deviceCount(liveToken)).toBe(1); // kept
  });

  it('still returns 201 when FCM answers 500', async () => {
    const saJson = await makeTestServiceAccountJson();
    const deviceToken = 'fcm-err-token-aaaaaaaaaaaaaaaa';
    const { cam } = await seedWithDevices([deviceToken]);
    const fake = createFcmFake({ onSend: () => ({ status: 500, body: '{"error":{"status":"INTERNAL"}}' }) });
    setFcmTransportForTests({ fetchFn: fake.fetchFn, serviceAccountJson: saJson });

    const res = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body: alertBody() });
    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{ event: { source_type: string } }>(res);
    expect(data!.event.source_type).toBe('LIVE');
    expect(fake.sendCalls.length).toBe(1);
    expect(await deviceCount(deviceToken)).toBe(1); // 500 must NOT delete the row
  });

  it('skips FCM entirely when FCM_SERVICE_ACCOUNT is absent', async () => {
    const deviceToken = 'fcm-unconf-token-aaaaaaaaaaaaaa';
    const { cam } = await seedWithDevices([deviceToken]);
    const fake = createFcmFake();
    setFcmTransportForTests({ fetchFn: fake.fetchFn, serviceAccountJson: null });

    const res = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body: alertBody() });
    expect(res.status).toBe(201);
    expect(fake.tokenCalls.length).toBe(0);
    expect(fake.sendCalls.length).toBe(0);
    expect(await deviceCount(deviceToken)).toBe(1);
  });
});

describe('FCM service unit tests', () => {
  it('caches the OAuth access token across sends (one token exchange)', async () => {
    const saJson = await makeTestServiceAccountJson();
    const fake = createFcmFake();
    const env = { FCM_SERVICE_ACCOUNT: saJson };
    const payload = { title: 't', body: 'b', data: { event_id: 'e', camera_id: 'c' } };

    const first = await sendFcmNotification(env, payload, 'fcm-unit-token-aaaaaaaaaaaaaaa-1', fake.fetchFn);
    const second = await sendFcmNotification(env, payload, 'fcm-unit-token-aaaaaaaaaaaaaaa-2', fake.fetchFn);

    expect(first).toBe('sent');
    expect(second).toBe('sent');
    expect(fake.tokenCalls.length).toBe(1);
    expect(fake.sendCalls.length).toBe(2);
  });

  it('builds an RS256 service-account JWT with correct header/claims/signature', async () => {
    const pem = await generateTestPrivateKeyPem();
    const sa = {
      client_email: 'svc@test-farmguard.iam.gserviceaccount.com',
      private_key: pem,
      token_uri: 'https://oauth2.googleapis.com/token',
    };
    const { jwt, parts } = await buildServiceAccountJwt(sa);

    const segments = jwt.split('.');
    expect(segments.length).toBe(3);
    const decode = (segment: string): Record<string, unknown> =>
      JSON.parse(atob(segment.replace(/-/g, '+').replace(/_/g, '/'))) as Record<string, unknown>;
    expect(decode(segments[0]!)).toEqual({ alg: 'RS256', typ: 'JWT' });
    const claims = decode(segments[1]!);
    expect(claims['iss']).toBe(sa.client_email);
    expect(claims['scope']).toBe('https://www.googleapis.com/auth/firebase.messaging');
    expect(claims['aud']).toBe(sa.token_uri);
    expect(claims['exp']).toBe((claims['iat'] as number) + 3600);
    // Signature decodes to non-empty bytes (shape only, not cryptographic).
    const sig = atob(segments[2]!.replace(/-/g, '+').replace(/_/g, '/'));
    expect(sig.length).toBeGreaterThan(0);
    expect(parts.signature.length).toBe(sig.length);
  });
});
