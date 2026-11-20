// Detection-event (alert) routes: token-type enforcement, idempotency,
// ownership scoping, validation, viewed marking, and keyset pagination.

import { describe, expect, it } from 'vitest';
import {
  api,
  insertEvent,
  pairCamera,
  readEnvelope,
  registerFarmer,
  testEnv,
} from './helpers';

function alertBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: crypto.randomUUID(),
    confidence: 0.87,
    bounding_box: [{ left: 0.1, top: 0.2, width: 0.3, height: 0.4 }],
    image_object_key: null,
    image_content_type: null,
    image_size: null,
    detected_at: new Date().toISOString(),
    ...overrides,
  };
}

describe('POST /api/v1/alerts', () => {
  it('stores an event from a camera token and returns it (201)', async () => {
    const farmer = await registerFarmer('alert-ok@example.com');
    const cam = await pairCamera(farmer.token, 'alert-ok');
    const body = alertBody();

    const res = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      body,
    });
    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{
      event: {
        id: string;
        farmer_id: string;
        camera_id: string;
        source_type: string;
        detection_type: string;
        bounding_box: Array<unknown> | null;
      };
    }>(res);
    expect(data!.event.id).toBe(body['id']);
    expect(data!.event.farmer_id).toBe(farmer.farmerId);
    expect(data!.event.camera_id).toBe(cam.cameraId);
    expect(data!.event.source_type).toBe('LIVE');
    expect(data!.event.detection_type).toBe('person');
    expect(data!.event.bounding_box).toEqual([{ left: 0.1, top: 0.2, width: 0.3, height: 0.4 }]);
  });

  it('rejects a farmer token with 403', async () => {
    const farmer = await registerFarmer('alert-farmer-token@example.com');
    const res = await api('POST', '/api/v1/alerts', {
      token: farmer.token,
      body: alertBody(),
    });
    expect(res.status).toBe(403);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('forbidden');
  });

  it('is idempotent: the same client id twice → one row, duplicate:true', async () => {
    const farmer = await registerFarmer('alert-idem@example.com');
    const cam = await pairCamera(farmer.token, 'alert-idem');
    const eventId = crypto.randomUUID();
    const body = alertBody({ id: eventId });

    const first = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body });
    expect(first.status).toBe(201);
    const firstData = await readEnvelope<{ duplicate?: boolean }>(first);
    expect(firstData.data?.duplicate).toBeUndefined();

    const second = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      body: alertBody({ id: eventId, confidence: 0.5 }), // different payload, same id
    });
    expect(second.status).toBe(200);
    const secondData = await readEnvelope<{ duplicate?: boolean; event: { confidence: number } }>(second);
    expect(secondData.data?.duplicate).toBe(true);
    // The originally stored event wins.
    expect(secondData.data?.event.confidence).toBe(0.87);

    const count = await testEnv.DB.prepare(
      'SELECT COUNT(*) AS n FROM detection_events WHERE id = ?',
    )
      .bind(body['id'])
      .first<{ n: number }>();
    expect(count!.n).toBe(1);
  });

  it('validates fields: confidence range, missing id, bad uuid, bad bbox, bad detected_at', async () => {
    const farmer = await registerFarmer('alert-valid@example.com');
    const cam = await pairCamera(farmer.token, 'alert-valid');

    const cases: Array<[Record<string, unknown>, string]> = [
      [alertBody({ confidence: 1.5 }), 'confidence > 1'],
      [alertBody({ confidence: -0.1 }), 'confidence < 0'],
      [alertBody({ id: 'not-a-uuid' }), 'bad uuid'],
      [{ confidence: 0.5, detected_at: new Date().toISOString() }, 'missing id'],
      [alertBody({ bounding_box: [{ left: 1.5, top: 0, width: 0.1, height: 0.1 }] }), 'bbox out of range'],
      [alertBody({ bounding_box: 'not-an-array' }), 'bbox not array'],
      [alertBody({ bounding_box: [1, 2, 3, 4, 5, 6] }), 'too many boxes'],
      [alertBody({ detected_at: 'not-a-date' }), 'bad detected_at'],
      [alertBody({ image_size: -5 }), 'negative image_size'],
      [{ id: crypto.randomUUID() }, 'missing confidence'],
    ];

    for (const [body, label] of cases) {
      const res = await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body });
      expect(res.status, label).toBe(400);
      const { error } = await readEnvelope(res);
      expect(error?.code, label).toBe('validation_error');
    }
  });

  it('rejects malformed JSON with 400 invalid_json', async () => {
    const farmer = await registerFarmer('alert-json@example.com');
    const cam = await pairCamera(farmer.token, 'alert-json');
    const res = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      rawBody: '{id: not json}',
    });
    expect(res.status).toBe(400);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('invalid_json');
  });

  it('rejects an oversized body with 413', async () => {
    const farmer = await registerFarmer('alert-big@example.com');
    const cam = await pairCamera(farmer.token, 'alert-big');
    const res = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      body: alertBody({ image_content_type: 'x'.repeat(300 * 1024) }),
    });
    expect(res.status).toBe(413);
  });
});

