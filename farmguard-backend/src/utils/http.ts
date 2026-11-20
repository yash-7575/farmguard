/**
 * Consistent JSON response envelope for every FarmGuard endpoint.
 *
 * Success: { "ok": true,  "data": ... }
 * Failure: { "ok": false, "error": { "code": "...", "message": "..." } }
 *
 * Never leak stack traces or internal detail in `message`.
 */

export function jsonResponse(data: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify({ ok: true, data }), {
    ...init,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      ...(init.headers ?? {}),
    },
  });
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
): Response {
  return new Response(
    JSON.stringify({ ok: false, error: { code, message } }),
    {
      status,
      headers: { 'content-type': 'application/json; charset=utf-8' },
    },
  );
}

/**
 * Typed error thrown by routes/middleware; the route wrapper converts it into
 * the standard error envelope. Thrown ApiErrors are *client-visible* by design.
 */
export class ApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }
}

/** Standard error codes used across routes. */
export const ErrorCodes = {
  notFound: 'not_found',
  methodNotAllowed: 'method_not_allowed',
  internal: 'internal_error',
  unauthorized: 'unauthorized',
  forbidden: 'forbidden',
  invalidJson: 'invalid_json',
  validationError: 'validation_error',
  payloadTooLarge: 'payload_too_large',
  invalidContentType: 'invalid_content_type',
  noImage: 'no_image',
  emailTaken: 'email_taken',
  invalidCredentials: 'invalid_credentials',
  deviceAlreadyPaired: 'device_already_paired',
  codeExpired: 'code_expired',
  tooManyAttempts: 'too_many_attempts',
  tooManyRequests: 'too_many_requests',
} as const;

/**
 * Route wrapper: runs the handler and converts thrown ApiError into the
 * standard error envelope; anything else becomes a generic 500 (detail is
 * kept out of the response on purpose — observability logs hold it).
 */
export async function withApiErrorHandling(
  handler: () => Promise<Response>,
): Promise<Response> {
  try {
    return await handler();
  } catch (error) {
    if (error instanceof ApiError) {
      return errorResponse(error.status, error.code, error.message);
    }
    return errorResponse(
      500,
      ErrorCodes.internal,
      'An unexpected error occurred.',
    );
  }
}
