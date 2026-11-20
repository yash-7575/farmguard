// Stage 8 + Phase 2A: DELETE routes.
//   - Alert deletion: event row + its R2 image object.
//   - Camera unpairing is now a SOFT unpair: the camera row is kept with
//     unpaired_at set and token_version bumped, so historical detection_events
//     and their R2 images remain readable while the device token dies
//     immediately and the same device_identifier can pair again later.
// Verifies ownership scoping (own else 404, camera token → 403) and
// cross-farmer isolation.

import { describe, expect, it } from 'vitest';
import {
  api,
  pairCamera,
  readEnvelope,
  registerFarmer,
  testEnv,
} from './helpers';

/** Puts a small object directly in R2 and returns its key. */
async function putImage(): Promise<string> {
  const key = `events/2026-11/${crypto.randomUUID()}.jpg`;
  await testEnv.IMAGES.put(key, new Uint8Array([0xff, 0xd8, 0x01, 0xff, 0xd9]), {
    httpMetadata: { contentType: 'image/jpeg' },
  });
  return key;
}

async function objectExists(key: string): Promise<boolean> {
  return (await testEnv.IMAGES.get(key)) !== null;
}

/** Creates an event through the API, optionally pointing at an image. */
async function createEvent(
  cameraToken: string,
  overrides: Record<string, unknown> = {},
): Promise<string> {
  const id = crypto.randomUUID();
  const res = await api('POST', '/api/v1/alerts', {
    token: cameraToken,
    body: {
      id,
      confidence: 0.8,
      detected_at: new Date().toISOString(),
      ...overrides,
    },
  });
  if (res.status !== 201) {
    throw new Error(`createEvent failed: ${res.status} ${await res.text()}`);
  }
  return id;
}

async function eventExists(id: string): Promise<boolean> {
  const row = await testEnv.DB.prepare(
    'SELECT id FROM detection_events WHERE id = ?',
  )
    .bind(id)
    .first<{ id: string }>();
  return row !== null;
}

async function cameraExists(id: string): Promise<boolean> {
  const row = await testEnv.DB.prepare('SELECT id FROM cameras WHERE id = ?')
    .bind(id)
    .first<{ id: string }>();
  return row !== null;
}