describe('GET /api/v1/alerts', () => {
  it('returns only the farmer\'s own events, newest first, with next_before', async () => {
    const farmerA = await registerFarmer('alerts-list-a@example.com');
    const farmerB = await registerFarmer('alerts-list-b@example.com');
    const camA = await pairCamera(farmerA.token, 'list-a');
    const camB = await pairCamera(farmerB.token, 'list-b');

    const base = Date.parse('2026-11-18T10:00:00.000Z');
    await insertEvent({
      farmerId: farmerA.farmerId,
      cameraId: camA.cameraId,
      id: crypto.randomUUID(),
      createdAt: new Date(base).toISOString(),
    });
    await insertEvent({
      farmerId: farmerA.farmerId,
      cameraId: camA.cameraId,
      id: crypto.randomUUID(),
      createdAt: new Date(base + 60_000).toISOString(),
    });
    await insertEvent({
      farmerId: farmerA.farmerId,
      cameraId: camA.cameraId,
      id: crypto.randomUUID(),
      createdAt: new Date(base + 120_000).toISOString(),
    });
    await insertEvent({
      farmerId: farmerB.farmerId,
      cameraId: camB.cameraId,
      id: crypto.randomUUID(),
      createdAt: new Date(base + 180_000).toISOString(),
    });

    const res = await api('GET', '/api/v1/alerts?limit=2', { token: farmerA.token });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{
      events: Array<{ created_at: string }>;
      next_before: string | null;
    }>(res);
    expect(data!.events.length).toBe(2);
    expect(data!.events[0]!.created_at).toBe(new Date(base + 120_000).toISOString());
    expect(data!.events[1]!.created_at).toBe(new Date(base + 60_000).toISOString());
    expect(data!.next_before).toBe(new Date(base + 60_000).toISOString());

    // Second page via the cursor.
    const page2 = await api(
      `GET`,
      `/api/v1/alerts?limit=2&before=${encodeURIComponent(data!.next_before!)}`,
      { token: farmerA.token },
    );
    const page2Data = await readEnvelope<{
      events: Array<{ created_at: string }>;
      next_before: string | null;
    }>(page2);
    expect(page2Data.data!.events.length).toBe(1);
    expect(page2Data.data!.events[0]!.created_at).toBe(new Date(base).toISOString());
    expect(page2Data.data!.next_before).toBeNull();
  });

  it('supports the camera_id filter', async () => {
    const farmer = await registerFarmer('alerts-filter@example.com');
    const cam1 = await pairCamera(farmer.token, 'filter-1');
    const cam2 = await pairCamera(farmer.token, 'filter-2');

    await insertEvent({
      farmerId: farmer.farmerId,
      cameraId: cam1.cameraId,
      id: crypto.randomUUID(),
      createdAt: '2026-11-18T09:00:00.000Z',
    });
    await insertEvent({
      farmerId: farmer.farmerId,
      cameraId: cam2.cameraId,
      id: crypto.randomUUID(),
      createdAt: '2026-11-18T09:01:00.000Z',
    });

    const res = await api('GET', `/api/v1/alerts?camera_id=${cam1.cameraId}`, {
      token: farmer.token,
    });
    const { data } = await readEnvelope<{ events: Array<{ camera_id: string }> }>(res);
    expect(data!.events.length).toBe(1);
    expect(data!.events[0]!.camera_id).toBe(cam1.cameraId);
  });

  it('rejects an out-of-range limit and a bad before with 400', async () => {
    const farmer = await registerFarmer('alerts-params@example.com');
    const badLimit = await api('GET', '/api/v1/alerts?limit=99', { token: farmer.token });
    expect(badLimit.status).toBe(400);
    const badBefore = await api('GET', '/api/v1/alerts?before=yesterday', {
      token: farmer.token,
    });
    expect(badBefore.status).toBe(400);
  });

  it('rejects a camera token with 403', async () => {
    const farmer = await registerFarmer('alerts-camtoken@example.com');
    const cam = await pairCamera(farmer.token, 'camtoken');
    const res = await api('GET', '/api/v1/alerts', { token: cam.cameraToken });
    expect(res.status).toBe(403);
  });
});

