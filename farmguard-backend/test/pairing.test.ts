// Pairing flow tests: success, expiry, invalid code, reuse after
// consumption, and the brute-force attempt limit.

import { describe, expect, it } from 'vitest';
import {
  api,
  pairCamera,
  readEnvelope,
  registerFarmer,
  testEnv,
} from './helpers';

/** Decodes a token's (unverified) payload for assertions like `tv`. */
function decodeTokenPayload(token: string): { sub: string; tv?: number } {
  const part = token.split('.')[0]!;
  const b64 = part.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  return JSON.parse(atob(padded)) as { sub: string; tv?: number };
}

describe('pairing', () => {
  it('success path: farmer creates a code, camera redeems it for a token', async () => {
    const farmer = await registerFarmer('pair-ok@example.com');

    const codeRes = await api('POST', '/api/v1/pairing/code', {
      token: farmer.token,
    });
    expect(codeRes.status).toBe(201);
    const { data: codeData } = await readEnvelope<{
      code: string;
      expires_at: string;
    }>(codeRes);
    expect(codeData!.code).toMatch(/^\d{6}$/);

    const redeemRes = await api('POST', '/api/v1/pairing/redeem', {
      body: {
        code: codeData!.code,
        device_identifier: 'cam-device-001',
        camera_name: 'Gate Camera',
        location: 'North field',
      },
    });
    expect(redeemRes.status).toBe(201);
    const { data } = await readEnvelope<{
      token: string;
      camera: {
        id: string;
        camera_name: string;
        name: string;
        status: string;
        last_seen_at: string | null;
        farmer_id: string;
      };
      farmer: {
        id: string;
        name: string;
        email_masked: string;
      } | null;
    }>(redeemRes);
    expect(data!.token).toContain('.');
    // A fresh camera is never online before its first real heartbeat.
    expect(data!.camera.status).toBe('offline');
    expect(data!.camera.last_seen_at).toBeNull();
    expect(data!.camera.name).toBe(data!.camera.camera_name);
    expect(data!.camera.farmer_id).toBe(farmer.farmerId);
    expect(data!.farmer).toEqual({
      id: farmer.farmerId,
      name: 'Test Farmer',
      email_masked: 'pa***@example.com',
    });
  });

  it('code requires a farmer token', async () => {
    const res = await api('POST', '/api/v1/pairing/code');
    expect(res.status).toBe(401);
  });

  it('rejects a malformed code with 400', async () => {
    const farmer = await registerFarmer('pair-badformat@example.com');
    const res = await api('POST', '/api/v1/pairing/redeem', {
      body: { code: '12ab56', device_identifier: 'd1', camera_name: 'C' },
    });
    expect(res.status).toBe(400);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('validation_error');
  });

  it('rejects an unknown code with 404 code_not_found', async () => {
    const res = await api('POST', '/api/v1/pairing/redeem', {
      body: { code: '000000', device_identifier: 'd2', camera_name: 'C' },
    });
    expect(res.status).toBe(404);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('not_found');
  });

  it('rejects an expired code (410) and counts it as a failed attempt', async () => {
    const farmer = await registerFarmer('pair-expired@example.com');
    const codeRes = await api('POST', '/api/v1/pairing/code', { token: farmer.token });
    const { data } = await readEnvelope<{ code: string }>(codeRes);
    const code = data!.code;

    // Force-expire the newest code row for this farmer.
    await testEnv.DB.prepare(
      `UPDATE pairing_codes SET expires_at = '2000-01-01T00:00:00.000Z'
       WHERE farmer_id = ?`,
    )
      .bind(farmer.farmerId)
      .run();

    const res = await api('POST', '/api/v1/pairing/redeem', {
      body: { code, device_identifier: 'd3', camera_name: 'C' },
    });
    expect(res.status).toBe(410);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('code_expired');

    const row = await testEnv.DB.prepare(
      'SELECT attempts FROM pairing_codes WHERE farmer_id = ?',
    )
      .bind(farmer.farmerId)
      .first<{ attempts: number }>();
    expect(row!.attempts).toBe(1);
  });

  it('a consumed code is single-use: reuse answers 404', async () => {
    const farmer = await registerFarmer('pair-reuse@example.com');
    const codeRes = await api('POST', '/api/v1/pairing/code', { token: farmer.token });
    const { data } = await readEnvelope<{ code: string }>(codeRes);
    const code = data!.code;

    const first = await api('POST', '/api/v1/pairing/redeem', {
      body: { code, device_identifier: 'd4', camera_name: 'C' },
    });
    expect(first.status).toBe(201);

    const second = await api('POST', '/api/v1/pairing/redeem', {
      body: { code, device_identifier: 'd5', camera_name: 'C2' },
    });
    expect(second.status).toBe(404);
    const { error } = await readEnvelope(second);
    expect(error?.code).toBe('not_found'); // indistinguishable from unknown
  });

  it('brute force: the 6th failed attempt answers 429 too_many_attempts', async () => {
    const farmer = await registerFarmer('pair-brute@example.com');
    const codeRes = await api('POST', '/api/v1/pairing/code', { token: farmer.token });
    const { data } = await readEnvelope<{ code: string }>(codeRes);
    const code = data!.code;

    await testEnv.DB.prepare(
      `UPDATE pairing_codes SET expires_at = '2000-01-01T00:00:00.000Z'
       WHERE farmer_id = ?`,
    )
      .bind(farmer.farmerId)
      .run();

    for (let attempt = 1; attempt <= 5; attempt++) {
      const res = await api('POST', '/api/v1/pairing/redeem', {
        body: { code, device_identifier: `d6-${attempt}`, camera_name: 'C' },
      });
      expect(res.status).toBe(410);
    }

    const sixth = await api('POST', '/api/v1/pairing/redeem', {
      body: { code, device_identifier: 'd6-6', camera_name: 'C' },
    });
    expect(sixth.status).toBe(429);
    const { error } = await readEnvelope(sixth);
    expect(error?.code).toBe('too_many_attempts');
  });

  it('re-pairing the same device_identifier re-binds the camera and revokes the old token', async () => {
    const farmer = await registerFarmer('pair-device@example.com');
    const first = await pairCamera(farmer.token, 'paired-first');

    // The first token works before the re-pair.
    const before = await api(
      'POST',
      `/api/v1/cameras/${first.cameraId}/heartbeat`,
      { token: first.cameraToken, body: {} },
    );
    expect(before.status).toBe(200);

    const codeRes = await api('POST', '/api/v1/pairing/code', {
      token: farmer.token,
    });
    const { data: codeData } = await readEnvelope<{ code: string }>(codeRes);

    const res = await api('POST', '/api/v1/pairing/redeem', {
      body: {
        code: codeData!.code,
        device_identifier: first.deviceIdentifier,
        camera_name: 'Again',
        location: 'South field',
      },
    });
    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{
      token: string;
      camera: {
        id: string;
        camera_name: string;
        status: string;
        last_seen_at: string | null;
      };
      farmer: { id: string } | null;
    }>(res);

    // Same camera row re-bound in place — no duplicate row, no 409.
    expect(data!.camera.id).toBe(first.cameraId);
    expect(data!.camera.camera_name).toBe('Again');
    expect(data!.camera.status).toBe('offline');
    expect(data!.camera.last_seen_at).toBeNull();
    expect(data!.farmer!.id).toBe(farmer.farmerId);

    // New token carries the bumped version and works.
    expect(decodeTokenPayload(data!.token).tv).toBe(2);
    const after = await api(
      'POST',
      `/api/v1/cameras/${first.cameraId}/heartbeat`,
      { token: data!.token, body: {} },
    );
    expect(after.status).toBe(200);

    // The old token is revoked immediately (tv 1 vs current 2).
    const old = await api(
      'POST',
      `/api/v1/cameras/${first.cameraId}/heartbeat`,
      { token: first.cameraToken, body: {} },
    );
    expect(old.status).toBe(401);

    // Exactly one camera row exists for this device identifier.
    const rows = await testEnv.DB.prepare(
      'SELECT id FROM cameras WHERE device_identifier = ?',
    )
      .bind(first.deviceIdentifier)
      .all<{ id: string }>();
    expect(rows.results?.length).toBe(1);
  });
});
