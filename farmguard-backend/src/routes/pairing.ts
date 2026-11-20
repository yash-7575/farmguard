/**
 * Camera pairing.
 *
 * Flow: farmer generates a 6-digit code (POST /api/v1/pairing/code) → enters
 * it in the camera app → camera redeems (POST /api/v1/pairing/redeem) → gets
 * a long-lived camera token. Only the SHA-256 hash of the code is stored; the
 * code is single-use and consumed atomically (UPDATE ... WHERE consumed_at IS
 * NULL — the affected-rows count decides the winner of a race).
 */
import { Env } from '../types/env';
import { ApiError, ErrorCodes, jsonResponse } from '../utils/http';
import {
  asObject,
  optionalTrimmedString,
  readJsonObject,
  requireTrimmedString,
} from '../utils/validation';
import { generatePairingCode, sha256Hex } from '../services/password';
import { createCameraToken } from '../services/token';
import { requireFarmer } from '../middleware/auth';
import { checkAndIncrement } from '../services/rate_limit';

const CODE_TTL_MS = 5 * 60 * 1000; // 5 minutes
const MAX_ATTEMPTS = 5;

/**
 * Stage 8: global brute-force limiter on redemption. A spray of random
 * 6-digit codes never touches a pairing_codes row, so the per-code attempt
 * counter cannot see it; these per-IP and per-device counters can.
 * Per-isolate memory caches are unreliable in Workers (isolates are
 * ephemeral and multi-instance), hence the D1-backed limiter.
 */
const REDEEM_LIMIT = 20; // attempts
const REDEEM_WINDOW_MS = 10 * 60 * 1000; // 10 minutes

interface PairingCodeRow {
  id: string;
  farmer_id: string;
  expires_at: string;
  attempts: number;
  consumed_at: string | null;
}

interface CameraRow {
  id: string;
  farmer_id: string;
  camera_name: string;
  location: string;
  device_identifier: string;
  status: string;
  last_seen_at: string | null;
  created_at: string;
}

interface FarmerRow {
  id: string;
  name: string;
  email: string;
}

/**
 * Masks an email for camera-side display: `ab***@domain` for a local part
 * longer than 2 characters, `a***@domain` for a 1-2 character local part, and
 * `***` for anything that is not a simple `local@domain`.
 */
export function maskEmail(email: string): string {
  const parts = email.split('@');
  if (parts.length !== 2) return '***';
  const local = parts[0]!;
  const domain = parts[1]!;
  if (local.length === 0 || domain.length === 0) return '***';
  if (local.length <= 2) {
    return `${local[0] ?? '*'}***@${domain}`;
  }
  return `${local.slice(0, 2)}***@${domain}`;
}

/** POST /api/v1/pairing/code (farmer token) → 201 {code, expires_at} */
export async function handleCreatePairingCode(
  request: Request,
  env: Env,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);

  const code = generatePairingCode();
  const codeHash = await sha256Hex(code);
  const now = new Date();
  const expiresAt = new Date(now.getTime() + CODE_TTL_MS).toISOString();

  await env.DB.prepare(
    'INSERT INTO pairing_codes (id, farmer_id, code_hash, expires_at, attempts, consumed_at, created_at) VALUES (?, ?, ?, ?, 0, NULL, ?)',
  )
    .bind(crypto.randomUUID(), farmerId, codeHash, expiresAt, now.toISOString())
    .run();

  return jsonResponse({ code, expires_at: expiresAt }, { status: 201 });
}

