// Image routes (Stage 4): private R2 storage via the Worker-authenticated
// proxy. Covers the upload descriptor, the raw-binary camera upload
// (content type, size limits, key format, R2 round-trip) and the
// farmer-facing GET (ownership scoping, bytes, cache header).

import { describe, expect, it } from 'vitest';
import {
  api,
  pairCamera,
  readEnvelope,
  registerFarmer,
  testEnv,
} from './helpers';

/** A tiny valid-looking JPEG payload — the routes don't sniff magic bytes. */
function fakeJpeg(size = 64): Uint8Array {
  const bytes = new Uint8Array(size);
  bytes[0] = 0xff;
  bytes[1] = 0xd8; // SOI marker
  bytes[size - 2] = 0xff;
  bytes[size - 1] = 0xd9; // EOI marker
  for (let i = 2; i < size - 2; i++) bytes[i] = i % 251;
  return bytes;
}

/** Uploads an image through the real camera flow, returns the object key. */
async function uploadImage(cameraToken: string): Promise<string> {
  const res = await api('POST', '/api/v1/images', {
    token: cameraToken,
    binaryBody: fakeJpeg(),
    contentType: 'image/jpeg',
  });
  if (res.status !== 201) {
    throw new Error(`uploadImage failed: ${res.status} ${await res.text()}`);
  }
  const { data } = await readEnvelope<{ object_key: string }>(res);
  return data!.object_key;
}

