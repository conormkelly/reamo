/**
 * The semantic z-index scale (UX_GUIDELINES.md §5) must compile to real CSS.
 *
 * Compiles index.css through the same PostCSS pipeline as the build, with the
 * same source scanning, so a scale class (z-base … z-tooltip) used in src/
 * that Tailwind can't resolve shows up here as a missing rule instead of a
 * silent `z-index: auto`. Misspelled or dynamically built class names are
 * not caught.
 */

import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import postcss, { type Root } from 'postcss';
import tailwindcss from '@tailwindcss/postcss';
import { describe, it, expect, beforeAll } from 'vitest';

const FRONTEND_DIR = resolve(import.meta.dirname, '..');
const SRC_DIR = join(FRONTEND_DIR, 'src');
const INDEX_CSS = join(SRC_DIR, 'index.css');

/** UX_GUIDELINES.md §5 */
const SCALE: Record<string, string> = {
  base: '0',
  elevated: '10',
  dropdown: '100',
  sticky: '200',
  fixed: '300',
  'modal-backdrop': '400',
  modal: '500',
  popover: '600',
  toast: '700',
  tooltip: '800',
};

const SCALE_CLASS = new RegExp(
  `(?<![\\w-])z-(${Object.keys(SCALE)
    .sort((a, b) => b.length - a.length)
    .join('|')})(?![\\w-])`,
  'g',
);

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return /\.(tsx?|jsx?)$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name) ? [path] : [];
  });
}

/** Every z-<scale> class name used in src/, e.g. "z-modal". */
function usedScaleClasses(): string[] {
  const used = new Set<string>();
  for (const file of sourceFiles(SRC_DIR)) {
    for (const match of readFileSync(file, 'utf8').matchAll(SCALE_CLASS)) {
      used.add(match[0]);
    }
  }
  return [...used].sort();
}

/** Resolves `var(--x)` chains against the custom properties declared anywhere in the sheet. */
function resolveValue(value: string, vars: Map<string, string>): string {
  const ref = /^var\((--[\w-]+)\)$/.exec(value.trim());
  if (!ref) return value.trim();
  const next = vars.get(ref[1]);
  return next === undefined ? value.trim() : resolveValue(next, vars);
}

/** Resolved z-index of the rule whose selector is exactly `.className`, or undefined if none. */
function compiledZIndex(css: Root, className: string): string | undefined {
  const vars = new Map<string, string>();
  css.walkDecls(/^--/, (decl) => {
    vars.set(decl.prop, decl.value);
  });

  let zIndex: string | undefined;
  css.walkRules((rule) => {
    if (rule.selector !== `.${className}`) return;
    rule.walkDecls('z-index', (decl) => {
      zIndex = resolveValue(decl.value, vars);
    });
  });
  return zIndex;
}

describe('semantic z-index scale', () => {
  let css: Root;

  beforeAll(async () => {
    const result = await postcss([tailwindcss({ base: FRONTEND_DIR, optimize: false })]).process(
      readFileSync(INDEX_CSS, 'utf8'),
      { from: INDEX_CSS },
    );
    css = result.root;
  }, 30_000);

  it('is used somewhere in src/ (otherwise this test proves nothing)', () => {
    expect(usedScaleClasses().length).toBeGreaterThan(0);
  });

  it('compiles every z-<scale> class used in src/ to its documented z-index', () => {
    const compiled = Object.fromEntries(
      usedScaleClasses().map((className) => [className, compiledZIndex(css, className)]),
    );
    const expected = Object.fromEntries(
      usedScaleClasses().map((className) => [className, SCALE[className.slice('z-'.length)]]),
    );
    expect(compiled).toEqual(expected);
  });
});
