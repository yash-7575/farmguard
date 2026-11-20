/**
 * Camera management routes (farmer token) and camera-device status routes
 * (camera token): GET/POST under /api/v1/cameras.
 *
 * Unpairing is a soft delete: the camera row stays (so historical
 * detection_events and their R2 images remain readable) but `unpaired_at` is
 * set and `token_version` is bumped, which revokes every issued device token
 * immediately. The same physical device can pair again later.
 */
import { Env } from '../types/env';
import { ApiError, ErrorCodes, jsonResponse } from '../utils/http';
import { asObject, readJsonObject, requireEnum } from '../utils/validation';
import { requireCamera, requireFarmer } from '../middleware/auth';
import { maskEmail } from './pairing';

export const CAMERA_STATUSES = ['offline', 'online', 'monitoring'] as const;

/**
 * A camera is only considered online/monitoring while its last heartbeat is
 * fresh. After 120s without a heartbeat it is reported as offline, regardless
 * of the last status it sent.
 */
export const ONLINE_THRESHOLD_MS = 120_000; // 120 seconds

export interface CameraRow {
  id: string;
  farmer_id: string;
  camera_name: string;
  location: string;
  device_identifier: string;
  status: string;
  last_seen_at: string | null;
  created_at: string;
}

export interface CameraResponse {
  id: string;
  farmer_id: string;
  camera_name: string;
  name: string;
  location: string;
  device_identifier: string;
  status: string;
  last_seen_at: string | null;
  created_at: string;
}

const CAMERA_COLUMNS =
  'id, farmer_id, camera_name, location, device_identifier, status, last_seen_at, created_at';

/**
 * Public camera shape: `name` aliases `camera_name`, and the status is
 * down-graded to 'offline' when the last heartbeat is stale (or missing).
 */
export function toCameraResponse(
  row: CameraRow,
  nowMs = Date.now(),
): CameraResponse {
  const isFresh =
    row.last_seen_at !== null &&
    nowMs - Date.parse(row.last_seen_at) <= ONLINE_THRESHOLD_MS;
  const effectiveStatus =
    (row.status === 'online' || row.status === 'monitoring') && isFresh
      ? row.status
      : 'offline';

  return {
    id: row.id,
    farmer_id: row.farmer_id,
    camera_name: row.camera_name,
    name: row.camera_name,
    location: row.location,
    device_identifier: row.device_identifier,
    status: effectiveStatus,
    last_seen_at: row.last_seen_at,
    created_at: row.created_at,
  };
}

function cameraNotFoundError(): ApiError {
  // Own-camera scoping: a foreign camera is indistinguishable from a missing one.
  return new ApiError(404, ErrorCodes.notFound, 'Camera not found.');
}

async function fetchOwnCamera(
  env: Env,
  cameraId: string,
  farmerId: string,
): Promise<CameraRow> {
  const camera = await env.DB.prepare(
    `SELECT ${CAMERA_COLUMNS} FROM cameras
      WHERE id = ? AND farmer_id = ? AND unpaired_at IS NULL`,
  )
    .bind(cameraId, farmerId)
    .first<CameraRow>();
  if (!camera) throw cameraNotFoundError();
  return camera;
}

/** GET /api/v1/cameras (farmer token) → 200 {cameras} — own active cameras only */
export async function handleListCameras(
  request: Request,
  env: Env,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);
  const { results } = await env.DB.prepare(
    `SELECT ${CAMERA_COLUMNS} FROM cameras
      WHERE farmer_id = ? AND unpaired_at IS NULL
      ORDER BY created_at ASC`,
  )
    .bind(farmerId)
    .all<CameraRow>();
  return jsonResponse({
    cameras: (results ?? []).map((row) => toCameraResponse(row)),
  });
}

/** GET /api/v1/cameras/:id (farmer token; own else 404) → 200 {camera} */
export async function handleGetCamera(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);
  const camera = await fetchOwnCamera(env, params['id']!, farmerId);
  return jsonResponse({ camera: toCameraResponse(camera) });
}

/**
 * POST /api/v1/cameras/:id/heartbeat (camera token; :id must equal the token
 * cid, else 403) → 200. Sets last_seen_at = now; status defaults to 'online'
 * unless an optional {status} body is supplied.
 */
