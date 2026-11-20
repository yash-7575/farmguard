/**
 * Detection-event (alert) routes.
 *
 * POST /api/v1/alerts is camera-token only (farmer tokens get 403) with
 * client-supplied UUID ids for idempotent retries (ON CONFLICT DO NOTHING).
 * GET routes are farmer-token only, scoped to the caller's own events, with
 * keyset pagination on created_at DESC. DELETE removes an event and its R2
 * image object (Stage 8).
 */
import { Env } from '../types/env';
import { ApiError, ErrorCodes, jsonResponse } from '../utils/http';
import {
  asObject,
  readJsonObject,
  requireIsoTimestamp,
  requireNumber,
  requireTrimmedString,
  requireUuid,
  validateBoundingBox,
} from '../utils/validation';
import { requireCamera, requireFarmer } from '../middleware/auth';
import { notifyFarmerOfEvent } from '../services/fcm';

export interface DetectionEventRow {
  id: string;
  farmer_id: string;
  camera_id: string;
  detection_type: string;
  confidence: number;
  image_object_key: string | null;
  image_content_type: string | null;
  image_size: number | null;
  bounding_box: string | null;
  source_type: string;
  detected_at: string;
  created_at: string;
  viewed_at: string | null;
  idempotency_key: string;
}

const EVENT_COLUMNS =
  'id, farmer_id, camera_id, detection_type, confidence, image_object_key, image_content_type, image_size, bounding_box, source_type, detected_at, created_at, viewed_at, idempotency_key';

/** bounding_box is stored as a JSON string; surface it parsed to clients. */
function toEvent(row: DetectionEventRow): Record<string, unknown> {
  return {
    ...row,
    bounding_box: row.bounding_box ? JSON.parse(row.bounding_box) : null,
  };
}

function eventNotFoundError(): ApiError {
  return new ApiError(404, ErrorCodes.notFound, 'Event not found.');
}

/**
 * POST /api/v1/alerts (camera token ONLY) — body:
 * {id (client UUID), confidence 0-1, bounding_box?, image_object_key?,
 *  image_content_type?, image_size?, detected_at}. source_type = 'LIVE',
 * farmer_id comes from the camera's owner (never the request body).
 */
