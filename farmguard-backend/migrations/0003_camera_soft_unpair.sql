-- Phase 2A: Soft-unpair and token-version revocation for cameras.
-- Preserves historical detection_events and R2 image keys when a camera is
-- removed, while revoking old credentials and allowing re-pairing.
ALTER TABLE cameras ADD COLUMN unpaired_at TEXT;
ALTER TABLE cameras ADD COLUMN token_version INTEGER NOT NULL DEFAULT 1;
