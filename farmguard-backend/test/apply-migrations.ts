// Applies the project's D1 migrations to the test database.
//
// Setup files run outside the per-test storage isolation and may run more
// than once; `applyD1Migrations()` only applies un-applied migrations, so it
// is safe to call it here. The migrations array is injected as the
// TEST_MIGRATIONS binding by vitest.config.ts.
import { applyD1Migrations } from 'cloudflare:test';
import { env } from 'cloudflare:workers';

await applyD1Migrations(
  env.DB,
  env.TEST_MIGRATIONS as Parameters<typeof applyD1Migrations>[1],
);
