// Test-only ambient types for bindings injected by vitest.config.ts
// (miniflare.bindings) that are not part of the real worker's Env.
declare namespace Cloudflare {
  interface Env {
    TEST_MIGRATIONS: unknown;
  }
}
