-- Stage 8: global rate limiting for pairing-code redemption.
--
-- The per-code attempt counter (pairing_codes.attempts) only ever fires when
-- a guessed code happens to match a stored row; a brute-forcer spraying
-- random 6-digit codes hits no row at all and stays invisible to it. This
-- table backs a global per-IP and per-device windowed counter instead.
-- Keys are SHA-256 hex digests of 'ip:<address>' / 'dev:<device_identifier>'
-- so no raw IP or device id is ever stored.
--
-- Pruning: rows older than their window are semantically dead and are reset
-- (not deleted) on the next hit; a scheduled cleanup can delete stale rows
-- later without any correctness impact.

CREATE TABLE IF NOT EXISTS rate_limit_windows (
  key          TEXT PRIMARY KEY,
  -- ISO-8601 UTC TEXT, start of the currently counted window.
  window_start TEXT NOT NULL,
  -- Attempts counted in the current window; saturates at the route's limit.
  count        INTEGER NOT NULL
);
