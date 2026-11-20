-- FarmGuard initial schema (Stage 2).
-- Conventions: all ids are TEXT UUIDv4 generated in app code; all timestamps
-- are ISO-8601 UTC TEXT (lexicographic order == chronological order, which the
-- keyset pagination on detection_events relies on).

CREATE TABLE farmers (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  email         TEXT NOT NULL UNIQUE COLLATE NOCASE,
  -- Format: 'pbkdf2-sha256$<iterations>$<salt_b64>$<hash_b64>'
  password_hash TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE cameras (
  id                TEXT PRIMARY KEY,
  farmer_id         TEXT NOT NULL REFERENCES farmers (id) ON DELETE CASCADE,
  camera_name       TEXT NOT NULL,
  location          TEXT NOT NULL DEFAULT '',
  device_identifier TEXT NOT NULL UNIQUE,
  status            TEXT NOT NULL DEFAULT 'offline'
                    CHECK (status IN ('offline', 'online', 'monitoring')),
  last_seen_at      TEXT,
  created_at        TEXT NOT NULL
);

CREATE INDEX idx_cameras_farmer_id ON cameras (farmer_id);

CREATE TABLE detection_events (
  id                 TEXT PRIMARY KEY, -- client-supplied UUID → natural idempotency key
  farmer_id          TEXT NOT NULL REFERENCES farmers (id) ON DELETE CASCADE,
  camera_id          TEXT NOT NULL REFERENCES cameras (id) ON DELETE CASCADE,
  detection_type     TEXT NOT NULL DEFAULT 'person'
                     CHECK (detection_type IN ('person')),
  confidence         REAL NOT NULL
                     CHECK (confidence >= 0.0 AND confidence <= 1.0),
  image_object_key   TEXT,
  image_content_type TEXT,
  image_size         INTEGER CHECK (image_size IS NULL OR image_size >= 0),
  -- JSON array of up to 5 {left, top, width, height} objects, normalized 0-1.
  bounding_box       TEXT,
  source_type        TEXT NOT NULL DEFAULT 'LIVE'
                     CHECK (source_type IN ('LIVE', 'DEMO')),
  detected_at        TEXT NOT NULL,
  created_at         TEXT NOT NULL,
  viewed_at          TEXT,
  -- Client-supplied id, duplicated for explicit idempotency semantics.
  idempotency_key    TEXT NOT NULL UNIQUE
);

CREATE INDEX idx_detection_events_farmer_created
  ON detection_events (farmer_id, created_at DESC);
CREATE INDEX idx_detection_events_camera_created
  ON detection_events (camera_id, created_at DESC);

CREATE TABLE push_devices (
  id         TEXT PRIMARY KEY,
  farmer_id  TEXT NOT NULL REFERENCES farmers (id) ON DELETE CASCADE,
  fcm_token  TEXT NOT NULL UNIQUE, -- unique so the register endpoint can upsert by token
  platform   TEXT NOT NULL DEFAULT 'android' CHECK (platform IN ('android', 'ios')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_push_devices_farmer_id ON push_devices (farmer_id);

CREATE TABLE pairing_codes (
  id          TEXT PRIMARY KEY,
  farmer_id   TEXT NOT NULL REFERENCES farmers (id) ON DELETE CASCADE,
  -- SHA-256 hex of the 6-digit code; the plaintext code is never stored.
  code_hash   TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  consumed_at TEXT,
  created_at  TEXT NOT NULL
);

CREATE INDEX idx_pairing_codes_farmer_id ON pairing_codes (farmer_id);
CREATE INDEX idx_pairing_codes_code_hash ON pairing_codes (code_hash);
