import { jsonResponse } from '../utils/http';

/**
 * GET /api/health (also served as /api/v1/health).
 *
 * Liveness probe for uptime checks and for the mobile apps' connection
 * status indicator. Reports the service name and server time (UTC).
 */
export function handleHealth(): Response {
  return jsonResponse({
    status: 'ok',
    service: 'farmguard-backend',
    time: new Date().toISOString(),
  });
}
