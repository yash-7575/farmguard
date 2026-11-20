// Camera routes: ownership scoping, heartbeat/status updates, token-type
// enforcement, `/me` self-discovery, the 120s online threshold and soft-unpair.

import { describe, expect, it } from 'vitest';
import {
  api,
  pairCamera,
  readEnvelope,
  registerFarmer,
  testEnv,
} from './helpers';
import { ONLINE_THRESHOLD_MS } from '../src/routes/cameras';

describe('GET /api/v1/cameras', () => {
  it('lists only the farmer\'s own cameras', async () => {
    const farmerA = await registerFarmer('cam-a@example.com');
    const farmerB = await registerFarmer('cam-b@example.com');
    const camA = await pairCamera(farmerA.token, 'alpha');
    await pairCamera(farmerA.token, 'alpha-2');
    await pairCamera(farmerB.token, 'beta');

    const res = await api('GET', '/api/v1/cameras', { token: farmerA.token });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ cameras: Array<{ id: string }> }>(res);
    const ids = data!.cameras.map((c) => c.id);
    expect(ids).toContain(camA.cameraId);
    expect(ids.length).toBe(2); // B's camera is invisible to A
  });

  it('requires a farmer token (camera token → 403)', async () => {
    const farmer = await registerFarmer('cam-token@example.com');
    const cam = await pairCamera(farmer.token, 'tok');
    const res = await api('GET', '/api/v1/cameras', { token: cam.cameraToken });
    expect(res.status).toBe(403);
  });
});

