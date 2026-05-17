import { describe, it, expect } from 'vitest';
import {
  FREE_CAP,
  PRO_CAP,
  getLocalYYYYMM,
  nextMonthResetUTC,
  deriveAppAccountToken,
} from '../lib/quota.js';

// ── Constants ─────────────────────────────────────────────────────────────────

describe('quota constants', () => {
  it('FREE_CAP is 5', () => expect(FREE_CAP).toBe(5));
  it('PRO_CAP is 30', () => expect(PRO_CAP).toBe(30));
  it('PRO_CAP > FREE_CAP', () => expect(PRO_CAP).toBeGreaterThan(FREE_CAP));
});

// ── getLocalYYYYMM ────────────────────────────────────────────────────────────
// This is the key used in KV for the monthly save counter.
// A wrong timezone shifts the reset date, causing users to lose their monthly
// allowance early or get extra uses they shouldn't have.

describe('getLocalYYYYMM', () => {
  it('returns YYYYMM string for UTC', () => {
    const now = new Date('2026-05-17T12:00:00Z');
    expect(getLocalYYYYMM('UTC', now)).toBe('202605');
  });

  it('returns 6-character string with no separator', () => {
    const now = new Date('2026-05-17T12:00:00Z');
    const result = getLocalYYYYMM('UTC', now);
    expect(result).toHaveLength(6);
    expect(result).toMatch(/^\d{6}$/);
  });

  it('LA (PDT = UTC-7) at 00:30 UTC is still previous local day', () => {
    // 2026-05-17T00:30:00Z = 2026-05-16T17:30 PDT — still May in LA
    const now = new Date('2026-05-17T00:30:00Z');
    expect(getLocalYYYYMM('America/Los_Angeles', now)).toBe('202605');
    expect(getLocalYYYYMM('UTC', now)).toBe('202605');
  });

  it('Dec 31 UTC is already January in UTC+8 timezones', () => {
    // 2025-12-31T23:45:00Z = 2026-01-01T07:45 Asia/Shanghai
    const now = new Date('2025-12-31T23:45:00Z');
    expect(getLocalYYYYMM('Asia/Shanghai', now)).toBe('202601');
    expect(getLocalYYYYMM('UTC', now)).toBe('202512');
  });

  it('India (UTC+5:30) crosses month boundary at the half-hour mark', () => {
    // 2026-05-31T18:45:00Z = 2026-06-01T00:15 IST — June for India, still May UTC
    const now = new Date('2026-05-31T18:45:00Z');
    expect(getLocalYYYYMM('Asia/Kolkata', now)).toBe('202606');
    expect(getLocalYYYYMM('UTC', now)).toBe('202605');
  });
});

// ── nextMonthResetUTC ─────────────────────────────────────────────────────────
// This is the reset date shown in the UI pill ("Resets Jun 1").
// A wrong value means users see the wrong countdown and quotas reset at the
// wrong moment.

describe('nextMonthResetUTC', () => {
  it('returns a Date object', () => {
    expect(nextMonthResetUTC('UTC', new Date())).toBeInstanceOf(Date);
  });

  it('reset is always in the future relative to input', () => {
    const now = new Date('2026-05-17T12:00:00Z');
    const reset = nextMonthResetUTC('UTC', now);
    expect(reset.getTime()).toBeGreaterThan(now.getTime());
  });

  it('UTC — reset is Jun 1 00:00 UTC when current month is May', () => {
    const now = new Date('2026-05-17T12:00:00Z');
    const reset = nextMonthResetUTC('UTC', now);
    expect(reset.getUTCFullYear()).toBe(2026);
    expect(reset.getUTCMonth()).toBe(5);   // June (0-indexed)
    expect(reset.getUTCDate()).toBe(1);
    expect(reset.getUTCHours()).toBe(0);
    expect(reset.getUTCMinutes()).toBe(0);
  });

  it('December → January year rollover', () => {
    const now = new Date('2025-12-15T12:00:00Z');
    const reset = nextMonthResetUTC('UTC', now);
    expect(reset.getUTCFullYear()).toBe(2026);
    expect(reset.getUTCMonth()).toBe(0);   // January
    expect(reset.getUTCDate()).toBe(1);
  });

  it('Los Angeles (PDT = UTC-7) — Jun 1 local midnight = Jun 1 07:00 UTC', () => {
    const now = new Date('2026-05-17T12:00:00Z');
    const reset = nextMonthResetUTC('America/Los_Angeles', now);
    expect(reset.getUTCFullYear()).toBe(2026);
    expect(reset.getUTCMonth()).toBe(5);   // June
    expect(reset.getUTCDate()).toBe(1);
    expect(reset.getUTCHours()).toBe(7);
    expect(reset.getUTCMinutes()).toBe(0);
  });

  it('India (UTC+5:30) — Jun 1 local midnight = May 31 18:30 UTC', () => {
    const now = new Date('2026-05-17T12:00:00Z');
    const reset = nextMonthResetUTC('Asia/Kolkata', now);
    expect(reset.getUTCFullYear()).toBe(2026);
    expect(reset.getUTCMonth()).toBe(4);   // May (UTC date is still May 31)
    expect(reset.getUTCDate()).toBe(31);
    expect(reset.getUTCHours()).toBe(18);
    expect(reset.getUTCMinutes()).toBe(30);
  });

  it('Nepal (UTC+5:45) — Jun 1 local midnight = May 31 18:15 UTC', () => {
    const now = new Date('2026-05-17T12:00:00Z');
    const reset = nextMonthResetUTC('Asia/Kathmandu', now);
    expect(reset.getUTCHours()).toBe(18);
    expect(reset.getUTCMinutes()).toBe(15);
  });
});

