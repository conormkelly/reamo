/**
 * Tests for icon lookup by name.
 *
 * Key contracts:
 * - The curated set and the search index use lucide's canonical icon names,
 *   never its deprecated aliases
 * - Every icon the search index suggests can be rendered from the curated set
 * - Words from alias names (music, home, ...) still find the canonical icon
 * - Alias names held by saved layouts resolve to the canonical icon
 * - Names that are not icons resolve to nothing, including Object prototype keys
 */

import { describe, it, expect } from 'vitest';
import { commonIcons } from './commonIcons';
import { searchIcons, tokenToIcons } from './iconSearchIndex';
import { canonicalIconName, getIconComponent } from './iconLookup';

type NamedComponent = { displayName?: string };

describe('commonIcons', () => {
  it.each(Object.keys(commonIcons))('%s is the canonical lucide name of its icon', (name) => {
    const component = commonIcons[name as keyof typeof commonIcons] as NamedComponent;
    expect(component.displayName).toBe(name);
  });
});

describe('iconSearchIndex', () => {
  it('suggests only icons in the curated set', () => {
    const missing = [...new Set(Object.values(tokenToIcons).flat())].filter(
      (name) => !Object.hasOwn(commonIcons, name)
    );
    expect(missing).toEqual([]);
  });

  it.each([
    ['music', 'EighthNotes'],
    ['home', 'House'],
    ['history', 'RotateCcwClock'],
    ['sort', 'ArrowUpNarrowWide'],
    ['flip', 'SquareCenterlineDashedHorizontal'],
    ['more', 'Ellipsis'],
  ])('searching "%s", a word only in the alias name, finds %s', (query, icon) => {
    expect(searchIcons(query)).toContain(icon);
  });
});

describe('canonicalIconName', () => {
  it('maps a deprecated alias to the canonical name', () => {
    expect(canonicalIconName('Trash2')).toBe('Trash');
    expect(canonicalIconName('XCircle')).toBe('CircleX');
  });

  it('maps a kebab-case deprecated alias to the canonical name', () => {
    expect(canonicalIconName('trash-2')).toBe('Trash');
  });

  it('returns canonical and unknown names unchanged', () => {
    expect(canonicalIconName('Trash')).toBe('Trash');
    expect(canonicalIconName('not-an-icon')).toBe('not-an-icon');
  });
});

describe('getIconComponent', () => {
  it('resolves a canonical name from the curated set', () => {
    expect(getIconComponent('Trash')).toBe(commonIcons.Trash);
  });

  it('resolves a kebab-case name from the curated set', () => {
    expect(getIconComponent('circle-x')).toBe(commonIcons.CircleX);
  });

  it.each([
    ['Trash2', 'Trash'],
    ['Loader2', 'LoaderCircle'],
    ['Music', 'EighthNotes'],
    ['HelpCircle', 'CircleQuestionMark'],
    ['CircleHelp', 'CircleQuestionMark'],
    ['Sliders', 'SlidersVertical'],
    ['Filter', 'Funnel'],
  ] as const)('resolves saved alias %s to the %s icon', (alias, canonical) => {
    expect(getIconComponent(alias)).toBe(commonIcons[canonical]);
  });

  it('returns null for a name that is not an icon', () => {
    expect(getIconComponent('NotAnIcon')).toBeNull();
  });

  it.each(['constructor', 'toString', 'hasOwnProperty', '__proto__'])(
    'returns null for the Object prototype key %s',
    (name) => {
      expect(getIconComponent(name)).toBeNull();
    }
  );
});