describe('GET /api/v1/cameras/:id', () => {
  it('returns the farmer\'s own camera', async () => {
    const farmer = await registerFarmer('cam-get@example.com');
    const cam = await pairCamera(farmer.token, 'get');

    const res = await api('GET', `/api/v1/cameras/${cam.cameraId}`, {
      token: farmer.token,
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{
      camera: { id: string; name: string; camera_name: string };
    }>(res);
    expect(data!.camera.id).toBe(cam.cameraId);
    expect(data!.camera.name).toBe(data!.camera.camera_name);
  });

  it('answers 404 for another farmer\'s camera', async () => {
    const farmerA = await registerFarmer('cam-own-a@example.com');
    const farmerB = await registerFarmer('cam-own-b@example.com');
    const camA = await pairCamera(farmerA.token, 'owned-by-a');

    const res = await api('GET', `/api/v1/cameras/${camA.cameraId}`, {
      token: farmerB.token,
    });
    expect(res.status).toBe(404);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('not_found');
  });
});

describe('POST /api/v1/cameras/:id/heartbeat', () => {
  it('updates last_seen_at and status (default online) with the camera token', async () => {
    const farmer = await registerFarmer('cam-hb@example.com');
    const cam = await pairCamera(farmer.token, 'hb');

    const res = await api('POST', `/api/v1/cameras/${cam.cameraId}/heartbeat`, {
      token: cam.cameraToken,
      body: {},
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ camera: { status: string; last_seen_at: string | null } }>(res);
    expect(data!.camera.status).toBe('online');
    expect(data!.camera.last_seen_at).not.toBeNull();
  });

  it('accepts an explicit body status', async () => {
    const farmer = await registerFarmer('cam-hb2@example.com');
    const cam = await pairCamera(farmer.token, 'hb2');

    const res = await api('POST', `/api/v1/cameras/${cam.cameraId}/heartbeat`, {
      token: cam.cameraToken,
      body: { status: 'monitoring' },
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ camera: { status: string } }>(res);
    expect(data!.camera.status).toBe('monitoring');
  });

  it('rejects a different camera id than the token cid with 403', async () => {
    const farmer = await registerFarmer('cam-hb3@example.com');
    const cam = await pairCamera(farmer.token, 'hb3');
    const other = await pairCamera(farmer.token, 'hb3-other');

    const res = await api('POST', `/api/v1/cameras/${other.cameraId}/heartbeat`, {
      token: cam.cameraToken,
      body: {},
    });
    expect(res.status).toBe(403);
  });
});

describe('PATCH /api/v1/cameras/:id/status', () => {
  it('sets a valid status with the camera token', async () => {
    const farmer = await registerFarmer('cam-st@example.com');
    const cam = await pairCamera(farmer.token, 'st');

    const res = await api('PATCH', `/api/v1/cameras/${cam.cameraId}/status`, {
      token: cam.cameraToken,
      body: { status: 'monitoring' },
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ camera: { status: string } }>(res);
    expect(data!.camera.status).toBe('monitoring');
  });

  it('rejects an invalid status with 400', async () => {
    const farmer = await registerFarmer('cam-st2@example.com');
    const cam = await pairCamera(farmer.token, 'st2');

    const res = await api('PATCH', `/api/v1/cameras/${cam.cameraId}/status`, {
      token: cam.cameraToken,
      body: { status: 'sleeping' },
    });
    expect(res.status).toBe(400);
  });
});

describe('GET /api/v1/cameras/me', () => {
  it('returns the paired camera and the farmer with a masked email', async () => {
    const farmer = await registerFarmer('cam-me@example.com');
    const cam = await pairCamera(farmer.token, 'me');

    const res = await api('GET', '/api/v1/cameras/me', {
      token: cam.cameraToken,
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{
      paired: boolean;
      camera: {
        id: string;
        name: string;
        camera_name: string;
        status: string;
        last_seen_at: string | null;
      };
      farmer: { id: string; name: string; email_masked: string } | null;
    }>(res);

    expect(data!.paired).toBe(true);
    expect(data!.camera.id).toBe(cam.cameraId);
    expect(data!.camera.name).toBe('Camera me');
    expect(data!.camera.name).toBe(data!.camera.camera_name);
    expect(data!.camera.status).toBe('offline');
    expect(data!.camera.last_seen_at).toBeNull();
    expect(data!.farmer).toEqual({
      id: farmer.farmerId,
      name: 'Test Farmer',
      email_masked: 'ca***@example.com',
    });
  });

  it('rejects a farmer token with 403', async () => {
    const farmer = await registerFarmer('cam-me-farmer@example.com');
    const res = await api('GET', '/api/v1/cameras/me', {
      token: farmer.token,
    });
    expect(res.status).toBe(403);
  });

  it('rejects an unpaired camera token with 401', async () => {
    const farmer = await registerFarmer('cam-me-unpaired@example.com');
    const cam = await pairCamera(farmer.token, 'me-unpaired');

    const unpair = await api('POST', '/api/v1/cameras/me/unpair', {
      token: cam.cameraToken,
    });
    expect(unpair.status).toBe(200);

    const res = await api('GET', '/api/v1/cameras/me', {
      token: cam.cameraToken,
    });
    expect(res.status).toBe(401);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('unauthorized');
  });
});

describe('online threshold (120s)', () => {
  it('exports a 120 second threshold', () => {
    expect(ONLINE_THRESHOLD_MS).toBe(120_000);
  });

  it('a newly paired camera is offline', async () => {
    const farmer = await registerFarmer('cam-thresh-new@example.com');
    const cam = await pairCamera(farmer.token, 'thresh-new');

    const res = await api('GET', `/api/v1/cameras/${cam.cameraId}`, {
      token: farmer.token,
    });
    const { data } = await readEnvelope<{ camera: { status: string } }>(res);
    expect(data!.camera.status).toBe('offline');
  });

  it('a fresh heartbeat reports online (or monitoring)', async () => {
    const farmer = await registerFarmer('cam-thresh-hb@example.com');
    const cam = await pairCamera(farmer.token, 'thresh-hb');

    const hb = await api('POST', `/api/v1/cameras/${cam.cameraId}/heartbeat`, {
      token: cam.cameraToken,
      body: {},
    });
    expect(hb.status).toBe(200);
    const { data } = await readEnvelope<{ camera: { status: string } }>(hb);
    expect(['online', 'monitoring']).toContain(data!.camera.status);

    const list = await api('GET', '/api/v1/cameras', { token: farmer.token });
    const { data: listData } = await readEnvelope<{
      cameras: Array<{ id: string; status: string }>;
    }>(list);
    const listed = listData!.cameras.find((c) => c.id === cam.cameraId);
    expect(listed!.status).toBe('online');
  });

  it('a stale last_seen_at (3 minutes ago) reports offline in list and detail', async () => {
    const farmer = await registerFarmer('cam-thresh-stale@example.com');
    const cam = await pairCamera(farmer.token, 'thresh-stale');

    const hb = await api('POST', `/api/v1/cameras/${cam.cameraId}/heartbeat`, {
      token: cam.cameraToken,
      body: {},
    });
    expect(hb.status).toBe(200);

    // Age the heartbeat well past the 120s threshold.
    await testEnv.DB.prepare(
      'UPDATE cameras SET last_seen_at = ? WHERE id = ?',
    )
      .bind('2000-01-01T00:00:00.000Z', cam.cameraId)
      .run();

    const list = await api('GET', '/api/v1/cameras', { token: farmer.token });
    const { data: listData } = await readEnvelope<{
      cameras: Array<{ id: string; status: string }>;
    }>(list);
    expect(
      listData!.cameras.find((c) => c.id === cam.cameraId)!.status,
    ).toBe('offline');

    const detail = await api('GET', `/api/v1/cameras/${cam.cameraId}`, {
      token: farmer.token,
    });
    const { data: detailData } = await readEnvelope<{
      camera: { status: string };
    }>(detail);
    expect(detailData!.camera.status).toBe('offline');
  });
});

describe('POST /api/v1/cameras/me/unpair', () => {
  it('soft-unpairs: revokes the token and hides the camera from the farmer', async () => {
    const farmer = await registerFarmer('cam-self-unpair@example.com');
    const cam = await pairCamera(farmer.token, 'self-unpair');

    const res = await api('POST', '/api/v1/cameras/me/unpair', {
      token: cam.cameraToken,
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ unpaired: boolean }>(res);
    expect(data!.unpaired).toBe(true);

    // The camera's own token is revoked immediately.
    const hb = await api(
      'POST',
      `/api/v1/cameras/${cam.cameraId}/heartbeat`,
      { token: cam.cameraToken, body: {} },
    );
    expect(hb.status).toBe(401);

    // Hidden from the farmer's active list and detail view.
    const list = await api('GET', '/api/v1/cameras', { token: farmer.token });
    const { data: listData } = await readEnvelope<{
      cameras: Array<{ id: string }>;
    }>(list);
    expect(listData!.cameras.map((c) => c.id)).not.toContain(cam.cameraId);

    const detail = await api('GET', `/api/v1/cameras/${cam.cameraId}`, {
      token: farmer.token,
    });
    expect(detail.status).toBe(404);

    // The row still exists (soft delete), with the historical data intact.
    const row = await testEnv.DB.prepare(
      'SELECT unpaired_at, status, last_seen_at, token_version FROM cameras WHERE id = ?',
    )
      .bind(cam.cameraId)
      .first<{
        unpaired_at: string | null;
        status: string;
        last_seen_at: string | null;
        token_version: number;
      }>();
    expect(row!.unpaired_at).not.toBeNull();
    expect(row!.status).toBe('offline');
    expect(row!.last_seen_at).toBeNull();
    expect(row!.token_version).toBe(2);
  });

  it('rejects a farmer token with 403', async () => {
    const farmer = await registerFarmer('cam-self-unpair-farmer@example.com');
    const res = await api('POST', '/api/v1/cameras/me/unpair', {
      token: farmer.token,
    });
    expect(res.status).toBe(403);
  });
});