export async function handleCreateAlert(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await requireCamera(request, env);

  const body = asObject(await readJsonObject(request));
  const id = requireUuid(body, 'id');
  const confidence = requireNumber(body, 'confidence', 0, 1);
  const boundingBoxJson = validateBoundingBox(body);

  // Images arrive in Stage 4 (R2); image_object_key stays nullable for now.
  let imageObjectKey: string | null = null;
  if (body['image_object_key'] !== undefined && body['image_object_key'] !== null) {
    imageObjectKey = requireTrimmedString(body, 'image_object_key', 1, 512);
  }
  let imageContentType: string | null = null;
  if (
    body['image_content_type'] !== undefined &&
    body['image_content_type'] !== null
  ) {
    imageContentType = requireTrimmedString(body, 'image_content_type', 3, 100);
  }
  let imageSize: number | null = null;
  if (body['image_size'] !== undefined && body['image_size'] !== null) {
    const size = requireNumber(body, 'image_size', 0, Number.MAX_SAFE_INTEGER);
    if (!Number.isInteger(size)) {
      throw new ApiError(
        400,
        ErrorCodes.validationError,
        "Invalid request: field 'image_size' must be an integer.",
      );
    }
    imageSize = size;
  }
  const detectedAt = requireIsoTimestamp(body, 'detected_at');

  const createdAt = new Date().toISOString();
  // RETURNING makes conflict detection deterministic: zero rows returned ⇔
  // the id already existed (some D1 versions report changes=1 for DO NOTHING).
  const inserted = await env.DB.prepare(
    `INSERT INTO detection_events
       (id, farmer_id, camera_id, detection_type, confidence, image_object_key,
        image_content_type, image_size, bounding_box, source_type, detected_at,
        created_at, viewed_at, idempotency_key)
     VALUES (?, ?, ?, 'person', ?, ?, ?, ?, ?, 'LIVE', ?, ?, NULL, ?)
     ON CONFLICT (id) DO NOTHING
     RETURNING id`,
  )
    .bind(
      id,
      auth.farmerId,
      auth.cameraId,
      confidence,
      imageObjectKey,
      imageContentType,
      imageSize,
      boundingBoxJson,
      detectedAt,
      createdAt,
      id, // idempotency_key = client id
    )
    .first<{ id: string }>();
  // inserted === null ⇔ conflict (the id already existed).

  const event = await env.DB.prepare(
    `SELECT ${EVENT_COLUMNS} FROM detection_events WHERE id = ?`,
  )
    .bind(id)
    .first<DetectionEventRow>();

  if (!event) throw eventNotFoundError();

  // Retry of the same client id → the already-stored event, not a duplicate
  // row (and never a second push).
  const isDuplicate = inserted === null;

  // Stage 7: push one FCM notification per registered device of the owning
  // farmer for NEW events only. Inline await (not ctx.waitUntil): the fetch
  // handler does not plumb ExecutionContext into route handlers, and the
  // camera client tolerates ~200 ms. A notification failure must never fail
  // the alert request — notifyFarmerOfEvent never throws, and this belt-and-
  // braces try/catch guards against anything else.
  if (!isDuplicate) {
    try {
      const camera = await env.DB.prepare(
        'SELECT camera_name FROM cameras WHERE id = ?',
      )
        .bind(auth.cameraId)
        .first<{ camera_name: string }>();
      await notifyFarmerOfEvent(
        env,
        {
          id: event.id,
          farmer_id: event.farmer_id,
          camera_id: event.camera_id,
          detected_at: event.detected_at,
        },
        camera?.camera_name ?? 'Camera',
      );
    } catch (error) {
      console.warn('Push notification failed:', error instanceof Error ? error.message : error);
    }
  }

  return jsonResponse(
    { event: toEvent(event), ...(isDuplicate ? { duplicate: true } : {}) },
    { status: isDuplicate ? 200 : 201 },
  );
}

/**
 * GET /api/v1/alerts (farmer token) — own events, keyset pagination:
 * limit (1-50, default 20), before (ISO timestamp → created_at < before),
 * camera_id (optional filter). Order created_at DESC.
 */
export async function handleListAlerts(
  request: Request,
  env: Env,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);

  const url = new URL(request.url);
  let limit = 20;
  const limitParam = url.searchParams.get('limit');
  if (limitParam !== null) {
    const parsed = Number(limitParam);
    if (!Number.isInteger(parsed) || parsed < 1 || parsed > 50) {
      throw new ApiError(
        400,
        ErrorCodes.validationError,
        "Invalid request: query param 'limit' must be an integer between 1 and 50.",
      );
    }
    limit = parsed;
  }

  let before: string | undefined;
  const beforeParam = url.searchParams.get('before');
  if (beforeParam !== null) {
    const parsed = new Date(beforeParam);
    if (Number.isNaN(parsed.getTime())) {
      throw new ApiError(
        400,
        ErrorCodes.validationError,
        "Invalid request: query param 'before' must be an ISO-8601 timestamp.",
      );
    }
    before = beforeParam;
  }

  const cameraIdParam = url.searchParams.get('camera_id') ?? undefined;

  // Fetch one extra row to know whether another page exists.
  const statement = env.DB.prepare(
    `SELECT ${EVENT_COLUMNS} FROM detection_events
     WHERE farmer_id = ?
       ${cameraIdParam !== undefined ? 'AND camera_id = ?' : ''}
       ${before !== undefined ? 'AND created_at < ?' : ''}
     ORDER BY created_at DESC
     LIMIT ?`,
  );
  const bindings: (string | number)[] = [farmerId];
  if (cameraIdParam !== undefined) bindings.push(cameraIdParam);
  if (before !== undefined) bindings.push(before);
  bindings.push(limit + 1);

  const { results } = await statement.bind(...bindings).all<DetectionEventRow>();
  const rows = results ?? [];

  const hasMore = rows.length > limit;
  const events = hasMore ? rows.slice(0, limit) : rows;
  const nextBefore = hasMore ? events[events.length - 1]!.created_at : null;

  return jsonResponse({ events: events.map(toEvent), next_before: nextBefore });
}