/** POST /api/v1/pairing/redeem {code, device_identifier, camera_name, location?} → 201 {token, camera} */
export async function handleRedeemPairingCode(
  request: Request,
  env: Env,
): Promise<Response> {
  const body = asObject(await readJsonObject(request));
  const code = requireTrimmedString(body, 'code', 6, 6);
  if (!/^\d{6}$/.test(code)) {
    throw new ApiError(
      400,
      ErrorCodes.validationError,
      "Invalid request: field 'code' must be 6 digits.",
    );
  }
  const deviceIdentifier = requireTrimmedString(body, 'device_identifier', 1, 200);
  const cameraName = requireTrimmedString(body, 'camera_name', 1, 100);
  const location = optionalTrimmedString(body, 'location', 0, 200) ?? '';

  // Stage 8: rate limit BEFORE any code lookup, so the 429 does not leak
  // whether a code exists. Count every attempt — success and failure alike.
  // The IP falls back to a constant when the header is absent (local dev and
  // tests); in production Cloudflare always sets cf-connecting-ip.
  const clientIp = request.headers.get('cf-connecting-ip') ?? 'unknown';
  const ipKey = await sha256Hex(`ip:${clientIp}`);
  const deviceKey = await sha256Hex(`dev:${deviceIdentifier}`);
  const now = new Date();
  const underLimit = await checkAndIncrement(
    env,
    [ipKey, deviceKey],
    REDEEM_LIMIT,
    REDEEM_WINDOW_MS,
    now,
  );
  if (!underLimit) {
    throw new ApiError(
      429,
      ErrorCodes.tooManyRequests,
      'Too many redemption attempts. Try again later.',
    );
  }

  const codeHash = await sha256Hex(code);
  const nowIso = now.toISOString();

  const row = await env.DB.prepare(
    'SELECT id, farmer_id, expires_at, attempts, consumed_at FROM pairing_codes WHERE code_hash = ? ORDER BY created_at DESC LIMIT 1',
  )
    .bind(codeHash)
    .first<PairingCodeRow>();

  if (!row) {
    // Unknown code — do not reveal anything about validity of other codes.
    throw codeNotFoundError();
  }
  if (row.consumed_at !== null) {
    // Already used — same 404 as unknown, so reuse is indistinguishable.
    throw codeNotFoundError();
  }
  if (row.attempts >= MAX_ATTEMPTS) {
    throw new ApiError(
      429,
      ErrorCodes.tooManyAttempts,
      'Too many attempts for this pairing code.',
    );
  }
  if (row.expires_at <= nowIso) {
    // A failed attempt against a live row counts toward the attempt limit.
    await env.DB.prepare(
      'UPDATE pairing_codes SET attempts = attempts + 1 WHERE id = ?',
    )
      .bind(row.id)
      .run();
    throw new ApiError(
      410,
      ErrorCodes.codeExpired,
      'This pairing code has expired.',
    );
  }

  // Atomic single-use claim: only one redemption can set consumed_at.
  const claim = await env.DB.prepare(
    'UPDATE pairing_codes SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL AND expires_at > ?',
  )
    .bind(nowIso, row.id, nowIso)
    .run();
  if (claim.meta.changes !== 1) {
    // Lost a race (another redemption consumed the code).
    throw codeNotFoundError();
  }

  // A device that was paired before (including a soft-unpaired one) is
  // re-bound in place: same camera id, new owner/name/location, and a bumped
  // token version that revokes every previously issued token.
  const existingDevice = await env.DB.prepare(
    'SELECT id, token_version FROM cameras WHERE device_identifier = ?',
  )
    .bind(deviceIdentifier)
    .first<{ id: string; token_version: number }>();

  let cameraId: string;
  let nextTokenVersion: number;
  if (existingDevice) {
    nextTokenVersion = (existingDevice.token_version ?? 1) + 1;
    cameraId = existingDevice.id;
    await env.DB.prepare(
      `UPDATE cameras
          SET farmer_id = ?, camera_name = ?, location = ?, status = 'offline',
              last_seen_at = NULL, unpaired_at = NULL, token_version = ?
        WHERE id = ?`,
    )
      .bind(
        row.farmer_id,
        cameraName,
        location,
        nextTokenVersion,
        cameraId,
      )
      .run();
  } else {
    cameraId = crypto.randomUUID();
    nextTokenVersion = 1;
    // A camera is NEVER online before its first real heartbeat.
    await env.DB.prepare(
      `INSERT INTO cameras
         (id, farmer_id, camera_name, location, device_identifier, status,
          last_seen_at, created_at, unpaired_at, token_version)
       VALUES (?, ?, ?, ?, ?, 'offline', NULL, ?, NULL, 1)`,
    )
      .bind(
        cameraId,
        row.farmer_id,
        cameraName,
        location,
        deviceIdentifier,
        nowIso,
      )
      .run();
  }

  const camera = await env.DB.prepare(
    'SELECT id, farmer_id, camera_name, location, device_identifier, status, last_seen_at, created_at FROM cameras WHERE id = ?',
  )
    .bind(cameraId)
    .first<CameraRow>();

  const farmer = await env.DB.prepare(
    'SELECT id, name, email FROM farmers WHERE id = ?',
  )
    .bind(row.farmer_id)
    .first<FarmerRow>();

  const token = await createCameraToken(env, cameraId, nextTokenVersion);
  return jsonResponse(
    {
      token,
      camera: {
        ...camera,
        name: camera!.camera_name,
      },
      farmer: farmer
        ? {
            id: farmer.id,
            name: farmer.name,
            email_masked: maskEmail(farmer.email),
          }
        : null,
    },
    { status: 201 },
  );
}

function codeNotFoundError(): ApiError {
  return new ApiError(
    404,
    ErrorCodes.notFound,
    'This pairing code is not valid.',
  );
}
