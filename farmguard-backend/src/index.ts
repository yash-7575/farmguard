/**
 * FarmGuard backend Worker — plain fetch handler (no framework).
 *
 * Routing is a small explicit path/method table (regex captures fill the
 * :id params). Middleware layers: CORS preflight + response headers, then
 * per-route auth/validation; ApiError thrown anywhere becomes the standard
 * error envelope. The handler never leaks a stack trace to the client.
 */
import { handleHealth } from './routes/health';
import { handleRegister, handleLogin, handleMe } from './routes/auth';
import {
  handleCreatePairingCode,
  handleRedeemPairingCode,
} from './routes/pairing';
import {
  handleListCameras,
  handleGetCamera,
  handleGetCameraMe,
  handleUnpairCameraMe,
  handleCameraHeartbeat,
  handleCameraStatus,
  handleDeleteCamera,
} from './routes/cameras';
import {
  handleCreateAlert,
  handleListAlerts,
  handleGetAlert,
  handleMarkAlertViewed,
  handleDeleteAlert,
} from './routes/alerts';
import {
  handleRegisterDevice,
  handleUnregisterDevice,
} from './routes/notifications';
import {
  handleImageUploadUrl,
  handleImageUpload,
  handleGetEventImage,
} from './routes/images';
import { handlePreflight, withCors } from './middleware/cors';
import { Env } from './types/env';
import { errorResponse, ErrorCodes, withApiErrorHandling } from './utils/http';

type RouteHandler = (
  request: Request,
  env: Env,
  params: Record<string, string>,
) => Promise<Response>;

interface Route {
  method: string;
  pattern: RegExp;
  handler: RouteHandler;
}

const ROUTES: Route[] = [
  // Auth (farmer)
  { method: 'POST', pattern: /^\/api\/v1\/auth\/register$/, handler: handleRegister },
  { method: 'POST', pattern: /^\/api\/v1\/auth\/login$/, handler: handleLogin },
  { method: 'GET', pattern: /^\/api\/v1\/auth\/me$/, handler: handleMe },
  // Pairing
  { method: 'POST', pattern: /^\/api\/v1\/pairing\/code$/, handler: handleCreatePairingCode },
  { method: 'POST', pattern: /^\/api\/v1\/pairing\/redeem$/, handler: handleRedeemPairingCode },
  // Cameras
  { method: 'GET', pattern: /^\/api\/v1\/cameras$/, handler: handleListCameras },
  // `/me` routes MUST come before the `:id` routes below.
  { method: 'GET', pattern: /^\/api\/v1\/cameras\/me$/, handler: handleGetCameraMe },
  { method: 'POST', pattern: /^\/api\/v1\/cameras\/me\/unpair$/, handler: handleUnpairCameraMe },
  { method: 'GET', pattern: /^\/api\/v1\/cameras\/(?<id>[^/]+)$/, handler: handleGetCamera },
  { method: 'DELETE', pattern: /^\/api\/v1\/cameras\/(?<id>[^/]+)$/, handler: handleDeleteCamera },
  { method: 'POST', pattern: /^\/api\/v1\/cameras\/(?<id>[^/]+)\/heartbeat$/, handler: handleCameraHeartbeat },
  { method: 'PATCH', pattern: /^\/api\/v1\/cameras\/(?<id>[^/]+)\/status$/, handler: handleCameraStatus },
  // Alerts (detection events)
  { method: 'POST', pattern: /^\/api\/v1\/alerts$/, handler: handleCreateAlert },
  { method: 'GET', pattern: /^\/api\/v1\/alerts$/, handler: handleListAlerts },
  { method: 'GET', pattern: /^\/api\/v1\/alerts\/(?<id>[^/]+)$/, handler: handleGetAlert },
  { method: 'DELETE', pattern: /^\/api\/v1\/alerts\/(?<id>[^/]+)$/, handler: handleDeleteAlert },
  { method: 'PATCH', pattern: /^\/api\/v1\/alerts\/(?<id>[^/]+)\/viewed$/, handler: handleMarkAlertViewed },
  // Push devices
  { method: 'POST', pattern: /^\/api\/v1\/notifications\/register-device$/, handler: handleRegisterDevice },
  { method: 'DELETE', pattern: /^\/api\/v1\/notifications\/unregister-device$/, handler: handleUnregisterDevice },
  // Images (private R2, Worker-authenticated proxy — Stage 4)
  { method: 'POST', pattern: /^\/api\/v1\/images\/upload-url$/, handler: handleImageUploadUrl },
  { method: 'POST', pattern: /^\/api\/v1\/images$/, handler: handleImageUpload },
  { method: 'GET', pattern: /^\/api\/v1\/images\/(?<eventId>[^/]+)$/, handler: handleGetEventImage },
];

function extractParams(
  pattern: RegExp,
  path: string,
): Record<string, string> | null {
  const match = pattern.exec(path);
  if (!match) return null;
  const params: Record<string, string> = {};
  for (const [key, value] of Object.entries(match.groups ?? {})) {
    params[key] = decodeURIComponent(value!);
  }
  return params;
}

export default {
  async fetch(
    request: Request,
    env: Env,
    _ctx: ExecutionContext,
  ): Promise<Response> {
    return withApiErrorHandling(async () => {
      // CORS preflight (CORS is not authentication; see middleware/cors.ts).
      const preflight = handlePreflight(request);
      if (preflight) return preflight;

      const url = new URL(request.url);
      const path = url.pathname;

      // Liveness probe (both plain and versioned paths).
      if (
        request.method === 'GET' &&
        (path === '/api/health' || path === '/api/v1/health')
      ) {
        return handleHealth();
      }

      for (const route of ROUTES) {
        if (route.method !== request.method) continue;
        const params = extractParams(route.pattern, path);
        if (params) {
          return withCors(await route.handler(request, env, params));
        }
      }

      // Unknown route → consistent JSON 404.
      return errorResponse(
        404,
        ErrorCodes.notFound,
        'The requested endpoint does not exist.',
      );
    });
  },
};
