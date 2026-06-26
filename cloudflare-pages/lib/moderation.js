// Server-side profanity/slur screen — the non-bypassable backstop for the
// app's content moderation. The CloudKit public DB is world-WRITABLE, so a
// client-only check (ios-native/Sources/Lib/ContentModeration.swift) can be
// sidestepped by writing records directly; anything we then render on a
// public page (the recipe OG preview, the shared grocery list) must be
// screened here too.
//
// This is a DIRECT MIRROR of ContentModeration.swift — the BLOCKED set,
// ALLOWLIST, leetspeak map, and matching rules must stay identical on both
// sides. When you edit one, edit the other.

const LEET = {
  '@': 'a', '4': 'a', '3': 'e', '1': 'i', '!': 'i',
  '0': 'o', '$': 's', '5': 's', '7': 't',
};

// Curated, intentionally non-exhaustive: clear obscenity + slurs only,
// biased away from mild words that appear in real recipe names. Stored as
// normalized base forms (lowercase, no separators).
const BLOCKED = new Set([
  // Obscenity
  'fuck', 'fucker', 'fucking', 'motherfucker', 'fuk', 'fuckface',
  'shit', 'shitty', 'bullshit', 'dipshit',
  'bitch', 'asshole', 'asshat', 'dumbass', 'jackass',
  'cunt', 'dick', 'dickhead', 'pussy', 'bastard', 'prick',
  'twat', 'wank', 'wanker', 'slut', 'whore', 'douchebag',
  'bollocks', 'arsehole',
  // Slurs (racial / homophobic / ableist) — represented stems
  'nigger', 'nigga', 'faggot', 'fag', 'retard', 'tranny',
  'chink', 'spic', 'kike', 'coon', 'wetback', 'gook',
]);

// Legit culinary / place terms that must never be flagged.
const ALLOWLIST = new Set([
  'shiitake', 'shitake', 'bass', 'seabass', 'cumin', 'scunthorpe',
  'sussex', 'mussel', 'cockle', 'coq', 'hummus', 'sake', 'dewberry',
]);

function stripDiacritics(s) {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '');
}

function normalize(text) {
  const folded = stripDiacritics(String(text == null ? '' : text)).toLowerCase();
  let out = '';
  for (const ch of folded) out += (LEET[ch] || ch);
  return out;
}

function tokensOf(s) {
  return new Set(s.split(/[^a-z]+/).filter(Boolean));
}

// Collapse every run of a repeated character to one ("fuuuck" -> "fuck").
function collapseRuns(s) {
  let out = '';
  let prev = null;
  for (const ch of s) {
    if (ch !== prev) { out += ch; prev = ch; }
  }
  return out;
}

/** @returns {{clean: boolean, matched?: string}} */
export function check(text) {
  const normalized = normalize(text);
  if (!normalized) return { clean: true };

  const sets = [tokensOf(normalized), tokensOf(collapseRuns(normalized))];
  for (const set of sets) {
    for (const token of set) {
      if (!ALLOWLIST.has(token) && BLOCKED.has(token)) {
        return { clean: false, matched: token };
      }
    }
  }
  const squashed = normalized.replace(/[^a-z]/g, '');
  if (BLOCKED.has(squashed) && !ALLOWLIST.has(squashed)) {
    return { clean: false, matched: squashed };
  }
  return { clean: true };
}

export function isClean(text) {
  return check(text).clean;
}

/**
 * Returns `text` if clean, otherwise `fallback`. Convenience for render
 * paths that want to neutralize an objectionable title/name rather than
 * fail the whole page.
 */
export function sanitizedOr(text, fallback) {
  return isClean(text) ? text : fallback;
}
