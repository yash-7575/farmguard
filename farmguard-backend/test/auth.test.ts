// Auth endpoint tests: register/login/me happy paths, duplicate email,
// wrong credentials, and tampered/expired token rejection.

import { describe, expect, it } from 'vitest';
import { env } from 'cloudflare:workers';
import {
  api,
  readEnvelope,
  registerFarmer,
  testEnv,
} from './helpers';
import { signTokenPayload } from '../src/services/token';

interface Farmer {
  id: string;
  name: string;
  email: string;
}

describe('POST /api/v1/auth/register', () => {
  it('creates a farmer and returns a token', async () => {
    const res = await api('POST', '/api/v1/auth/register', {
      body: {
        name: 'Ravi Kumar',
        email: 'ravi@example.com',
        password: 'strong-pass-123',
      },
    });

    expect(res.status).toBe(201);
    const { data } = await readEnvelope<{ token: string; farmer: Farmer }>(res);
    expect(data!.token).toMatch(/.+\..+/);
    expect(data!.farmer.email).toBe('ravi@example.com');
    expect(data!.farmer.name).toBe('Ravi Kumar');
    expect(data!.farmer.id).toBeDefined();
    // Password hash never leaks.
    expect(JSON.stringify(data)).not.toContain('pbkdf2');
  });

  it('rejects a duplicate email (case-insensitive) with 409', async () => {
    await registerFarmer('dupe@example.com');

    const res = await api('POST', '/api/v1/auth/register', {
      body: { name: 'Other', email: 'DUPE@example.com', password: 'password-123' },
    });

    expect(res.status).toBe(409);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('email_taken');
  });

  it('validates field types and ranges with 400', async () => {
    for (const body of [
      { name: '', email: 'a@b.com', password: 'password-123' }, // empty name
      { name: 'x'.repeat(101), email: 'a@b.com', password: 'password-123' },
      { name: 'A', email: 'not-an-email', password: 'password-123' },
      { name: 'A', email: 'a@b.com', password: 'short' }, // < 8 chars
      { email: 'a@b.com', password: 'password-123' }, // missing name
    ]) {
      const res = await api('POST', '/api/v1/auth/register', { body });
      expect(res.status, JSON.stringify(body)).toBe(400);
      const { error } = await readEnvelope(res);
      expect(error?.code).toBe('validation_error');
    }
  });

  it('rejects malformed JSON with 400 invalid_json', async () => {
    const res = await api('POST', '/api/v1/auth/register', {
      rawBody: '{"name": "A", oops',
    });
    expect(res.status).toBe(400);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('invalid_json');
  });

  it('rejects an oversized body with 413', async () => {
    const filler = 'x'.repeat(300 * 1024);
    const res = await api('POST', '/api/v1/auth/register', {
      rawBody: `{"name": "${filler}", "email": "a@b.com", "password": "password-123"}`,
    });
    expect(res.status).toBe(413);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('payload_too_large');
  });
});

describe('POST /api/v1/auth/login', () => {
  it('logs in with valid credentials', async () => {
    await registerFarmer('login@example.com');

    const res = await api('POST', '/api/v1/auth/login', {
      body: { email: 'login@example.com', password: 'test-password-123' },
    });

    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ token: string; farmer: Farmer }>(res);
    expect(data!.farmer.email).toBe('login@example.com');
  });

  it('rejects a wrong password with the same 401 as an unknown email', async () => {
    await registerFarmer('wrongpw@example.com');

    const wrongPassword = await api('POST', '/api/v1/auth/login', {
      body: { email: 'wrongpw@example.com', password: 'wrong-password' },
    });
    const unknownEmail = await api('POST', '/api/v1/auth/login', {
      body: { email: 'ghost@example.com', password: 'whatever-password' },
    });

    expect(wrongPassword.status).toBe(401);
    expect(unknownEmail.status).toBe(401);
    const pwBody = await readEnvelope(wrongPassword);
    const ghostBody = await readEnvelope(unknownEmail);
    expect(pwBody.error?.code).toBe('invalid_credentials');
    expect(pwBody.error).toEqual(ghostBody.error); // identical envelope
  });
});

describe('GET /api/v1/auth/me', () => {
  it('returns the authenticated farmer', async () => {
    const { token, email } = await registerFarmer('me@example.com');

    const res = await api('GET', '/api/v1/auth/me', { token });
    expect(res.status).toBe(200);
    const { data } = await readEnvelope<{ farmer: Farmer }>(res);
    expect(data!.farmer.email).toBe(email);
  });

  it('rejects a missing token with 401', async () => {
    const res = await api('GET', '/api/v1/auth/me');
    expect(res.status).toBe(401);
  });

  it('rejects a tampered token with 401', async () => {
    const { token } = await registerFarmer('tamper@example.com');
    const [payload, sig] = token.split('.');
    const tampered = `${payload}.${sig!.slice(0, -2)}zz`;

    const res = await api('GET', '/api/v1/auth/me', { token: tampered });
    expect(res.status).toBe(401);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('unauthorized');
  });

  it('rejects an expired token with 401', async () => {
    const { farmerId } = await registerFarmer('expired@example.com');

    const now = Math.floor(Date.now() / 1000);
    const expired = await signTokenPayload(testEnv, {
      sub: farmerId,
      typ: 'farmer',
      iat: now - 7200,
      exp: now - 3600,
    });

    const res = await api('GET', '/api/v1/auth/me', { token: expired });
    expect(res.status).toBe(401);
    const { error } = await readEnvelope(res);
    expect(error?.code).toBe('unauthorized');
  });

  it('rejects a token signed with the wrong secret with 401', async () => {
    await registerFarmer('wrongsecret@example.com');

    const forged = await signTokenPayload(
      { AUTH_SECRET: 'a'.repeat(64) },
      {
        sub: crypto.randomUUID(),
        typ: 'farmer',
        iat: Math.floor(Date.now() / 1000),
        exp: Math.floor(Date.now() / 1000) + 3600,
      },
    );
    // `env.AUTH_SECRET` in this worker is the vitest fixture, not 'aaa…'.
    expect(env.AUTH_SECRET === 'a'.repeat(64)).toBe(false);

    const res = await api('GET', '/api/v1/auth/me', { token: forged });
    expect(res.status).toBe(401);
  });
});
