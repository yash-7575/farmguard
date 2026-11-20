/**
 * Worker environment bindings.
 *
 * - `DB`         D1 database `farmguard-db` (Stage 2).
 * - `AUTH_SECRET` Wrangler secret used to sign auth tokens (Stage 3). Set with
 *   `wrangler secret put AUTH_SECRET` (remote) or `.dev.vars` (local, gitignored).
 *   NEVER committed to the repository.
 * - `IMAGES`     R2 bucket `farmguard-images` (Stage 4) — private; all access
 *   goes through the authenticated routes in `routes/images.ts`.
 * - `FCM_SERVICE_ACCOUNT` Wrangler secret holding the Firebase service-account
 *   key JSON (Stage 7) — optional; when unset, push notifications are silently
 *   skipped. Set with `wrangler secret put FCM_SERVICE_ACCOUNT`; NEVER committed.
 */
export interface Env {
  DB: D1Database;
  AUTH_SECRET: string;
  IMAGES: R2Bucket;
  FCM_SERVICE_ACCOUNT?: string;
}
