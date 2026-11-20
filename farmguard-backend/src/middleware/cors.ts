/**
 * CORS middleware.
 *
 * NOTE: CORS is a browser-enforced policy, NOT authentication. Any origin is
 * allowed here because the clients are native mobile apps; the actual access
 * control is the bearer-token auth in `./auth.ts`.
 */
const ALLOWED_METHODS = 'GET, POST, PATCH, DELETE, OPTIONS';
const ALLOWED_HEADERS = 'Content-Type, Authorization';
const MAX_AGE_SECONDS = 86_400;

function corsHeaders(): Record<string, string> {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': ALLOWED_METHODS,
    'access-control-allow-headers': ALLOWED_HEADERS,
    'access-control-max-age': String(MAX_AGE_SECONDS),
  };
}

/** Returns a 204 preflight response for OPTIONS requests, else null. */
export function handlePreflight(request: Request): Response | null {
  if (request.method !== 'OPTIONS') return null;
  return new Response(null, { status: 204, headers: corsHeaders() });
}

/** Adds the CORS headers to an actual (non-preflight) response. */
export function withCors(response: Response): Response {
  for (const [name, value] of Object.entries(corsHeaders())) {
    response.headers.set(name, value);
  }
  return response;
}
