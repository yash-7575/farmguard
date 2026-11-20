import path from 'node:path';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

/**
 * Tests run inside the real Workers runtime (workerd via Miniflare), with
 * bindings resolved from the project's wrangler.jsonc. D1 migrations are read
 * here (Node context), injected as a test-only binding, and applied by the
 * `test/apply-migrations.ts` setup file inside the worker.
 *
 * AUTH_SECRET is a fixed test-only value (never the real secret); local dev
 * uses .dev.vars, remote uses `wrangler secret put`.
 */
export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    path.join(import.meta.dirname, 'migrations'),
  );

  return defineConfig({
    plugins: [
      cloudflareTest({
        wrangler: { configPath: './wrangler.jsonc' },
        miniflare: {
          // Test-only bindings on top of the wrangler.jsonc ones.
          bindings: {
            TEST_MIGRATIONS: migrations,
            AUTH_SECRET: 'vitest-test-only-auth-secret-0123456789abcdef',
          },
        },
      }),
    ],
    test: {
      setupFiles: ['./test/apply-migrations.ts'],
    },
  });
});