/** GET /api/v1/alerts/:id (farmer token, own else 404) → 200 {event, camera} */
export async function handleGetAlert(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);
  const row = await env.DB.prepare(
    `SELECT
       detection_events.*, cameras.id AS camera_id,
       cameras.camera_name AS camera_name, cameras.location AS camera_location
     FROM detection_events
     JOIN cameras ON cameras.id = detection_events.camera_id
     WHERE detection_events.id = ? AND detection_events.farmer_id = ?`,
  )
    .bind(params['id']!, farmerId)
    .first<DetectionEventRow & { camera_id: string; camera_name: string; camera_location: string }>();
  if (!row) throw eventNotFoundError();

  return jsonResponse({
    event: toEvent(row),
    camera: {
      id: row.camera_id,
      name: row.camera_name,
      location: row.camera_location,
    },
  });
}

/** PATCH /api/v1/alerts/:id/viewed (farmer token, own else 404) → 200 (idempotent) */
export async function handleMarkAlertViewed(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);

  const updated = await env.DB.prepare(
    'UPDATE detection_events SET viewed_at = ? WHERE id = ? AND farmer_id = ? AND viewed_at IS NULL',
  )
    .bind(new Date().toISOString(), params['id']!, farmerId)
    .run();

  const event = await env.DB.prepare(
    `SELECT ${EVENT_COLUMNS} FROM detection_events WHERE id = ? AND farmer_id = ?`,
  )
    .bind(params['id']!, farmerId)
    .first<DetectionEventRow>();
  if (!event) throw eventNotFoundError();

  // Idempotent: an already-viewed event is returned unchanged (updated.changes === 0).
  return jsonResponse({ event: toEvent(event), updated: updated.meta.changes === 1 });
}

/**
 * DELETE /api/v1/alerts/:id (farmer token, own else 404) → 200 {deleted: true}.
 *
 * Deletes the event row AND its R2 image object. The image delete is
 * best-effort (try/catch): a missing or un-deletable object must never block
 * the row deletion — the worst case is a deleted row with an orphaned image
 * object in the bucket (documented in README alongside the orphan-upload
 * cleanup options). The row delete is scoped with farmer_id, so a foreign
 * event answers 404 exactly like an unknown one (indistinguishable, same as
 * GET). Camera tokens are refused by requireFarmer with 403.
 */
export async function handleDeleteAlert(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);

  const event = await env.DB.prepare(
    'SELECT image_object_key FROM detection_events WHERE id = ? AND farmer_id = ?',
  )
    .bind(params['id']!, farmerId)
    .first<{ image_object_key: string | null }>();
  if (!event) throw eventNotFoundError();

  const deleted = await env.DB.prepare(
    'DELETE FROM detection_events WHERE id = ? AND farmer_id = ?',
  )
    .bind(params['id']!, farmerId)
    .run();
  if (deleted.meta.changes !== 1) throw eventNotFoundError();

  if (event.image_object_key !== null) {
    // Best-effort: an R2 failure (or an already-missing object) must not
    // roll back or fail the delete — the row is gone either way.
    try {
      await env.IMAGES.delete(event.image_object_key);
    } catch (error) {
      console.warn(
        'Orphaned R2 image after event delete:',
        error instanceof Error ? error.message : error,
      );
    }
  }

  return jsonResponse({ deleted: true });
}
