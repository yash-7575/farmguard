// Worker route tests. `SELF` runs the actual Worker via Miniflare, so the
// real wrangler.jsonc is exercised — no framework mocks.

import { describe, expect, it } from 'vitest';
import { SELF } from 'cloudflare:test';

interface ApiEnvelope<T> {
  ok: boolean;
  data?: T;
  error?: { code: string; message: string };
}

describe('GET /api/health', () => {
  it('returns an ok envelope with service status', async () => {
    const res = await SELF.fetch('https://example.com/api/health');

    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('application/json');

    const body = (await res.json()) as ApiEnvelope<{
      status: string;
      service: string;
      time: string;
    }>;
    expect(body.ok).toBe(true);
    expect(body.data?.status).toBe('ok');
    expect(body.data?.service).toBe('farmguard-backend');
    expect(body.data?.time).toBeDefined();
  });

  it('also serves the versioned /api/v1/health path', async () => {
    const res = await SELF.fetch('https://example.com/api/v1/health');
    expect(res.status).toBe(200);
    const body = (await res.json()) as ApiEnvelope<{ status: string }>;
    expect(body.ok).toBe(true);
    expect(body.data?.status).toBe('ok');
  });
});

describe('unknown routes', () => {
  it('return the consistent JSON error envelope', async () => {
    const res = await SELF.fetch('https://example.com/api/does-not-exist');

    expect(res.status).toBe(404);
    const body = (await res.json()) as ApiEnvelope<unknown>;
    expect(body.ok).toBe(false);
    expect(body.error?.code).toBe('not_found');
    expect(body.error?.message).toBeDefined();
  });

  it('reject the wrong HTTP method with 404-style JSON, never a crash', async () => {
    const res = await SELF.fetch('https://example.com/api/health', {
      method: 'POST',
      body: '{}',
    });

    expect(res.status).toBe(404);
    const body = (await res.json()) as ApiEnvelope<unknown>;
    expect(body.ok).toBe(false);
  });
});
