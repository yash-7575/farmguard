/**
 * Request-body reading and field validation helpers.
 *
 * Every route validates: JSON well-formedness, body size, field presence,
 * types and ranges — validation failures produce 400s with a stable code.
 */
import { ApiError, ErrorCodes } from './http';

/** 256 KB request-body limit (image upload routes in Stage 4 get their own). */
export const MAX_BODY_BYTES = 256 * 1024;

/**
 * Reads and parses the request body as JSON.
 * - Rejects bodies larger than MAX_BODY_BYTES with 413.
 * - Rejects invalid JSON with 400 `invalid_json`.
 * - Rejects non-object JSON with 400 `validation_error`.
 */
export async function readJsonObject(
  request: Request,
  maxBytes: number = MAX_BODY_BYTES,
): Promise<Record<string, unknown>> {
  const contentLength = request.headers.get('content-length');
  if (contentLength && Number(contentLength) > maxBytes) {
    throw new ApiError(
      413,
      ErrorCodes.payloadTooLarge,
      'Request body exceeds the allowed size.',
    );
  }

  const text = await request.text();
  if (text.length > maxBytes) {
    throw new ApiError(
      413,
      ErrorCodes.payloadTooLarge,
      'Request body exceeds the allowed size.',
    );
  }
  // text.length <= byte length, so a char-count near the limit warrants an
  // exact byte check (multi-byte UTF-8 bodies could otherwise slip past).
  if (text.length * 4 > maxBytes) {
    const byteLength = new TextEncoder().encode(text).length;
    if (byteLength > maxBytes) {
      throw new ApiError(
        413,
        ErrorCodes.payloadTooLarge,
        'Request body exceeds the allowed size.',
      );
    }
  }

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
  return asObject(parsed);
}

/** Narrow an unknown parsed JSON value to a plain object (arrays rejected). */
export function asObject(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new ApiError(
      400,
      ErrorCodes.validationError,
      'Request body must be a JSON object.',
    );
  }
  return value as Record<string, unknown>;
}

/** Required string field, length-checked after trimming. */
export function requireTrimmedString(
  obj: Record<string, unknown>,
  field: string,
  min: number,
  max: number,
): string {
  const value = obj[field];
  if (typeof value !== 'string') {
    throw fieldValidationError(field, 'must be a string');
  }
  const trimmed = value.trim();
  if (trimmed.length < min || trimmed.length > max) {
    throw fieldValidationError(
      field,
      `must be between ${min} and ${max} characters`,
    );
  }
  return trimmed;
}

/** Required string field, length-checked WITHOUT trimming (e.g. passwords). */
export function requireRawString(
  obj: Record<string, unknown>,
  field: string,
  min: number,
  max: number,
): string {
  const value = obj[field];
  if (typeof value !== 'string') {
    throw fieldValidationError(field, 'must be a string');
  }
  if (value.length < min || value.length > max) {
    throw fieldValidationError(
      field,
      `must be between ${min} and ${max} characters`,
    );
  }
  return value;
}

/** Optional string field; returns undefined when absent, '' when null. */
export function optionalTrimmedString(
  obj: Record<string, unknown>,
  field: string,
  min: number,
  max: number,
): string | undefined {
  if (obj[field] === undefined) return undefined;
  if (obj[field] === null) return '';
  const value = requireTrimmedString(obj, field, min, max);
  return value;
}

/** Required email field; validated and normalized to lowercase. */
export function requireEmail(
  obj: Record<string, unknown>,
  field: string,
): string {
  const value = requireTrimmedString(obj, field, 3, 254);
  const email = value.toLowerCase();
  // Pragmatic format check: one @, non-empty local part, dotted domain.
  const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailPattern.test(email)) {
    throw fieldValidationError(field, 'must be a valid email address');
  }
  return email;
}

/** Required number in [min, max] inclusive; rejects booleans and strings. */
export function requireNumber(
  obj: Record<string, unknown>,
  field: string,
  min: number,
  max: number,
): number {
  const value = obj[field];
  if (typeof value !== 'number' || Number.isNaN(value)) {
    throw fieldValidationError(field, 'must be a number');
  }
  if (value < min || value > max) {
    throw fieldValidationError(field, `must be between ${min} and ${max}`);
  }
  return value;
}

/** Optional integer ≥ min (e.g. image_size); returns undefined when absent. */
export function optionalNonNegativeInt(
  obj: Record<string, unknown>,
  field: string,
  min: number,
): number | undefined {
  if (obj[field] === undefined || obj[field] === null) return undefined;
  const value = obj[field];
  if (typeof value !== 'number' || !Number.isInteger(value) || value < min) {
    throw fieldValidationError(field, `must be an integer >= ${min}`);
  }
  return value;
}

/** Value must be one of the allowed literals. */
export function requireEnum(
  obj: Record<string, unknown>,
  field: string,
  allowed: readonly string[],
): string {
  const value = obj[field];
  if (typeof value !== 'string' || !allowed.includes(value)) {
    throw fieldValidationError(
      field,
      `must be one of: ${allowed.join(', ')}`,
    );
  }
  return value;
}

/** Optional enum; default used when the field is absent. */
export function optionalEnumWithDefault(
  obj: Record<string, unknown>,
  field: string,
  allowed: readonly string[],
  fallback: string,
): string {
  if (obj[field] === undefined) return fallback;
  return requireEnum(obj, field, allowed);
}

/** UUID (any RFC-4122 version) for client-supplied ids. */
export function requireUuid(
  obj: Record<string, unknown>,
  field: string,
): string {
  const value = requireTrimmedString(obj, field, 36, 36);
  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidPattern.test(value)) {
    throw fieldValidationError(field, 'must be a UUID');
  }
  return value.toLowerCase();
}

/** Parseable ISO-8601 timestamp string. */
export function requireIsoTimestamp(
  obj: Record<string, unknown>,
  field: string,
): string {
  const value = requireTrimmedString(obj, field, 10, 100);
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw fieldValidationError(field, 'must be an ISO-8601 timestamp');
  }
  return value;
}

/** bounding_box: null or array of 0-5 normalized {left,top,width,height}. */
export function validateBoundingBox(obj: Record<string, unknown>): string | null {
  const value = obj['bounding_box'];
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value)) {
    throw fieldValidationError('bounding_box', 'must be an array or null');
  }
  if (value.length > 5) {
    throw fieldValidationError('bounding_box', 'must contain at most 5 boxes');
  }
  for (const entry of value) {
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
      throw fieldValidationError(
        'bounding_box',
        'each box must be an object with left, top, width, height',
      );
    }
    const box = entry as Record<string, unknown>;
    for (const key of ['left', 'top', 'width', 'height'] as const) {
      const coord = box[key];
      if (typeof coord !== 'number' || Number.isNaN(coord) || coord < 0 || coord > 1) {
        throw fieldValidationError(
          'bounding_box',
          `each box ${key} must be a number between 0.0 and 1.0`,
        );
      }
    }
  }
  return JSON.stringify(value);
}

export function fieldValidationError(field: string, detail: string): ApiError {
  return new ApiError(
    400,
    ErrorCodes.validationError,
    `Invalid request: field '${field}' ${detail}.`,
  );
}
