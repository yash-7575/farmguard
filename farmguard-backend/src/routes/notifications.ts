/**
 * Push-notification device registry (farmer token).
 * register-device upserts by FCM token (a device can move between farmers,
 * e.g. a family phone); unregister-device is idempotent.
 */
import { Env } from '../types/env';
import { jsonResponse } from '../utils/http';
import {
  asObject,
  optionalEnumWithDefault,
  readJsonObject,
  requireTrimmedString,
} from '../utils/validation';
import { requireFarmer } from '../middleware/auth';

export const PLATFORMS = ['android', 'ios'] as const;

interface PushDeviceRow {
  id: string;
  farmer_id: string;
  fcm_token: string;
  platform: string;
  created_at: string;
  updated_at: string;
}

/** POST /api/v1/notifications/register-device {fcm_token, platform?} → 201 {device} */
export async function handleRegisterDevice(
  request: Request,
  env: Env,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);
  const body = asObject(await readJsonObject(request));
  const fcmToken = requireTrimmedString(body, 'fcm_token', 20, 500);
  const platform = optionalEnumWithDefault(body, 'platform', PLATFORMS, 'android');

  const now = new Date().toISOString();
  await env.DB.prepare(
    `INSERT INTO push_devices (id, farmer_id, fcm_token, platform, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT (fcm_token) DO UPDATE
       SET farmer_id = excluded.farmer_id,
           platform = excluded.platform,
           updated_at = excluded.updated_at`,
  )
    .bind(crypto.randomUUID(), farmerId, fcmToken, platform, now, now)
    .run();

  const device = await env.DB.prepare(
    'SELECT id, farmer_id, fcm_token, platform, created_at, updated_at FROM push_devices WHERE fcm_token = ?',
  )
    .bind(fcmToken)
    .first<PushDeviceRow>();
  return jsonResponse({ device }, { status: 201 });
}

/** DELETE /api/v1/notifications/unregister-device {fcm_token} → 200 {deleted} */
export async function handleUnregisterDevice(
  request: Request,
  env: Env,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);
  const body = asObject(await readJsonObject(request));
  const fcmToken = requireTrimmedString(body, 'fcm_token', 20, 500);

  const deleted = await env.DB.prepare(
    'DELETE FROM push_devices WHERE farmer_id = ? AND fcm_token = ?',
  )
    .bind(farmerId, fcmToken)
    .run();

  // Idempotent: a token already gone (or owned by someone else) → deleted: false.
  return jsonResponse({ deleted: deleted.meta.changes > 0 });
}
