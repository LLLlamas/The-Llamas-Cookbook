const FRACTION_GLYPHS: Record<string, number> = {
  '\u00BC': 0.25,
  '\u00BD': 0.5,
  '\u00BE': 0.75,
  '\u2153': 1 / 3,
  '\u2154': 2 / 3,
  '\u2155': 0.2,
  '\u2156': 0.4,
  '\u2157': 0.6,
  '\u2158': 0.8,
  '\u2159': 1 / 6,
  '\u215A': 5 / 6,
  '\u215B': 0.125,
  '\u215C': 0.375,
  '\u215D': 0.625,
  '\u215E': 0.875,
};

const COMMON_FRACTIONS: Array<[number, string]> = [
  [1 / 8, '1/8'],
  [1 / 4, '1/4'],
  [1 / 3, '1/3'],
  [3 / 8, '3/8'],
  [1 / 2, '1/2'],
  [5 / 8, '5/8'],
  [2 / 3, '2/3'],
  [3 / 4, '3/4'],
  [7 / 8, '7/8'],
];

export function parseQuantity(raw: string | undefined): number | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;

  if (trimmed.length === 1 && FRACTION_GLYPHS[trimmed] != null) {
    return FRACTION_GLYPHS[trimmed];
  }

  const mixed = trimmed.match(/^(\d+)\s+(\d+)\/(\d+)$/);
  if (mixed) {
    const whole = Number(mixed[1]);
    const num = Number(mixed[2]);
    const den = Number(mixed[3]);
    if (den === 0) return null;
    return whole + num / den;
  }

  const frac = trimmed.match(/^(\d+)\/(\d+)$/);
  if (frac) {
    const num = Number(frac[1]);
    const den = Number(frac[2]);
    if (den === 0) return null;
    return num / den;
  }

  const wholeAndGlyph = trimmed.match(/^(\d+)\s*([\u00BC-\u00BE\u2150-\u215E])$/);
  if (wholeAndGlyph) {
    const whole = Number(wholeAndGlyph[1]);
    const glyph = FRACTION_GLYPHS[wholeAndGlyph[2]];
    if (glyph != null) return whole + glyph;
  }

  const num = Number(trimmed);
  if (Number.isFinite(num)) return num;

  return null;
}

export function formatQuantity(value: number): string {
  if (!Number.isFinite(value) || value < 0) return '';
  if (value === 0) return '0';

  const whole = Math.floor(value);
  const frac = value - whole;

  if (frac < 0.02) return String(whole);
  if (frac > 0.98) return String(whole + 1);

  let best: [number, string] | null = null;
  let bestDiff = Infinity;
  for (const entry of COMMON_FRACTIONS) {
    const diff = Math.abs(frac - entry[0]);
    if (diff < bestDiff) {
      bestDiff = diff;
      best = entry;
    }
  }

  if (best && bestDiff < 0.04) {
    return whole > 0 ? `${whole} ${best[1]}` : best[1];
  }

  const rounded = Math.round(value * 100) / 100;
  return String(rounded).replace(/\.?0+$/, '');
}

export function scaleQuantity(
  original: string | undefined,
  factor: number,
): string | undefined {
  if (!original) return original;
  if (factor === 1) return original;
  const parsed = parseQuantity(original);
  if (parsed == null) return original;
  return formatQuantity(parsed * factor);
}
