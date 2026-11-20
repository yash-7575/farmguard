// Push-device registration tests: upsert by FCM token and idempotent
// unregistering.

import { describe, expect, it } from 'vitest';
import { api, readEnvelope, registerFarmer, testEnv } from './helpers';

describe('POST /api/v1/notifications/register-device', () => {
  it('registers a device (default platform android) → 201', async () => {
    const farmer = await registerFarmer('push-ok@example.com');
    const res = await api('POST', '/api/v1/notifications/register-device', {
      token: farmer.token,
      body: { fcm_token: 'fcm-token-abcdefghijklmnop-123456' },
    });
    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{ device: { platform: string; farmer_id: string } }>(res);
    expect(data!.device.platform).toBe('android');
    expect(data!.device.farmer_id).toBe(farmer.farmerId);
  });

  it('upserts by token: re-registering updates farmer and platform, not row count', async () => {
    const farmerA = await registerFarmer('push-upsert-a@example.com');
    const farmerB = await registerFarmer('push-upsert-b@example.com');
    const token = 'fcm-upsert-token-abcdefghijklmnopqrstuvwxyz';

    await api('POST', '/api/v1/notifications/register-device', {
      token: farmerA.token,
      body: { fcm_token: token, platform: 'android' },
    });
    const second = await api('POST', '/api/v1/notifications/register-device', {
      token: farmerB.token,
      body: { fcm_token: token, platform: 'ios' },
    });
    expect(second.status).toBe(201);

    const { data } = await readEnvelope<{ device: { farmer_id: string; platform: string } }>(second);
    expect(data!.device.farmer_id).toBe(farmerB.farmerId);
    expect(data!.device.platform).toBe('ios');

    const count = await testEnv.DB.prepare(
      'SELECT COUNT(*) AS n FROM push_devices WHERE fcm_token = ?',
    )
      .bind(token)
      .first<{ n: number }>();
    expect(count!.n).toBe(1);
  });

  it('validates fcm_token length and platform values with 400', async () => {
    const farmer = await registerFarmer('push-valid@example.com');
    const short = await api('POST', '/api/v1/notifications/register-device', {
      token: farmer.token,
      body: { fcm_token: 'short' },
    });
    expect(short.status).toBe(400);

    const badPlatform = await api('POST', '/api/v1/notifications/register-device', {
      token: farmer.token,
      body: { fcm_token: 'fcm-token-abcdefghijklmnop-123456', platform: 'web' },
    });
    expect(badPlatform.status).toBe(400);
  });

  it('requires a farmer token', async () => {
    const res = await api('POST', '/api/v1/notifications/register-device', {
      body: { fcm_token: 'fcm-token-abcdefghijklmnop-123456' },
    });
    expect(res.status).toBe(401);
  });
});

describe('DELETE /api/v1/notifications/unregister-device', () => {
  it('deletes the farmer\'s device and reports deleted:true', async () => {
    const farmer = await registerFarmer('push-del@example.com');
    const token = 'fcm-delete-token-abcdefghijklmnopqrstuvwxyz';
    await api('POST', '/api/v1/notifications/register-device', {
      token: farmer.token,
      body: { fcm_token: token },
    });

    const res = await api('DELETE', '/api/v1/notifications/unregister-device', {
      token: farmer.token,
      body: { fcm_token: token },
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ deleted: boolean }>(res);
    expect(data!.deleted).toBe(true);
  });

  it('is idempotent: a missing token → 200 deleted:false', async () => {
    const farmer = await registerFarmer('push-del2@example.com');
    const res = await api('DELETE', '/api/v1/notifications/unregister-device', {
      token: farmer.token,
      body: { fcm_token: 'fcm-missing-token-abcdefghijklmnopqrstuvwxyz' },
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ deleted: boolean }>(res);
    expect(data!.deleted).toBe(false);
  });

  it('cannot delete another farmer\'s device', async () => {
    const farmerA = await registerFarmer('push-del-a@example.com');
    const farmerB = await registerFarmer('push-del-b@example.com');
    const token = 'fcm-cross-token-abcdefghijklmnopqrstuvwxyz';
    await api('POST', '/api/v1/notifications/register-device', {
      token: farmerA.token,
      body: { fcm_token: token },
    });

    const res = await api('DELETE', '/api/v1/notifications/unregister-device', {
      token: farmerB.token,
      body: { fcm_token: token },
    });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ deleted: boolean }>(res);
    expect(data!.deleted).toBe(false);
  });
});