describe('POST /api/v1/images/upload-url', () => {
  it('returns the direct-upload descriptor for a camera token', async () => {
    const farmer = await registerFarmer('img-descriptor@example.com');
    const cam = await pairCamera(farmer.token, 'img-descriptor');

    const res = await api('POST', '/api/v1/images/upload-url', {
      token: cam.cameraToken,
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{
      upload_url: string;
      method: string;
      max_size_bytes: number;
      allowed_content_types: string[];
    }>(res);
    expect(data!.upload_url).toBe('/api/v1/images');
    expect(data!.method).toBe('POST');
    expect(data!.max_size_bytes).toBe(8 * 1024 * 1024);
    expect(data!.allowed_content_types).toEqual(['image/jpeg']);
  });

  it('rejects a farmer token with 403', async () => {
    const farmer = await registerFarmer('img-descriptor-f@example.com');
    const res = await api('POST', '/api/v1/images/upload-url', {
      token: farmer.token,
    });
    expect(res.status).toBe(403);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('forbidden');
  });
});

describe('POST /api/v1/images', () => {
  it('stores the bytes in R2 and returns a unique, non-guessable key (201)', async () => {
    const farmer = await registerFarmer('img-upload@example.com');
    const cam = await pairCamera(farmer.token, 'img-upload');
    const payload = fakeJpeg();

    const res = await api('POST', '/api/v1/images', {
      token: cam.cameraToken,
      binaryBody: payload,
      contentType: 'image/jpeg',
    });
    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{ object_key: string }>(res);
    expect(data!.object_key).toMatch(/^events\/\d{4}-\d{2}\/[0-9a-f-]{36}\.jpg$/);

    // Round-trip: the exact bytes are retrievable from the binding, with the
    // JPEG content type recorded as R2 httpMetadata.
    const object = await testEnv.IMAGES.get(data!.object_key);
    expect(object).not.toBeNull();
    const stored = new Uint8Array(await object!.arrayBuffer());
    expect(stored).toEqual(payload);
    expect(object!.httpMetadata?.contentType).toBe('image/jpeg');
  });

  it('generates distinct keys for repeated uploads', async () => {
    const farmer = await registerFarmer('img-unique@example.com');
    const cam = await pairCamera(farmer.token, 'img-unique');
    const key1 = await uploadImage(cam.cameraToken);
    const key2 = await uploadImage(cam.cameraToken);
    expect(key1).not.toBe(key2);
  });

  it('accepts Content-Type with parameters (image/jpeg; charset=binary)', async () => {
    const farmer = await registerFarmer('img-charset@example.com');
    const cam = await pairCamera(farmer.token, 'img-charset');
    const res = await api('POST', '/api/v1/images', {
      token: cam.cameraToken,
      binaryBody: fakeJpeg(),
      contentType: 'image/jpeg; charset=binary',
    });
    expect(res.status).toBe(201);
  });

  it('rejects a wrong content type with 400 invalid_content_type', async () => {
    const farmer = await registerFarmer('img-ctype@example.com');
    const cam = await pairCamera(farmer.token, 'img-ctype');
    for (const contentType of ['image/png', 'text/plain', 'application/json']) {
      const res = await api('POST', '/api/v1/images', {
        token: cam.cameraToken,
        binaryBody: fakeJpeg(),
        contentType,
      });
      expect(res.status, contentType).toBe(400);
      const { error } = await readEnvelope(res);
      expect(error?.code, contentType).toBe('invalid_content_type');
    }
  });

  it('rejects an oversized body with 413 payload_too_large', async () => {
    const farmer = await registerFarmer('img-big@example.com');
    const cam = await pairCamera(farmer.token, 'img-big');
    const big = new Uint8Array(8 * 1024 * 1024 + 1);
    const res = await api('POST', '/api/v1/images', {
      token: cam.cameraToken,
      binaryBody: big,
      contentType: 'image/jpeg',
    });
    expect(res.status).toBe(413);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('payload_too_large');
  });

  it('accepts a body of exactly 8 MiB (boundary)', async () => {
    const farmer = await registerFarmer('img-exact@example.com');
    const cam = await pairCamera(farmer.token, 'img-exact');
    const exact = fakeJpeg(8 * 1024 * 1024);
    const res = await api('POST', '/api/v1/images', {
      token: cam.cameraToken,
      binaryBody: exact,
      contentType: 'image/jpeg',
    });
    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{ object_key: string }>(res);
    const object = await testEnv.IMAGES.get(data!.object_key);
    const stored = new Uint8Array(await object!.arrayBuffer());
    expect(stored.byteLength).toBe(8 * 1024 * 1024);
  });

  it('rejects an empty body with 400', async () => {
    const farmer = await registerFarmer('img-empty@example.com');
    const cam = await pairCamera(farmer.token, 'img-empty');
    const res = await api('POST', '/api/v1/images', {
      token: cam.cameraToken,
      binaryBody: new Uint8Array(0),
      contentType: 'image/jpeg',
    });
    expect(res.status).toBe(400);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('validation_error');
  });

  it('rejects a farmer token with 403', async () => {
    const farmer = await registerFarmer('img-farmer@example.com');
    const res = await api('POST', '/api/v1/images', {
      token: farmer.token,
      binaryBody: fakeJpeg(),
      contentType: 'image/jpeg',
    });
    expect(res.status).toBe(403);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('forbidden');
  });

  it('rejects a missing token with 401', async () => {
    const res = await api('POST', '/api/v1/images', {
      binaryBody: fakeJpeg(),
      contentType: 'image/jpeg',
    });
    expect(res.status).toBe(401);
  });
});

describe('GET /api/v1/images/:eventId', () => {
  /** Registers farmer, pairs camera, uploads an image, creates its event. */
  async function seedEventWithImage(
    email: string,
    suffix: string,
  ): Promise<{ farmerToken: string; eventId: string; objectKey: string }> {
    const farmer = await registerFarmer(email);
    const cam = await pairCamera(farmer.token, suffix);
    const objectKey = await uploadImage(cam.cameraToken);
    const eventId = crypto.randomUUID();
    const res = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      body: {
        id: eventId,
        confidence: 0.91,
        image_object_key: objectKey,
        image_content_type: 'image/jpeg',
        image_size: 64,
        detected_at: new Date().toISOString(),
      },
    });
    if (res.status !== 201) {
      throw new Error(`seedEventWithImage alert failed: ${res.status} ${await res.text()}`);
    }
    return { farmerToken: farmer.token, eventId, objectKey };
  }

  it('returns the exact bytes with content type and private cache header', async () => {
    const seeded = await seedEventWithImage('img-get@example.com', 'img-get');

    const res = await api(
      'GET',
      `/api/v1/images/${seeded.eventId}`,
      { token: seeded.farmerToken },
    );
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('image/jpeg');
    expect(res.headers.get('cache-control')).toBe('private, no-store');
    const bytes = new Uint8Array(await res.arrayBuffer());
    const stored = await testEnv.IMAGES.get(seeded.objectKey);
    const expected = new Uint8Array(await stored!.arrayBuffer());
    expect(bytes).toEqual(expected);
  });

  it('answers 404 no_image for an event without an image', async () => {
    const farmer = await registerFarmer('img-noimage@example.com');
    const cam = await pairCamera(farmer.token, 'img-noimage');
    const eventId = crypto.randomUUID();
    const createRes = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      body: {
        id: eventId,
        confidence: 0.5,
        detected_at: new Date().toISOString(),
      },
    });
    expect(createRes.status).toBe(201);

    const res = await api('GET', `/api/v1/images/${eventId}`, {
      token: farmer.token,
    });
    expect(res.status).toBe(404);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('no_image');
  });

  it('answers 404 for another farmer\'s event (never leaks existence)', async () => {
    const seededA = await seedEventWithImage('img-get-a@example.com', 'img-get-a');
    const farmerB = await registerFarmer('img-get-b@example.com');

    const res = await api(
      'GET',
      `/api/v1/images/${seededA.eventId}`,
      { token: farmerB.token },
    );
    expect(res.status).toBe(404);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('no_image');
  });

  it('answers 404 for an unknown event id', async () => {
    const farmer = await registerFarmer('img-unknown@example.com');
    const res = await api('GET', `/api/v1/images/${crypto.randomUUID()}`, {
      token: farmer.token,
    });
    expect(res.status).toBe(404);
  });

  it('rejects a camera token with 403', async () => {
    const farmer = await registerFarmer('img-camtoken@example.com');
    const cam = await pairCamera(farmer.token, 'img-camtoken');
    const res = await api('GET', `/api/v1/images/${crypto.randomUUID()}`, {
      token: cam.cameraToken,
    });
    expect(res.status).toBe(403);
  });
});
