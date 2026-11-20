/**
 * Farmer authentication: POST /api/v1/auth/register, POST .../login,
 * GET .../me. Wrong credentials always answer with the same 401 envelope,
 * whether or not the email exists.
 */
import { Env } from '../types/env';
import {
  ApiError,
  ErrorCodes,
  jsonResponse,
} from '../utils/http';
import {
  asObject,
  readJsonObject,
  requireEmail,
  requireRawString,
  requireTrimmedString,
} from '../utils/validation';
import { hashPassword, verifyPassword } from '../services/password';
import { createFarmerToken } from '../services/token';
import { requireFarmer } from '../middleware/auth';

interface FarmerRow {
  id: string;
  name: string;
  email: string;
  password_hash: string;
}

interface PublicFarmer {
  id: string;
  name: string;
  email: string;
}

function toPublicFarmer(row: { id: string; name: string; email: string }): PublicFarmer {
  return { id: row.id, name: row.name, email: row.email };
}

function isUniqueConstraintError(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.message.includes('UNIQUE constraint failed') ||
      error.message.includes('constraint failed: farmers.email'))
  );
}

/** POST /api/v1/auth/register {name, email, password} → 201 {token, farmer} */
export async function handleRegister(
  request: Request,
  env: Env,
): Promise<Response> {
  const body = asObject(await readJsonObject(request));
  const name = requireTrimmedString(body, 'name', 1, 100);
  const email = requireEmail(body, 'email');
  const password = requireRawString(body, 'password', 8, 128);

  const now = new Date().toISOString();
  const id = crypto.randomUUID();
  const passwordHash = await hashPassword(password);

  try {
    await env.DB.prepare(
      'INSERT INTO farmers (id, name, email, password_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
    )
      .bind(id, name, email, passwordHash, now, now)
      .run();
  } catch (error) {
    // Covers the race between the pre-check and INSERT.
    if (isUniqueConstraintError(error)) {
      throw new ApiError(
        409,
        ErrorCodes.emailTaken,
        'An account with this email already exists.',
      );
    }
    throw error;
  }

  const token = await createFarmerToken(env, id);
  return jsonResponse(
    { token, farmer: { id, name, email } },
    { status: 201 },
  );
}

/** POST /api/v1/auth/login {email, password} → 200 {token, farmer} */
export async function handleLogin(
  request: Request,
  env: Env,
): Promise<Response> {
  const body = asObject(await readJsonObject(request));
  const email = requireEmail(body, 'email');
  const password = requireRawString(body, 'password', 1, 128);

  const farmer = await env.DB.prepare(
    'SELECT id, name, email, password_hash FROM farmers WHERE email = ?',
  )
    .bind(email)
    .first<FarmerRow>();

  const ok =
    farmer !== null && (await verifyPassword(password, farmer.password_hash));
  if (farmer === null || !ok) {
    // Same response whether or not the email exists.
    throw new ApiError(
      401,
      ErrorCodes.invalidCredentials,
      'Invalid email or password.',
    );
  }

  const token = await createFarmerToken(env, farmer.id);
  return jsonResponse({ token, farmer: toPublicFarmer(farmer) });
}

/** GET /api/v1/auth/me (farmer token) → 200 {farmer} */
export async function handleMe(request: Request, env: Env): Promise<Response> {
  const farmerId = await requireFarmer(request, env);
  const farmer = await env.DB.prepare(
    'SELECT id, name, email FROM farmers WHERE id = ?',
  )
    .bind(farmerId)
    .first<PublicFarmer>();
  if (!farmer) {
    throw new ApiError(404, ErrorCodes.notFound, 'Farmer not found.');
  }
  return jsonResponse({ farmer });
}
