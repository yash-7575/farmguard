/**
 * HMAC-SHA256 signed tokens (Web Crypto only; no JWT library needed).
 *
 * Format: base64url(payloadJson).base64url(signature)
 * Payload: { sub, typ: 'farmer' | 'camera', cid?, iat, exp }
 *   - farmer tokens: sub = farmer id, 12h TTL
 *   - camera tokens: sub = cid = camera id, 30d TTL
 *
 * Signing key is env.AUTH_SECRET — a Wrangler secret (`wrangler secret put
 * AUTH_SECRET`); local dev uses .dev.vars (gitignored). NEVER committed.
 */
import { ApiError, ErrorCodes } from '../utils/http';

const FARMER_TOKEN_TTL_SECONDS = 12 * 60 * 60; // 12h
const CAMERA_TOKEN_TTL_SECONDS = 30 * 24 * 60 * 60; // 30d

export type TokenType = 'farmer' | 'camera';

export interface TokenPayload {
  sub: string;
  typ: TokenType;
  /** Camera id — present on camera tokens only (sub === cid). */
  cid?: string;
  /** Camera token version — bumped on re-pair/unpair to revoke older tokens. */
  tv?: number;
  iat: number;
  exp: number;
}

const encoder = new TextEncoder();

function toBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(value: string): Uint8Array {
  const b64 = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw',
    encoder.encode(secret) as BufferSource,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  );
}

/**
 * Signs an arbitrary payload (exported so tests can craft e.g. expired
 * tokens). Production code should use createFarmerToken/createCameraToken.
 */
export async function signTokenPayload(
  env: { AUTH_SECRET: string },
  payload: TokenPayload,
): Promise<string> {
  const key = await hmacKey(env.AUTH_SECRET);
  const payloadPart = toBase64Url(encoder.encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(payloadPart) as BufferSource,
  );
  return `${payloadPart}.${toBase64Url(new Uint8Array(signature))}`;
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

export async function createFarmerToken(
  env: { AUTH_SECRET: string },
  farmerId: string,
): Promise<string> {
  const iat = nowSeconds();
  return signTokenPayload(env, {
    sub: farmerId,
    typ: 'farmer',
    iat,
    exp: iat + FARMER_TOKEN_TTL_SECONDS,
  });
}

export async function createCameraToken(
  env: { AUTH_SECRET: string },
  cameraId: string,
  tokenVersion = 1,
): Promise<string> {
  const iat = nowSeconds();
  return signTokenPayload(env, {
    sub: cameraId,
    typ: 'camera',
    cid: cameraId,
    tv: tokenVersion,
    iat,
    exp: iat + CAMERA_TOKEN_TTL_SECONDS,
  });
}

/**
 * Verifies signature, expiry and structure. Throws 401 `unauthorized` on any
 * failure (signature, format, expiry). Callers then check `typ`/`cid` and map
 * a wrong type to 403.
 */
export async function verifyToken(
  env: { AUTH_SECRET: string },
  token: string,
): Promise<TokenPayload> {
  const parts = token.split('.');
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    throw new ApiError(401, ErrorCodes.unauthorized, 'Invalid token.');
  }

  const key = await hmacKey(env.AUTH_SECRET);
  const providedSignature = fromBase64Url(parts[1]);
  // Recompute the signature and compare in constant time.
  let expectedSignature: Uint8Array;
  try {
    expectedSignature = new Uint8Array(
      await crypto.subtle.sign(
        'HMAC',
        key,
        encoder.encode(parts[0]) as BufferSource,
      ),
    );
  } catch {
    throw new ApiError(401, ErrorCodes.unauthorized, 'Invalid token.');
  }

  const signaturesMatch =
    expectedSignature.length === providedSignature.length &&
    !expectedSignature.some((byte, i) => byte !== providedSignature[i]);
  if (!signaturesMatch) {
    throw new ApiError(401, ErrorCodes.unauthorized, 'Invalid token.');
  }

  let payload: TokenPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(fromBase64Url(parts[0])));
  } catch {
    throw new ApiError(401, ErrorCodes.unauthorized, 'Invalid token.');
  }
  if (
    typeof payload !== 'object' ||
    payload === null ||
    typeof payload.sub !== 'string' ||
    (payload.typ !== 'farmer' && payload.typ !== 'camera') ||
    typeof payload.iat !== 'number' ||
    typeof payload.exp !== 'number'
  ) {
    throw new ApiError(401, ErrorCodes.unauthorized, 'Invalid token.');
  }

  if (payload.exp <= nowSeconds()) {
    throw new ApiError(401, ErrorCodes.unauthorized, 'Token expired.');
  }
  return payload;
}