describe('GET /api/v1/alerts/:id', () => {
  it('returns the event with its camera, or 404 for another farmer', async () => {
    const farmerA = await registerFarmer('alert-get-a@example.com');
    const farmerB = await registerFarmer('alert-get-b@example.com');
    const cam = await pairCamera(farmerA.token, 'get-cam');

    const createRes = await api('POST', '/api/v1/alerts', {
      token: cam.cameraToken,
      body: alertBody(),
    });
    const { data: created } = await readEnvelope<{ event: { id: string } }>(createRes);

    const ok = await api('GET', `/api/v1/alerts/${created!.event.id}`, {
      token: farmerA.token,
    });
    expect(ok.status).toBe(200);
    const okData = await readEnvelope<{
      event: { id: string };
      camera: { id: string; name: string; location: string };
    }>(ok);
    expect(okData.data!.event.id).toBe(created!.event.id);
    expect(okData.data!.camera.id).toBe(cam.cameraId);

    const foreign = await api('GET', `/api/v1/alerts/${created!.event.id}`, {
      token: farmerB.token,
    });
    expect(foreign.status).toBe(404);
  });
});

describe('PATCH /api/v1/alerts/:id/viewed', () => {
  it('marks viewed_at once and is idempotent', async () => {
    const farmer = await registerFarmer('alert-viewed@example.com');
    const cam = await pairCamera(farmer.token, 'viewed-cam');
    const body = alertBody();
    await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body });

    const first = await api('PATCH', `/api/v1/alerts/${body['id']}/viewed`, {
      token: farmer.token,
    });
    expect(first.status).toBe(200);
    const firstData = await readEnvelope<{ event: { viewed_at: string | null } }>(first);
    expect(firstData.data!.event.viewed_at).not.toBeNull();

    const second = await api('PATCH', `/api/v1/alerts/${body['id']}/viewed`, {
      token: farmer.token,
    });
    expect(second.status).toBe(200);
    const secondData = await readEnvelope<{ event: { viewed_at: string | null } }>(second);
    expect(secondData.data!.event.viewed_at).toBe(firstData.data!.event.viewed_at);
  });

  it('answers 404 for another farmer\'s event', async () => {
    const farmerA = await registerFarmer('alert-viewed-a@example.com');
    const farmerB = await registerFarmer('alert-viewed-b@example.com');
    const cam = await pairCamera(farmerA.token, 'viewed-cam-b');
    const body = alertBody();
    await api('POST', '/api/v1/alerts', { token: cam.cameraToken, body });

    const res = await api('PATCH', `/api/v1/alerts/${body['id']}/viewed`, {
      token: farmerB.token,
    });
    expect(res.status).toBe(404);
  });
});