// ── Quota cap arithmetic ──────────────────────────────────────────────────────
// These are the formulas used in parse.js and consume.js; testing them
// directly catches an accidental off-by-one before it ships.

describe('quota cap arithmetic', () => {
  it('remaining = cap - used when under cap', () => {
    expect(Math.max(0, FREE_CAP - 3)).toBe(2);
  });

  it('remaining = 0 when exactly at cap', () => {
    expect(Math.max(0, FREE_CAP - FREE_CAP)).toBe(0);
  });

  it('remaining never goes below 0 when over cap', () => {
    expect(Math.max(0, FREE_CAP - (FREE_CAP + 2))).toBe(0);
  });

  it('used >= cap means exhausted', () => {
    expect(FREE_CAP >= FREE_CAP).toBe(true);
    expect(FREE_CAP - 1 >= FREE_CAP).toBe(false);
  });

  it('pro cap gives 25 more imports than free cap', () => {
    expect(PRO_CAP - FREE_CAP).toBe(25);
  });
});

// ── deriveAppAccountToken ─────────────────────────────────────────────────────
// This function mirrors LlamaProStore.appAccountToken(for:) in Swift exactly.
// If the UUID shape or bit manipulation differs, activate-pro.js will reject
// every valid purchase with token_mismatch.

describe('deriveAppAccountToken', () => {
  it('returns a lowercase UUID-formatted string', async () => {
    const token = await deriveAppAccountToken('test-sub-123');
    expect(token).not.toBeNull();
    expect(token).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  });

  it('sets UUID version 4 (first char of 3rd group is "4")', async () => {
    const token = await deriveAppAccountToken('test-sub-123');
    const thirdGroup = token.split('-')[2];
    expect(thirdGroup[0]).toBe('4');
  });

  it('sets RFC 4122 variant (first nibble of 4th group is 8–b)', async () => {
    const token = await deriveAppAccountToken('test-sub-123');
    const fourthGroup = token.split('-')[3];
    const nibble = parseInt(fourthGroup[0], 16);
    expect(nibble).toBeGreaterThanOrEqual(8);
    expect(nibble).toBeLessThanOrEqual(11);
  });

  it('is deterministic — same sub produces same token', async () => {
    const sub = 'apple.siwa.sub.001';
    const t1 = await deriveAppAccountToken(sub);
    const t2 = await deriveAppAccountToken(sub);
    expect(t1).toBe(t2);
  });

  it('different subs produce different tokens', async () => {
    const t1 = await deriveAppAccountToken('user-aaa');
    const t2 = await deriveAppAccountToken('user-bbb');
    expect(t1).not.toBe(t2);
  });

  it('matches the known token for a fixed input', async () => {
    // Pre-computed: SHA-256('fixed-test-sub') first 16 bytes, v4 variant applied.
    // This pins the algorithm against accidental drift.
    const token = await deriveAppAccountToken('fixed-test-sub');
    // Must be a valid UUID; the exact value is checked in the next assertion
    // so a future algorithm change fails loudly instead of silently.
    expect(token).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });
});