describe('DELETE /api/v1/alerts/:id', () => {
  it('owner deletes an event with an image → row gone AND R2 object gone', async () => {
    const farmer = await registerFarmer('del-alert-ok@example.com');
    const cam = await pairCamera(farmer.token, 'del-alert-ok');
    const imageKey = await putImage();
    const eventId = await createEvent(cam.cameraToken, {
      image_object_key: imageKey,
      image_content_type: 'image/jpeg',
      image_size: 5,
    });

    // Round-trip: the object is really there before the delete.
    expect(await objectExists(imageKey)).toBe(true);

    const res = await api('DELETE', `/api/v1/alerts/${eventId}`, {
      token: farmer.token,
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ deleted: boolean }>(res);
    expect(data!.deleted).toBe(true);

    expect(await eventExists(eventId)).toBe(false);
    expect(await objectExists(imageKey)).toBe(false);
  });

  it('a foreign farmer gets 404 (indistinguishable from unknown), row untouched', async () => {
    const farmerA = await registerFarmer('del-alert-a@example.com');
    const farmerB = await registerFarmer('del-alert-b@example.com');
    const camA = await pairCamera(farmerA.token, 'del-alert-a');
    const eventId = await createEvent(camA.cameraToken);

    const res = await api('DELETE', `/api/v1/alerts/${eventId}`, {
      token: farmerB.token,
    });
    expect(res.status).toBe(404);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('not_found');
    expect(await eventExists(eventId)).toBe(true);
  });

  it('a camera token gets 403, row untouched', async () => {
    const farmer = await registerFarmer('del-alert-cam@example.com');
    const cam = await pairCamera(farmer.token, 'del-alert-cam');
    const eventId = await createEvent(cam.cameraToken);

    const res = await api('DELETE', `/api/v1/alerts/${eventId}`, {
      token: cam.cameraToken,
    });
    expect(res.status).toBe(403);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('forbidden');
    expect(await eventExists(eventId)).toBe(true);
  });

  it('an event without an image still deletes (200, no R2 access needed)', async () => {
    const farmer = await registerFarmer('del-alert-noimg@example.com');
    const cam = await pairCamera(farmer.token, 'del-alert-noimg');
    const eventId = await createEvent(cam.cameraToken);

    const res = await api('DELETE', `/api/v1/alerts/${eventId}`, {
      token: farmer.token,
    });
    expect(res.status).toBe(200);
    expect(await eventExists(eventId)).toBe(false);
  });

  it('an unknown event id answers 404', async () => {
    const farmer = await registerFarmer('del-alert-unknown@example.com');
    const res = await api('DELETE', `/api/v1/alerts/${crypto.randomUUID()}`, {
      token: farmer.token,
    });
    expect(res.status).toBe(404);
  });
});

describe('DELETE /api/v1/cameras/:id (soft unpair)', () => {
  it('soft-unpairs: camera hidden, events and R2 images preserved, token dead', async () => {
    const farmerA = await registerFarmer('del-cam-a@example.com');
    const farmerB = await registerFarmer('del-cam-b@example.com'); // isolation witness
    const camA = await pairCamera(farmerA.token, 'del-cam-a');
    const camB = await pairCamera(farmerB.token, 'del-cam-b');

    // Camera A: one event with an image, one without.
    const imageKeyA = await putImage();
    const eventWithImage = await createEvent(camA.cameraToken, {
      image_object_key: imageKeyA,
      image_content_type: 'image/jpeg',
      image_size: 5,
    });
    const eventNoImage = await createEvent(camA.cameraToken);

    // Camera B keeps its own event + image — must be untouched afterwards.
    const imageKeyB = await putImage();
    const eventB = await createEvent(camB.cameraToken, {
      image_object_key: imageKeyB,
      image_content_type: 'image/jpeg',
      image_size: 5,
    });

    expect(await objectExists(imageKeyA)).toBe(true);
    expect(await objectExists(imageKeyB)).toBe(true);

    const res = await api('DELETE', `/api/v1/cameras/${camA.cameraId}`, {
      token: farmerA.token,
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{
      deleted: boolean;
      unpaired: boolean;
      events_preserved: number;
    }>(res);
    expect(data!.deleted).toBe(true);
    expect(data!.unpaired).toBe(true);
    expect(data!.events_preserved).toBe(2);

    // The row is soft-deleted, not removed: historical FKs stay valid.
    expect(await cameraExists(camA.cameraId)).toBe(true);
    const row = await testEnv.DB.prepare(
      'SELECT unpaired_at, status, last_seen_at FROM cameras WHERE id = ?',
    )
      .bind(camA.cameraId)
      .first<{
        unpaired_at: string | null;
        status: string;
        last_seen_at: string | null;
      }>();
    expect(row!.unpaired_at).not.toBeNull();
    expect(row!.status).toBe('offline');
    expect(row!.last_seen_at).toBeNull();

    // Hidden from the farmer's active camera list and detail view.
    const list = await api('GET', '/api/v1/cameras', { token: farmerA.token });
    const { data: listData } = await readEnvelope<{
      cameras: Array<{ id: string }>;
    }>(list);
    expect(listData!.cameras.map((c) => c.id)).not.toContain(camA.cameraId);

    const detail = await api('GET', `/api/v1/cameras/${camA.cameraId}`, {
      token: farmerA.token,
    });
    expect(detail.status).toBe(404);

    // Historical events and their R2 images are PRESERVED.
    expect(await eventExists(eventWithImage)).toBe(true);
    expect(await eventExists(eventNoImage)).toBe(true);
    expect(await objectExists(imageKeyA)).toBe(true);

    // ...and still readable through the farmer-facing APIs.
    const alerts = await api('GET', '/api/v1/alerts', {
      token: farmerA.token,
    });
    expect(alerts.status).toBe(200);
    const { data: alertsData } = await readEnvelope<{
      events: Array<{ id: string }>;
    }>(alerts);
    const alertIds = alertsData!.events.map((e) => e.id);
    expect(alertIds).toContain(eventWithImage);
    expect(alertIds).toContain(eventNoImage);

    const image = await api('GET', `/api/v1/images/${eventWithImage}`, {
      token: farmerA.token,
    });
    expect(image.status).toBe(200);
    expect(image.headers.get('content-type')).toBe('image/jpeg');

    // The device token dies immediately on every camera-authenticated route.
    const heartbeat = await api(
      'POST',
      `/api/v1/cameras/${camA.cameraId}/heartbeat`,
      { token: camA.cameraToken },
    );
    expect(heartbeat.status).toBe(401);

    const alertPost = await api('POST', '/api/v1/alerts', {
      token: camA.cameraToken,
      body: {
        id: crypto.randomUUID(),
        confidence: 0.8,
        detected_at: new Date().toISOString(),
      },
    });
    expect(alertPost.status).toBe(401);

    const imagePost = await api('POST', '/api/v1/images', {
      token: camA.cameraToken,
      binaryBody: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]),
      contentType: 'image/jpeg',
    });
    expect(imagePost.status).toBe(401);

    const me = await api('GET', '/api/v1/cameras/me', {
      token: camA.cameraToken,
    });
    expect(me.status).toBe(401);

    // Farmer B's camera, event and image are untouched.
    expect(await cameraExists(camB.cameraId)).toBe(true);
    expect(await eventExists(eventB)).toBe(true);
    expect(await objectExists(imageKeyB)).toBe(true);
  });

  it('the same device_identifier can pair again and receives working credentials', async () => {
    const farmer = await registerFarmer('del-cam-repair@example.com');
    const first = await pairCamera(farmer.token, 'del-cam-repair');

    const del = await api('DELETE', `/api/v1/cameras/${first.cameraId}`, {
      token: farmer.token,
    });
    expect(del.status).toBe(200);

    const codeRes = await api('POST', '/api/v1/pairing/code', {
      token: farmer.token,
    });
    const { data: codeData } = await readEnvelope<{ code: string }>(codeRes);

    const redeem = await api('POST', '/api/v1/pairing/redeem', {
      body: {
        code: codeData!.code,
        device_identifier: first.deviceIdentifier,
        camera_name: 'Re-paired Camera',
        location: 'West field',
      },
    });
    expect(redeem.status).toBe(201);
    const { data } = await readEnvelope<{
      token: string;
      camera: {
        id: string;
        camera_name: string;
        status: string;
        last_seen_at: string | null;
      };
    }>(redeem);

    // Re-bound to the same physical device (same camera id), offline until
    // its first heartbeat.
    expect(data!.camera.id).toBe(first.cameraId);
    expect(data!.camera.camera_name).toBe('Re-paired Camera');
    expect(data!.camera.status).toBe('offline');
    expect(data!.camera.last_seen_at).toBeNull();

    // The new credentials work...
    const heartbeat = await api(
      'POST',
      `/api/v1/cameras/${first.cameraId}/heartbeat`,
      { token: data!.token, body: {} },
    );
    expect(heartbeat.status).toBe(200);

    // ...and the camera is visible again in the farmer's active list.
    const list = await api('GET', '/api/v1/cameras', { token: farmer.token });
    const { data: listData } = await readEnvelope<{
      cameras: Array<{ id: string }>;
    }>(list);
    expect(listData!.cameras.map((c) => c.id)).toContain(first.cameraId);

    // The pre-unpair token stays revoked.
    const oldToken = await api(
      'POST',
      `/api/v1/cameras/${first.cameraId}/heartbeat`,
      { token: first.cameraToken, body: {} },
    );
    expect(oldToken.status).toBe(401);
  });

  it('a foreign farmer gets 404, camera untouched', async () => {
    const farmerA = await registerFarmer('del-cam-fa@example.com');
    const farmerB = await registerFarmer('del-cam-fb@example.com');
    const camA = await pairCamera(farmerA.token, 'del-cam-fa');

    const res = await api('DELETE', `/api/v1/cameras/${camA.cameraId}`, {
      token: farmerB.token,
    });
    expect(res.status).toBe(404);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('not_found');

    expect(await cameraExists(camA.cameraId)).toBe(true);
    const row = await testEnv.DB.prepare(
      'SELECT unpaired_at FROM cameras WHERE id = ?',
    )
      .bind(camA.cameraId)
      .first<{ unpaired_at: string | null }>();
    expect(row!.unpaired_at).toBeNull();
  });

  it('a camera token gets 403 (cameras must use /cameras/me/unpair)', async () => {
    const farmer = await registerFarmer('del-cam-token@example.com');
    const cam = await pairCamera(farmer.token, 'del-cam-token');

    const res = await api('DELETE', `/api/v1/cameras/${cam.cameraId}`, {
      token: cam.cameraToken,
    });
    expect(res.status).toBe(403);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('forbidden');
    expect(await cameraExists(cam.cameraId)).toBe(true);
  });

  it('an unknown camera id answers 404', async () => {
    const farmer = await registerFarmer('del-cam-unknown@example.com');
    const res = await api('DELETE', `/api/v1/cameras/${crypto.randomUUID()}`, {
      token: farmer.token,
    });
    expect(res.status).toBe(404);
  });
});
