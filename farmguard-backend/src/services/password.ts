/**
 * Password hashing with Web Crypto only (Workers runtime).
 *
 * Format stored in `farmers.password_hash`:
 *   pbkdf2-sha256$<iterations>$<salt_b64>$<hash_b64>
 *
 * 100 000 iterations of PBKDF2-SHA256, 16-byte random salt, 32-byte derived
 * key. Verification derives from the stored salt and compares in constant
 * time.
 */
import { ApiError, ErrorCodes } from '../utils/http';

export const PBKDF2_ITERATIONS = 100_000;
const SALT_BYTES = 16;
const KEY_BYTES = 32;
const HASH_FORMAT = 'pbkdf2-sha256';

const encoder = new TextEncoder();

function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function deriveKey(
  password: string,
  salt: Uint8Array,
  iterations: number,
): Promise<Uint8Array> {
  const keyMaterial = await crypto.subtle.importKey(
    'raw',
    encoder.encode(password),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    {
      name: 'PBKDF2',
      hash: 'SHA-256',
      salt: salt as BufferSource,
      iterations,
    },
    keyMaterial,
    KEY_BYTES * 8,
  );
  return new Uint8Array(bits);
}

/** Constant-time byte comparison (no early exit on mismatch). */
export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const derived = await deriveKey(password, salt, PBKDF2_ITERATIONS);
  return `${HASH_FORMAT}$${PBKDF2_ITERATIONS}$${toBase64(salt)}$${toBase64(derived)}`;
}

export async function verifyPassword(
  password: string,
  stored: string,
): Promise<boolean> {
  const parts = stored.split('$');
  if (
    parts.length !== 4 ||
    parts[0] !== HASH_FORMAT ||
    parts[2] === undefined ||
    parts[3] === undefined
  ) {
    // Unknown stored format → treat as failed verification, not a crash.
    return false;
  }
  const iterations = Number(parts[1]);
  if (!Number.isInteger(iterations) || iterations < 1) return false;

  try {
    const salt = fromBase64(parts[2]);
    const storedHash = fromBase64(parts[3]);
    const derived = await deriveKey(password, salt, iterations);
    return constantTimeEqual(derived, storedHash);
  } catch {
    return false;
  }
}

/** SHA-256 of an ASCII string, returned as lowercase hex (pairing codes). */
export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    encoder.encode(value) as BufferSource,
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** Uniform 6-digit pairing code via rejection sampling (no modulo bias). */
export function generatePairingCode(): string {
  let code = '';
  while (code.length < 6) {
    const bytes = crypto.getRandomValues(new Uint8Array(1));
    const byte = bytes[0]!;
    if (byte >= 250) continue; // 250 = largest multiple of 10 in [0,255]
    code += String(byte % 10);
  }
  return code;
}

export function assertAuthSecretConfigured(env: { AUTH_SECRET?: string }): void {
  if (!env.AUTH_SECRET || env.AUTH_SECRET.length < 32) {
    throw new ApiError(
      500,
      ErrorCodes.internal,
      'Server authentication is not configured.',
    );
  }
}
