/**
 * D1-backed windowed rate limiter (Stage 8).
 *
 * Why D1 and not module state: per-isolate memory caches are unreliable in
 * Workers — isolates are ephemeral, can be evicted at any moment, and a
 * request may land on any of many isolates, so an in-memory counter would
 * silently reset and undercount. D1 gives one shared, durable counter.
 *
 * Semantics of checkAndIncrement: for every key, a fixed window
 * [window_start, window_start + windowMs) counts attempts. The first attempt
 * after a window expires starts a fresh window (reset to 1). Once a key's
 * count reaches `limit`, further attempts are refused and the counter is NOT
 * incremented further (saturates at the limit, no runaway rows).
 */
import { Env } from '../types/env';

interface RateLimitRow {
  window_start: string;
  count: number;
}

/**
 * Counts one attempt against each key. Returns true only if ALL keys are
 * still under their limit after this attempt is counted.
 *
 * Read-then-write per key: the SELECT decides the verdict, the write applies
 * it (reset / increment / no-op when saturated). Sequential calls are exact —
 * N calls against the same key under one window leave count = min(N, limit).
 */
export async function checkAndIncrement(
  env: Env,
  keys: string[],
  limit: number,
  windowMs: number,
  now: Date = new Date(),
): Promise<boolean> {
  const nowIso = now.toISOString();
  const nowMs = now.getTime();
  let allAllowed = true;

  for (const key of keys) {
    const row = await env.DB.prepare(
      'SELECT window_start, count FROM rate_limit_windows WHERE key = ?',
    )
      .bind(key)
      .first<RateLimitRow>();

    const expired =
      row === null ||
      !Number.isFinite(Date.parse(row.window_start)) ||
      nowMs - Date.parse(row.window_start) > windowMs;

    if (expired) {
      // Fresh window: (re)start at 1. The upsert keeps this correct even if
      // two requests race past the same SELECT.
      await env.DB.prepare(
        `INSERT INTO rate_limit_windows (key, window_start, count)
         VALUES (?, ?, 1)
         ON CONFLICT(key) DO UPDATE SET
           window_start = excluded.window_start,
           count = 1`,
      )
        .bind(key, nowIso)
        .run();
      continue;
    }

    if (row!.count >= limit) {
      // Over the limit: refuse, and do NOT increment further.
      allAllowed = false;
      continue;
    }

    await env.DB.prepare(
      'UPDATE rate_limit_windows SET count = count + 1 WHERE key = ?',
    )
      .bind(key)
      .run();
  }

  return allAllowed;
}
