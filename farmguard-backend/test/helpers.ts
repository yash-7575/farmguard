// Shared test helpers: every test file gets fresh (isolated) DB storage from
// the vitest plugin, so fixtures are created per file via the real HTTP API.
import { SELF } from 'cloudflare:test';
import { env } from 'cloudflare:workers';
import { Env } from '../src/types/env';

export const testEnv = env as unknown as Env;

export interface ApiEnvelope<T> {
  ok: boolean;
  data?: T;
  error?: { code: string; message: string };
}

export const BASE = 'https://example.com';

export async function api(
  method: string,
  path: string,
  options: {
    body?: unknown;
    token?: string;
    rawBody?: string;
    /** Raw binary request body (image uploads) — sent as-is. */
    binaryBody?: Uint8Array;
    /** Content-Type header to send (only meaningful with binaryBody). */
    contentType?: string;
    /** Extra headers (e.g. cf-connecting-ip for rate-limit tests). */
    headers?: Record<string, string>;
  } = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    ...(options.headers ?? {}),
  };
  if (options.token) headers['authorization'] = `Bearer ${options.token}`;
  let body: string | BodyInit | undefined;
  if (options.binaryBody !== undefined) {
    // Uint8Array<ArrayBufferLike> vs BodyInit's ArrayBufferView<ArrayBuffer>:
    // copy into a plain ArrayBuffer-backed view (fetch sends it as-is).
    body = new Uint8Array(options.binaryBody).slice().buffer as ArrayBuffer;
    if (options.contentType !== undefined) {
      headers['content-type'] = options.contentType;
    }
  } else if (options.rawBody !== undefined) {
    body = options.rawBody;
    headers['content-type'] = 'application/json';
  } else if (options.body !== undefined) {
    body = JSON.stringify(options.body);
    headers['content-type'] = 'application/json';
  }
  return SELF.fetch(`${BASE}${path}`, {
    method,
    headers,
    body,
  });
}

export async function readEnvelope<T>(response: Response): Promise<ApiEnvelope<T>> {
  return (await response.json()) as ApiEnvelope<T>;
}

export interface FarmerFixture {
  farmerId: string;
  token: string;
  email: string;
}

export async function registerFarmer(
  email: string,
  name = 'Test Farmer',
  password = 'test-password-123',
): Promise<FarmerFixture> {
  const res = await api('POST', '/api/v1/auth/register', {
    body: { name, email, password },
  });
  if (res.status !== 201) {
    throw new Error(`registerFarmer failed: ${res.status} ${await res.text()}`);
  }
  const { data } = await readEnvelope<{
    token: string;
    farmer: { id: string; name: string; email: string };
  }>(res);
  return { farmerId: data!.farmer.id, token: data!.token, email };
}

export interface CameraFixture {
  cameraId: string;
  cameraToken: string;
  deviceIdentifier: string;
}

/** Pairs a camera to the farmer through the real pairing flow. */
export async function pairCamera(
  farmerToken: string,
  suffix: string,
): Promise<CameraFixture> {
  const codeRes = await api('POST', '/api/v1/pairing/code', {
    token: farmerToken,
  });
  if (codeRes.status !== 201) {
    throw new Error(`pairing code failed: ${codeRes.status}`);
  }
  const { data: codeData } = await readEnvelope<{ code: string }>(codeRes);
  const redeemRes = await api('POST', '/api/v1/pairing/redeem', {
    body: {
      code: codeData!.code,
      device_identifier: `device-${suffix}`,
      camera_name: `Camera ${suffix}`,
      location: 'Bengaluru',
    },
  });
  if (redeemRes.status !== 201) {
    throw new Error(`redeem failed: ${redeemRes.status} ${await redeemRes.text()}`);
  }
  const { data } = await readEnvelope<{
    token: string;
    camera: { id: string };
  }>(redeemRes);
  return {
    cameraId: data!.camera.id,
    cameraToken: data!.token,
    deviceIdentifier: `device-${suffix}`,
  };
}

/** Inserts a detection event directly (deterministic created_at for pagination tests). */
export async function insertEvent(options: {
  farmerId: string;
  cameraId: string;
  id: string;
  createdAt: string;
  confidence?: number;
}): Promise<void> {
  await testEnv.DB.prepare(
    `INSERT INTO detection_events
       (id, farmer_id, camera_id, detection_type, confidence, image_object_key,
        image_content_type, image_size, bounding_box, source_type, detected_at,
        created_at, viewed_at, idempotency_key)
     VALUES (?, ?, ?, 'person', ?, NULL, NULL, NULL, NULL, 'LIVE', ?, ?, NULL, ?)`,
  )
    .bind(
      options.id,
      options.farmerId,
      options.cameraId,
      options.confidence ?? 0.9,
      options.createdAt,
      options.createdAt,
      options.id,
    )
    .run();
}
