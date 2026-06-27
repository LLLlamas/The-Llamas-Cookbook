import { describe, it, expect } from 'vitest';
import { renderListHTML } from '../functions/list/[id].js';

describe('shared grocery list page — security', () => {
  it('HTML-escapes a malicious item name (no script injection)', () => {
    const html = renderListHTML({
      title: 'Weekend Shop',
      items: [{ name: '<script>alert(1)</script>', quantity: '', unit: '', checked: false, outOfStock: false, substitution: '' }],
    });
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;');
  });

  it('escapes a malicious substitution note', () => {
    const html = renderListHTML({
      title: 'Taco Night',
      items: [{ name: 'milk', quantity: '1', unit: 'cup', checked: false, outOfStock: false, substitution: '"><img src=x onerror=alert(1)>' }],
    });
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;img');
  });

  it('neutralizes a profane list title via moderation', () => {
    const html = renderListHTML({ title: 'fuck this list', items: [] });
    expect(html.toLowerCase()).not.toContain('fuck');
    expect(html).toContain('Grocery List'); // fallback title
  });

  it('renders a clean list with aisle headers, check state, and swaps', () => {
    const html = renderListHTML({
      title: 'Sunday Shop',
      items: [
        { name: 'apples', quantity: '6', unit: '', aisle: 'Produce', checked: true, outOfStock: false, substitution: '' },
        { name: 'buttermilk', quantity: '1', unit: 'cup', aisle: 'Dairy & Eggs', checked: false, outOfStock: false, substitution: '1 cup milk + 1 tbsp lemon juice' },
      ],
    });
    expect(html).toContain('Sunday Shop');
    expect(html).toContain('Produce');
    expect(html).toContain('Dairy &amp; Eggs');
    expect(html).toContain('apples');
    expect(html).toContain('→ 1 cup milk + 1 tbsp lemon juice');
    expect(html).toContain('1 of 2 still to buy');
    expect(html).toContain('li class="item checked"'); // apples is checked
  });

  it('shows the all-set state when everything is checked', () => {
    const html = renderListHTML({
      title: 'Done Shop',
      items: [{ name: 'salt', quantity: '', unit: '', checked: true, outOfStock: false, substitution: '' }],
    });
    expect(html).toContain('All set');
    expect(html).toContain('progress done');
  });
});
