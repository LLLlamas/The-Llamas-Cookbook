import type { Ingredient } from '../types/recipe';
import { newId } from './ids';

type Parsed = Pick<Ingredient, 'quantity' | 'unit' | 'name'>;

const KNOWN_UNITS = new Set([
  'cup', 'cups', 'c',
  'tablespoon', 'tablespoons', 'tbsp', 'tbs', 'tb',
  'teaspoon', 'teaspoons', 'tsp', 'ts',
  'ounce', 'ounces', 'oz',
  'pound', 'pounds', 'lb', 'lbs',
  'gram', 'grams', 'g',
  'kilogram', 'kilograms', 'kg',
  'milliliter', 'milliliters', 'ml',
  'liter', 'liters', 'l',
  'clove', 'cloves',
  'pinch', 'pinches',
  'dash', 'dashes',
  'slice', 'slices',
  'can', 'cans',
  'stick', 'sticks',
]);

const QTY_PATTERN = /^(\d+\s\d+\/\d+|\d+\/\d+|\d+(?:\.\d+)?|[\u00BC-\u00BE\u2150-\u215E])$/;

export function parseIngredientLine(line: string): Parsed {
  const trimmed = line.trim();
  if (!trimmed) return { name: '' };

  const tokens = trimmed.split(/\s+/);
  let quantity: string | undefined;
  let unit: string | undefined;
  let nameStart = 0;

  if (tokens[0] && QTY_PATTERN.test(tokens[0])) {
    quantity = tokens[0];
    nameStart = 1;
    if (tokens[1] && /^\d+\/\d+$/.test(tokens[1]) && /^\d+$/.test(tokens[0])) {
      quantity = `${tokens[0]} ${tokens[1]}`;
      nameStart = 2;
    }
  }

  if (tokens[nameStart] && KNOWN_UNITS.has(tokens[nameStart].toLowerCase())) {
    unit = tokens[nameStart];
    nameStart += 1;
  }

  const name = tokens.slice(nameStart).join(' ').trim();
  return { quantity, unit, name };
}

export function parseIngredientBlock(block: string): Ingredient[] {
  const lines = block.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  return lines.map((line, index) => {
    const parsed = parseIngredientLine(line);
    return {
      id: newId(),
      order: index,
      name: parsed.name || line,
      quantity: parsed.quantity,
      unit: parsed.unit,
    };
  });
}
