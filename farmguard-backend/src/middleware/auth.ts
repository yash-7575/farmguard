/**
 * Bearer-token authentication middleware.
 *
 * `requireFarmer` guards farmer-app routes; `requireCamera` guards
 * camera-device routes. Both validate signature + expiry + typ via
 * services/token. Wrong token *type* on a valid signature is 403 (the caller
 * is authenticated but not allowed); missing/expired/tampered is 401.
 */
import { Env } from '../types/env';
import { ApiError, ErrorCodes } from '../utils/http';
import { verifyToken } from '../services/token';

export interface FarmerAuth {
  farmerId: string;
}

export interface CameraAuth {
  cameraId: string;
  farmerId: string;
}

function extractBearerToken(request: Request): string {
  const header = request.headers.get('authorization');
  if (!header || !header.startsWith('Bearer ')) {
    throw new ApiError(
      401,
      ErrorCodes.unauthorized,
      'Missing bearer token.',
    );
  }
  const token = header.slice('Bearer '.length).trim();
  if (token.length === 0) {
    throw new ApiError(401, ErrorCodes.unauthorized, 'Missing bearer token.');
  }
  return token;
}

/** Returns the authenticated farmer id, or throws 401/403. */
export async function requireFarmer(
  request: Request,
  env: Env,
): Promise<string> {
  const payload = await verifyToken(env, extractBearerToken(request));
  if (payload.typ !== 'farmer') {
    throw new ApiError(
      403,
      ErrorCodes.forbidden,
      'This endpoint requires a farmer token.',
    );
  }
  return payload.sub;
}

/**
 * Returns the authenticated camera's id and its owner's farmer id, or throws
 * 401/403. The farmer id is re-read from D1 (not trusted from the token) so a
 * deleted/soft-unpaired camera loses access immediately. The token's `tv` is
 * compared with the camera's current `token_version`; a mismatch means the
 * token was revoked by a re-pair or unpair.
 */
export async function requireCamera(
  request: Request,
  env: Env,
): Promise<CameraAuth> {
  const payload = await verifyToken(env, extractBearerToken(request));
  if (payload.typ !== 'camera' || payload.cid !== payload.sub) {
    throw new ApiError(
      403,
      ErrorCodes.forbidden,
      'This endpoint requires a camera token.',
    );
  }
  const camera = await env.DB.prepare(
    'SELECT farmer_id, unpaired_at, token_version FROM cameras WHERE id = ?',
  )
    .bind(payload.sub)
    .first<{
      farmer_id: string;
      unpaired_at: string | null;
      token_version: number;
    }>();
  if (!camera || camera.unpaired_at !== null) {
    throw new ApiError(
      401,
      ErrorCodes.unauthorized,
      'Camera is no longer registered.',
    );
  }
  if ((payload.tv ?? 1) !== camera.token_version) {
    throw new ApiError(
      401,
      ErrorCodes.unauthorized,
      'Camera token has been revoked.',
    );
  }
  return { cameraId: payload.sub, farmerId: camera.farmer_id };
}