export async function handleCameraHeartbeat(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const auth = await requireCamera(request, env);
  if (params['id'] !== auth.cameraId) {
    throw new ApiError(
      403,
      ErrorCodes.forbidden,
      'Token does not belong to this camera.',
    );
  }

  // Body is optional: treat an empty body as no explicit status.
  let requestedStatus: string | undefined;
  const text = await request.text();
  if (text.trim().length > 0) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new ApiError(
        400,
        ErrorCodes.invalidJson,
        'Request body must be valid JSON.',
      );
    }
    const body = asObject(parsed);
    if (body['status'] !== undefined) {
      requestedStatus = requireEnum(body, 'status', CAMERA_STATUSES);
    }
  }

  const now = new Date().toISOString();
  await env.DB.prepare(
    'UPDATE cameras SET last_seen_at = ?, status = ? WHERE id = ?',
  )
    .bind(now, requestedStatus ?? 'online', auth.cameraId)
    .run();

  const camera = await env.DB.prepare(
    `SELECT ${CAMERA_COLUMNS} FROM cameras WHERE id = ?`,
  )
    .bind(auth.cameraId)
    .first<CameraRow>();
  return jsonResponse({ camera: toCameraResponse(camera!) });
}

/** PATCH /api/v1/cameras/:id/status (camera token) {status} → 200 */
export async function handleCameraStatus(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const auth = await requireCamera(request, env);
  if (params['id'] !== auth.cameraId) {
    throw new ApiError(
      403,
      ErrorCodes.forbidden,
      'Token does not belong to this camera.',
    );
  }

  const body = asObject(await readJsonObject(request));
  const status = requireEnum(body, 'status', CAMERA_STATUSES);

  const now = new Date().toISOString();
  await env.DB.prepare(
    'UPDATE cameras SET status = ?, last_seen_at = ? WHERE id = ?',
  )
    .bind(status, now, auth.cameraId)
    .run();

  const camera = await env.DB.prepare(
    `SELECT ${CAMERA_COLUMNS} FROM cameras WHERE id = ?`,
  )
    .bind(auth.cameraId)
    .first<CameraRow>();
  return jsonResponse({ camera: toCameraResponse(camera!) });
}

/**
 * GET /api/v1/cameras/me (camera token) → 200 {paired, camera, farmer}.
 * Lets the camera app discover which farmer it is paired with (email masked).
 */
export async function handleGetCameraMe(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await requireCamera(request, env);

  const camera = await env.DB.prepare(
    `SELECT ${CAMERA_COLUMNS} FROM cameras WHERE id = ? AND unpaired_at IS NULL`,
  )
    .bind(auth.cameraId)
    .first<CameraRow>();
  if (!camera) throw cameraNotFoundError();

  const farmer = await env.DB.prepare(
    'SELECT id, name, email FROM farmers WHERE id = ?',
  )
    .bind(auth.farmerId)
    .first<{ id: string; name: string; email: string }>();

  return jsonResponse({
    paired: true,
    camera: toCameraResponse(camera),
    farmer: farmer
      ? {
          id: farmer.id,
          name: farmer.name,
          email_masked: maskEmail(farmer.email),
        }
      : null,
  });
}

/**
 * POST /api/v1/cameras/me/unpair (camera token) → 200 {unpaired: true}.
 * Soft-unpairs the camera and bumps token_version, revoking its own token.
 */
export async function handleUnpairCameraMe(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await requireCamera(request, env);

  await env.DB.prepare(
    `UPDATE cameras
        SET unpaired_at = ?, status = 'offline', last_seen_at = NULL,
            token_version = token_version + 1
      WHERE id = ?`,
  )
    .bind(new Date().toISOString(), auth.cameraId)
    .run();

  return jsonResponse({ unpaired: true });
}

/**
 * DELETE /api/v1/cameras/:id (farmer token, own else 404) → soft unpair.
 *
 * The camera row is kept with `unpaired_at` set, `status = 'offline'`,
 * `last_seen_at = NULL` and `token_version` bumped. This hides the camera from
 * the farmer's active list while preserving historical detection_events and
 * their R2 image objects (nothing is deleted here). The old device token dies
 * immediately via the token-version check in requireCamera; re-pairing the
 * same device_identifier later issues a fresh token.
 *
 * Camera tokens may NOT call this (requireFarmer → 403); a foreign farmer
 * gets 404, indistinguishable from an unknown camera.
 */
export async function handleDeleteCamera(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);
  const camera = await fetchOwnCamera(env, params['id']!, farmerId);

  const counts = await env.DB.prepare(
    'SELECT COUNT(*) AS events FROM detection_events WHERE camera_id = ?',
  )
    .bind(camera.id)
    .first<{ events: number }>();

  await env.DB.prepare(
    `UPDATE cameras
        SET unpaired_at = ?, status = 'offline', last_seen_at = NULL,
            token_version = token_version + 1
      WHERE id = ? AND farmer_id = ?`,
  )
    .bind(new Date().toISOString(), camera.id, farmerId)
    .run();

  return jsonResponse({
    deleted: true,
    unpaired: true,
    events_preserved: counts?.events ?? 0,
  });
}
