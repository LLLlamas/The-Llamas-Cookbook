import { describe, it, expect } from 'vitest';
import { isClean, check, sanitizedOr } from '../lib/moderation.js';

describe('content moderation — clean names pass', () => {
  const clean = [
    'Weekend Shop',
    'Taco Night',
    'Grandma\'s Sunday Sauce',
    // Scunthorpe-problem / culinary false positives that must NOT trip:
    'Shiitake Mushroom Soup',
    'Sea Bass Ceviche',
    'Cumin Lamb Stew',
    'Scunthorpe Pork Pie',
    'Sussex Pond Pudding',
    'Coq au Vin',
    'Cock-a-leekie Soup',
    'Hummus & Pita',
    'Mussels Mariniere',
    // Mild words we deliberately don't block (legit recipe names):
    "Hell's Kitchen Chili",
    'What the Cluck Wings',
    'Mac n Cheese',
  ];
  for (const name of clean) {
    it(`allows "${name}"`, () => {
      expect(isClean(name)).toBe(true);
    });
  }
});

describe('content moderation — bad names are blocked', () => {
  const blocked = [
    'fuck',
    'My Bitch List',
    'this is bullshit',
    'asshole special',
    // Evasions the normalizer must defeat:
    'F.U.C.K.',          // separator squashing
    'sh1t list',         // leetspeak 1 -> i
    'a$$hole',           // leetspeak $ -> s
    'fuuuuck off',       // repeated-char padding
    'F U C K',           // spaced letters
    // Representative slurs (the set also covers racial slurs):
    'you retard',
    'faggot',
  ];
  for (const name of blocked) {
    it(`blocks "${name}"`, () => {
      expect(isClean(name)).toBe(false);
    });
  }
});

describe('content moderation — check() detail + sanitizedOr', () => {
  it('reports the matched term', () => {
    const result = check('what the fuck');
    expect(result.clean).toBe(false);
    expect(result.matched).toBe('fuck');
  });

  it('treats empty / nullish input as clean', () => {
    expect(isClean('')).toBe(true);
    expect(isClean('   ')).toBe(true);
    expect(isClean(null)).toBe(true);
    expect(isClean(undefined)).toBe(true);
  });

  it('sanitizedOr passes clean text through and replaces dirty text', () => {
    expect(sanitizedOr('Taco Night', 'A recipe')).toBe('Taco Night');
    expect(sanitizedOr('fuck', 'A recipe')).toBe('A recipe');
  });
});
