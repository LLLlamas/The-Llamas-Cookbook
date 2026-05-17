// Shared quota constants, timezone helpers, and token derivation.
// Imported by parse.js, usage.js, consume.js, and activate-pro.js so
// the logic lives in exactly one place and is testable in isolation.
//
// All date-producing functions accept an optional `now` parameter so
// tests can inject a fixed timestamp without monkey-patching Date.

export const FREE_CAP = 5;
export const PRO_CAP  = 30;

// ── Timezone helpers ──────────────────────────────────────────────────────────

export function getLocalDate(tz, now = new Date()) {
  // Returns "YYYY-MM-DD" in the given IANA timezone.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(now);
}

export function getLocalYYYYMM(tz, now = new Date()) {
  // Returns "YYYYMM" (no separator) in the given IANA timezone.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit',
  }).format(now).replace('-', '');
}

export function getTimezoneOffsetMs(tz, date) {
  // Compute the UTC offset in ms for a timezone at a specific date by
  // comparing the ISO wall-clock representation at UTC vs. the given zone.
  const fmt = t => new Intl.DateTimeFormat('en-CA', {
    timeZone: t,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).formatToParts(date);
  const toParts = parts => {
    const g = type => parseInt(parts.find(p => p.type === type)?.value ?? '0', 10);
    return Date.UTC(g('year'), g('month') - 1, g('day'), g('hour'), g('minute'), g('second'));
  };
  return toParts(fmt(tz)) - toParts(fmt('UTC'));
}

export function nextLocalMidnightUTC(tz, now = new Date()) {
  // Returns a Date for the next local midnight in the given timezone.
  const localDate     = getLocalDate(tz, now);
  const [y, m, d]     = localDate.split('-').map(Number);
  const tomorrowLocal = Date.UTC(y, m - 1, d + 1, 0, 0, 0);
  const candidate     = new Date(tomorrowLocal);
  return new Date(tomorrowLocal - getTimezoneOffsetMs(tz, candidate));
}

export function nextMonthResetUTC(tz, now = new Date()) {
  // Returns a Date for 00:00 on the 1st of next month in the given timezone,
  // expressed as a UTC Date. This is when the monthly save counter resets.
  const localYM = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit',
  }).format(now);
  const [y, m]    = localYM.split('-').map(Number);
  const nextYear  = m === 12 ? y + 1 : y;
  const nextMonth = m === 12 ? 1 : m + 1;
  const firstOfNextLocal = Date.UTC(nextYear, nextMonth - 1, 1, 0, 0, 0);
  const candidate        = new Date(firstOfNextLocal);
  return new Date(firstOfNextLocal - getTimezoneOffsetMs(tz, candidate));
}

// ── Token derivation ──────────────────────────────────────────────────────────
// Mirrors LlamaProStore.appAccountToken(for:) in Swift exactly:
// SHA-256(SIWA sub UTF-8) → first 16 bytes → UUID v4 variant → UUID string.
// Both sides must produce the same token for activate-pro.js to accept it.

export async function deriveAppAccountToken(userId) {
  try {
    const encoded = new TextEncoder().encode(userId);
    const hashBuf = await crypto.subtle.digest('SHA-256', encoded);
    const bytes   = new Uint8Array(hashBuf).slice(0, 16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;  // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80;  // RFC 4122 variant
    const hex = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  } catch {
    return null;
  }
}
