// Stage 8: D1-backed global rate limiting on pairing redemption.
//
// Covers the limiter service directly (sequential counting, saturation, no
// double-count corruption, window reset) and the redeem route integration
// (429 before any code lookup, per-IP and per-device keys, successful
// redemptions counted too). Every redeem call here sends an explicit
// cf-connecting-ip so this file never shares the fallback-IP bucket used by
// tests that omit the header.

import { describe, expect, it } from 'vitest';
import { checkAndIncrement } from '../src/services/rate_limit';
import { sha256Hex } from '../src/services/password';
import {
  api,
  readEnvelope,
  registerFarmer,
  testEnv,
} from './helpers';

const WINDOW_MS = 10 * 60 * 1000; // matches the route's 10-minute window
const REDEEM_LIMIT = 20; // matches the route's limit

function ipKey(ip: string): Promise<string> {
  return sha256Hex(`ip:${ip}`);
}
function deviceKey(device: string): Promise<string> {
  return sha256Hex(`dev:${device}`);
}

/** Inserts (or overwrites) a rate_limit_windows row directly. */
async function seedWindow(
  key: string,
  count: number,
  windowStart: string,
): Promise<void> {
  await testEnv.DB.prepare(
    `INSERT INTO rate_limit_windows (key, window_start, count) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET window_start = excluded.window_start, count = excluded.count`,
  )
    .bind(key, windowStart, count)
    .run();
}

async function readCount(key: string): Promise<number | null> {
  const row = await testEnv.DB.prepare(
    'SELECT count FROM rate_limit_windows WHERE key = ?',
  )
    .bind(key)
    .first<{ count: number }>();
  return row === null ? null : row.count;
}

/** Redeems an (invalid) code from an explicit IP/device. */
function redeemFrom(ip: string, device: string, code = '000000') {
  return api('POST', '/api/v1/pairing/redeem', {
    body: { code, device_identifier: device, camera_name: 'C' },
    headers: { 'cf-connecting-ip': ip },
  });
}

describe('checkAndIncrement (service)', () => {
  it('counts sequential calls exactly, saturates at the limit, never double-counts', async () => {
    const key = `unit-${crypto.randomUUID()}`;
    const t0 = Date.parse('2026-11-18T12:00:00.000Z');
    const at = (s: number) => new Date(t0 + s * 1000);

    expect(await checkAndIncrement(testEnv, [key], 3, 60_000, at(0))).toBe(true);
    expect(await readCount(key)).toBe(1);
    expect(await checkAndIncrement(testEnv, [key], 3, 60_000, at(10))).toBe(true);
    expect(await readCount(key)).toBe(2);
    expect(await checkAndIncrement(testEnv, [key], 3, 60_000, at(20))).toBe(true);
    expect(await readCount(key)).toBe(3); // == limit

    // Over the limit: refused, and the counter does NOT increment further.
    expect(await checkAndIncrement(testEnv, [key], 3, 60_000, at(30))).toBe(false);
    expect(await readCount(key)).toBe(3);
    expect(await checkAndIncrement(testEnv, [key], 3, 60_000, at(40))).toBe(false);
    expect(await readCount(key)).toBe(3);
  });

  it('resets the counter when the window has expired', async () => {
    const key = `unit-reset-${crypto.randomUUID()}`;
    const t0 = Date.parse('2026-11-18T12:00:00.000Z');

    await seedWindow(key, 999, new Date(t0).toISOString());
    // 61s later with a 60s window: expired → fresh window starting at 1.
    const allowed = await checkAndIncrement(
      testEnv,
      [key],
      3,
      60_000,
      new Date(t0 + 61_000),
    );
    expect(allowed).toBe(true);
    expect(await readCount(key)).toBe(1);
  });

  it('requires ALL keys to be under limit', async () => {
    const a = `unit-a-${crypto.randomUUID()}`;
    const b = `unit-b-${crypto.randomUUID()}`;
    const t0 = Date.parse('2026-11-18T12:00:00.000Z');

    await seedWindow(a, 3, new Date(t0).toISOString()); // a is saturated (limit 3)
    const allowed = await checkAndIncrement(
      testEnv,
      [a, b],
      3,
      60_000,
      new Date(t0 + 1000),
    );
    expect(allowed).toBe(false);
    expect(await readCount(b)).toBe(1); // b still counted this attempt
    expect(await readCount(a)).toBe(3); // a not incremented further
  });
});

describe('POST /api/v1/pairing/redeem rate limiting', () => {
  it('429 too_many_requests BEFORE any code lookup when the IP bucket is full', async () => {
    const ip = '203.0.113.7';
    const key = await ipKey(ip);
    // Seed the IP bucket at the limit → the very next attempt (an unknown
    // code!) must be 429, not 404 — the limiter fires before the lookup.
    await seedWindow(key, REDEEM_LIMIT, new Date().toISOString());

    const res = await redeemFrom(ip, 'rl-device-a');
    expect(res.status).toBe(429);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('too_many_requests');

    // Saturated bucket: the counter must not have incremented further.
    expect(await readCount(key)).toBe(REDEEM_LIMIT);
  });

  it('429 when the device bucket is full, even from a different IP', async () => {
    const device = `rl-device-b-${crypto.randomUUID()}`;
    const key = await deviceKey(device);
    await seedWindow(key, REDEEM_LIMIT, new Date().toISOString());

    const res = await redeemFrom('203.0.113.8', device);
    expect(res.status).toBe(429);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('too_many_requests');
  });

  it('a fresh window resets a full bucket (old window_start row)', async () => {
    const ip = '203.0.113.9';
    const key = await ipKey(ip);
    // Full bucket whose window started 11 minutes ago (> 10 min window).
    await seedWindow(
      key,
      REDEEM_LIMIT,
      new Date(Date.now() - 11 * 60 * 1000).toISOString(),
    );

    const res = await redeemFrom(ip, 'rl-device-c');
    expect(res.status).toBe(404); // not 429 — the window reset, unknown code answered normally
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('not_found');
    expect(await readCount(key)).toBe(1); // fresh window, this attempt counted
  });

  it('a different IP is not affected by another IP being over limit', async () => {
    await seedWindow(
      await ipKey('203.0.113.10'),
      REDEEM_LIMIT,
      new Date().toISOString(),
    );
    const res = await redeemFrom('203.0.113.11', 'rl-device-d');
    expect(res.status).toBe(404);
  });

  it('counts successful redemptions too (both keys get a window row)', async () => {
    const farmer = await registerFarmer('rl-success@example.com');
    const ip = '203.0.113.12';
    const device = `rl-device-e-${crypto.randomUUID()}`;

    const codeRes = await api('POST', '/api/v1/pairing/code', {
      token: farmer.token,
    });
    const { data: codeData } = await readEnvelope<{ code: string }>(codeRes);

    const redeemRes = await api('POST', '/api/v1/pairing/redeem', {
      body: {
        code: codeData!.code,
        device_identifier: device,
        camera_name: 'C',
      },
      headers: { 'cf-connecting-ip': ip },
    });
    expect(redeemRes.status).toBe(201);

    expect(await readCount(await ipKey(ip))).toBe(1);
    expect(await readCount(await deviceKey(device))).toBe(1);
  });
});
