/**
 * Image routes (Stage 4) — private R2 storage, Worker-authenticated proxy.
 *
 * The bucket is never public and never hands out credentials or presigned
 * URLs to clients: the camera uploads raw JPEG bytes through this Worker and
 * the farmer app reads them back through an ownership-checked GET. Object
 * keys are random UUIDs stored in D1 (`detection_events.image_object_key`);
 * they are never exposed as URLs.
 *
 * The upload body bypasses the shared JSON-envelope reader (readJsonObject) —
 * it is raw binary, validated by Content-Type and size only.
 */
import { Env } from '../types/env';
import { ApiError, ErrorCodes, jsonResponse } from '../utils/http';
import { requireCamera, requireFarmer } from '../middleware/auth';

export const MAX_IMAGE_BYTES = 8 * 1024 * 1024; // 8 MiB
const ALLOWED_CONTENT_TYPE = 'image/jpeg';

/** Returns the type part of a Content-Type header, lowercased, minus params. */
function baseContentType(header: string | null): string {
  if (header === null) return '';
  // "image/jpeg; charset=binary" → "image/jpeg" (strip parameters, trim case).
  return header.split(';')[0]!.trim().toLowerCase();
}

/**
 * POST /api/v1/images/upload-url (camera token) → an honest direct-upload
 * descriptor (NOT a presigned URL): the camera POSTs the raw bytes to
 * POST /api/v1/images with its camera token.
 */
export async function handleImageUploadUrl(
  request: Request,
  env: Env,
): Promise<Response> {
  await requireCamera(request, env);
  return jsonResponse({
    upload_url: '/api/v1/images',
    method: 'POST',
    max_size_bytes: MAX_IMAGE_BYTES,
    allowed_content_types: [ALLOWED_CONTENT_TYPE],
  });
}

/**
 * POST /api/v1/images (camera token ONLY; farmer tokens → 403) — raw binary
 * JPEG body, 1 byte..8 MiB. Stored under a random, non-guessable key
 * `events/<yyyy-MM>/<uuid>.jpg`; the key is returned so the camera can
 * reference it in POST /api/v1/alerts (image_object_key).
 */
export async function handleImageUpload(
  request: Request,
  env: Env,
): Promise<Response> {
  await requireCamera(request, env);

  if (baseContentType(request.headers.get('content-type')) !== ALLOWED_CONTENT_TYPE) {
    throw new ApiError(
      400,
      ErrorCodes.invalidContentType,
      'Invalid request: Content-Type must be image/jpeg.',
    );
  }

  const body = await request.arrayBuffer();
  if (body.byteLength < 1) {
    throw new ApiError(
      400,
      ErrorCodes.validationError,
      'Request body must contain image bytes.',
    );
  }
  if (body.byteLength > MAX_IMAGE_BYTES) {
    throw new ApiError(
      413,
      ErrorCodes.payloadTooLarge,
      'Request body exceeds the allowed size.',
    );
  }

  const now = new Date();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const objectKey = `events/${now.getUTCFullYear()}-${month}/${crypto.randomUUID()}.jpg`;

  await env.IMAGES.put(objectKey, body, {
    httpMetadata: { contentType: ALLOWED_CONTENT_TYPE },
  });

  return jsonResponse({ object_key: objectKey }, { status: 201 });
}

/**
 * GET /api/v1/images/:eventId (farmer token) — streams the image attached to
 * the caller's own detection event. Foreign events answer 404 exactly like
 * the alert routes; a missing object (bucket or key) also answers 404.
 */
export async function handleGetEventImage(
  request: Request,
  env: Env,
  params: Record<string, string>,
): Promise<Response> {
  const farmerId = await requireFarmer(request, env);

  const event = await env.DB.prepare(
    `SELECT image_object_key, image_content_type
       FROM detection_events
      WHERE id = ? AND farmer_id = ?`,
  )
    .bind(params['eventId']!, farmerId)
    .first<{ image_object_key: string | null; image_content_type: string | null }>();

  if (!event || event.image_object_key === null) {
    throw new ApiError(404, ErrorCodes.noImage, 'Image not found.');
  }

  const object = await env.IMAGES.get(event.image_object_key);
  if (object === null) {
    throw new ApiError(404, ErrorCodes.noImage, 'Image not found.');
  }

  return new Response(object.body, {
    status: 200,
    headers: {
      'content-type': event.image_content_type ?? ALLOWED_CONTENT_TYPE,
      'cache-control': 'private, no-store',
    },
  });
}
