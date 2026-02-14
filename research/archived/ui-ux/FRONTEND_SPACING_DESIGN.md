# World-class spacing token architecture for Tailwind CSS 4

**Bottom line:** For your React + TypeScript + Tailwind 4 PWA, the optimal approach is **Option B: extend Tailwind's spacing scale with semantic tokens in @theme**. This leverages Tailwind 4's new CSS-first configuration to automatically generate utility classes like `p-modal` and `gap-panel` while maintaining full compatibility with your existing patterns. Production systems from Shopify Polaris to Radix UI converge on a **three-tier token hierarchy** (primitive → semantic → component-specific) with a **4px base unit**—and Tailwind 4's `--spacing-*` namespace makes this architecture native to the framework.

Your current raw classes (`p-4`, `gap-2`, `px-3 py-2`) map cleanly to this system: define semantic tokens in @theme, and Tailwind generates the utilities automatically. The migration can be progressive, starting with your already-identified patterns (modals, info bars, views).

---

## How Tailwind 4's @theme directive transforms spacing

Tailwind CSS 4 (released January 2025) replaces JavaScript configuration with **CSS-first theming via the `@theme` directive**. Variables defined with the `--spacing-*` namespace automatically generate all spacing utility classes—padding, margin, gap, width, height, and their directional variants.

```css
@import "tailwindcss";

@theme {
  /* Base unit drives numeric scale (p-1, p-2, etc.) */
  --spacing: 0.25rem;  /* 4px */
  
  /* Semantic tokens → generate p-modal, gap-panel, etc. */
  --spacing-modal: 1rem;           /* 16px - your current p-4 */
  --spacing-modal-header: 0.75rem; /* 12px */
  --spacing-info-bar-x: 0.75rem;   /* 12px - your current px-3 */
  --spacing-info-bar-y: 0.5rem;    /* 8px - your current py-2 */
  --spacing-view: 0.75rem;         /* 12px - your current p-3 */
  --spacing-panel-gap: 0.5rem;     /* 8px */
  --spacing-fader-track: 0.25rem;  /* 4px - for audio controls */
}
```

When you define `--spacing-modal: 1rem`, Tailwind 4 automatically creates `p-modal`, `px-modal`, `py-modal`, `pt-modal`, `m-modal`, `gap-modal`, `w-modal`, `h-modal`, and every other spacing-related utility. Your components then use semantic classes directly:

```html
<div class="p-modal rounded-lg">Modal content</div>
<div class="px-info-bar-x py-info-bar-y">Status: Connected</div>
<section class="p-view flex flex-col gap-panel-gap">Mixer view</section>
```

Tailwind 4 also introduces a cleaner **parentheses syntax** for arbitrary values that automatically wraps with `var()`:

```html
<!-- Old bracket syntax -->
<div class="p-[var(--spacing-modal)]">Content</div>

<!-- New Tailwind 4 parentheses syntax (preferred) -->
<div class="p-(--spacing-modal)">Content</div>
```

---

## Production design systems validate the three-tier pattern

Research across eight major design systems reveals consistent architectural patterns. All mature systems use CSS custom properties as their foundation, with semantic naming layered on top of primitive scales.

| System | Base Unit | Naming Pattern | Semantic Layer |
|--------|-----------|----------------|----------------|
| **Shopify Polaris** | 4px | `space-100`, `space-200` (multipliers) | Component tokens (`space-card-padding`) |
| **GitHub Primer** | 4px | kebab-case + functional naming | Base → functional hierarchy |
| **Adobe Spectrum** | 8px | `spectrum-component-height-100` | Medium/large scale modes |
| **Radix UI** | 4px | `space-1` to `space-9` | Global `--scaling` factor |
| **Chakra UI** | 4px | Numeric (`1`, `2`, `4`) | `defineTokens()` semantic layer |
| **Stripe** | Variable | T-shirt sizing (`medium`, `large`) | Semantic-only approach |

**Shopify Polaris** exemplifies the three-tier architecture most completely. Their primitive layer uses multiplier-based naming (`--p-space-100` = 4px base, `--p-space-400` = 16px), while semantic component tokens reference primitives (`--p-space-card-padding: var(--p-space-400)`). This separation lets them change the visual density system-wide by adjusting primitives.

**Radix UI** offers an elegant **global scaling pattern** worth considering for your audio production PWA. Their `--scaling` CSS variable (90%–110%) uniformly scales all spacing across the application:

```jsx
<Theme scaling="95%">  {/* Denser UI for compact screens */}
```

```css
.custom-component {
  width: calc(200px * var(--scaling));
}
```

This pattern is particularly valuable for audio interfaces that may need density adjustments between desktop and tablet modes.

---

## Primitive versus semantic tokens requires intentional balance

The W3C Design Tokens specification (stable release October 2025) defines **Dimension** as the token type for spacing—not a dedicated "spacing" type. This reflects the broader principle that tokens describe *what exists* (primitives) versus *how to use it* (semantic).

**Nathan Curtis (EightShapes)** articulates this as "options versus decisions": primitives provide the available options, while semantic tokens encode purposeful decisions. His recommendation: **primitives should rarely be used directly in designs**—they're the foundation that semantic tokens reference.

**Brad Frost** frames design tokens as "subatomic particles" preceding atoms in atomic design. His three-tier architecture:

- **Primitive tokens**: Raw values without context (`space.100: 8px`)
- **Semantic tokens**: Contextual application (`spacing.inset.default: {space.100}`)  
- **Component tokens**: Specific usage (`button.padding.x: {spacing.inset.default}`)

The practical rule from Nathan Curtis: **tokenize values used three or more times**. Single-use values stay as local variables; two uses may lack conviction; three uses signals token-worthiness.

For your existing patterns, this maps cleanly:

```css
@theme {
  /* Primitives (hidden from direct use) */
  --spacing-1: 0.25rem;  /* 4px */
  --spacing-2: 0.5rem;   /* 8px */
  --spacing-3: 0.75rem;  /* 12px */
  --spacing-4: 1rem;     /* 16px */
  --spacing-6: 1.5rem;   /* 24px */
  --spacing-8: 2rem;     /* 32px */
  
  /* Semantic tokens (primary consumption layer) */
  --spacing-modal: var(--spacing-4);
  --spacing-info-bar-x: var(--spacing-3);
  --spacing-info-bar-y: var(--spacing-2);
  --spacing-view: var(--spacing-3);
  --spacing-panel-gap: var(--spacing-2);
  --spacing-control-padding: var(--spacing-2);
}
```

When semantic tokens reference primitives using `var()`, use Tailwind 4's `inline` option to ensure proper resolution:

```css
@theme inline {
  --spacing-modal: var(--spacing-4);
}
```

---

## Integrating CSS tokens with your TypeScript layout constants

Your project already maintains layout constants in TypeScript for JavaScript calculations (panel heights, fader limits). The key question is source of truth—and for Tailwind 4 projects, **CSS should be authoritative** with TypeScript consuming those values.

**Pattern 1: Read CSS variables at runtime**

```typescript
const getSpacingToken = (tokenName: string): number => {
  const value = getComputedStyle(document.documentElement)
    .getPropertyValue(`--spacing-${tokenName}`);
  return parseFloat(value) * 16; // Convert rem to px
};

// Usage in your fader calculations
const modalPadding = getSpacingToken('modal'); // Returns 16
```

**Pattern 2: Style Dictionary for build-time generation**

For more sophisticated systems, Style Dictionary transforms a single JSON source into both CSS variables and TypeScript constants:

```json
// tokens/spacing.json
{
  "spacing": {
    "modal": { "$value": "16px", "$type": "dimension" },
    "fader-track": { "$value": "4px", "$type": "dimension" }
  }
}
```

```javascript
// sd.config.js
export default {
  source: ['tokens/**/*.json'],
  platforms: {
    css: {
      buildPath: 'src/styles/',
      files: [{ destination: 'tokens.css', format: 'css/variables' }]
    },
    typescript: {
      buildPath: 'src/constants/',
      files: [{ destination: 'spacing.ts', format: 'typescript/es6-declarations' }]
    }
  }
};
```

This generates synchronized outputs, eliminating drift between CSS and TypeScript.

**Pattern 3: Scoped CSS variables for dynamic components**

For components like your fader that need JavaScript-driven positioning:

```tsx
function Fader({ value, min, max }: FaderProps) {
  const position = ((value - min) / (max - min)) * 100;
  
  return (
    <div 
      className="h-full bg-surface-fader"
      style={{ '--fader-position': `${position}%` } as React.CSSProperties}
    >
      <div className="absolute bottom-(--fader-position) w-full h-fader-track bg-accent" />
    </div>
  );
}
```

This keeps layout logic in TypeScript while spacing tokens remain in CSS.

---

## Responsive spacing strategies for multi-device audio control

Audio production PWAs face unique responsive challenges—tablet users may want denser mixer views while maintaining touch-friendly targets. Three patterns from production systems apply:

**Global scaling (Radix pattern)**

Define a scaling factor that adjusts all spacing proportionally:

```css
:root {
  --ui-scale: 1;
}

@media (max-width: 768px) {
  :root {
    --ui-scale: 0.9;  /* 10% denser on tablets */
  }
}

@theme {
  --spacing-modal: calc(1rem * var(--ui-scale));
  --spacing-control-padding: calc(0.5rem * var(--ui-scale));
}
```

**Fluid spacing with clamp()**

Eliminate breakpoint jumps with continuous scaling:

```css
@theme {
  --spacing-view: clamp(0.5rem, 0.25rem + 2vw, 0.75rem);
  --spacing-panel-gap: clamp(0.375rem, 0.25rem + 1vw, 0.5rem);
}
```

The `fluid-tailwind` plugin provides shorthand syntax:

```html
<!-- Scales from p-2 to p-3 fluidly -->
<div class="~p-2/3">Mixer channel</div>
```

**Container queries for component-relative spacing**

For panels that may appear at different sizes:

```css
.mixer-panel {
  container-type: inline-size;
}

@container (min-width: 400px) {
  .channel-strip {
    padding: var(--spacing-4);
    gap: var(--spacing-3);
  }
}

@container (max-width: 399px) {
  .channel-strip {
    padding: var(--spacing-2);
    gap: var(--spacing-1);
  }
}
```

**Important limitation**: Tailwind 4's `@theme` directive cannot be nested inside `@media` queries. Define separate tokens for each breakpoint and use responsive utility variants:

```html
<div class="p-modal-compact md:p-modal">Responsive modal</div>
```

---

## Migration from raw utilities to semantic tokens

Your audit revealed consistent patterns (`p-4` for modals, `px-3 py-2` for info bars, `p-3` for views). This is the ideal starting point for progressive migration.

**Phase 1: Document and define (1-2 days)**

Map your discovered patterns to semantic tokens:

| Current Pattern | Component Type | Semantic Token |
|-----------------|----------------|----------------|
| `p-4` | Modal content | `--spacing-modal` |
| `px-3 py-2` | Info bars | `--spacing-info-bar-x/y` |
| `p-3` | Views | `--spacing-view` |
| `gap-2` | Panel layouts | `--spacing-panel-gap` |

**Phase 2: Add tokens alongside existing classes**

```css
@theme {
  --spacing-modal: 1rem;
  --spacing-info-bar-x: 0.75rem;
  --spacing-info-bar-y: 0.5rem;
  --spacing-view: 0.75rem;
  --spacing-panel-gap: 0.5rem;
}
```

**Phase 3: ESLint enforcement**

Atlassian's ESLint plugin provides `ensure-design-token-usage` and `use-tokens-space` rules. For Tailwind-specific enforcement:

```javascript
// .eslintrc.js - Custom rule to warn on raw spacing classes
{
  rules: {
    'no-restricted-syntax': ['warn', {
      selector: 'JSXAttribute[name.name="className"][value.value=/\\bp-[0-9]/]',
      message: 'Use semantic spacing tokens (p-modal, p-view) instead of raw values'
    }]
  }
}
```

**Phase 4: Gradual replacement**

Use search-and-replace or codemods to migrate:

```bash
# Simple find-replace for consistent patterns
grep -r "p-4" src/components/modals/ 
# Replace with p-modal
```

For complex migrations, Tailwind's official upgrade tool handles v3→v4 syntax changes:

```bash
npx @tailwindcss/upgrade@next
```

---

## Architecture decision matrix for your context

Given your existing 150+ color tokens in @theme and TypeScript layout constants, here's how each option fits:

| Approach | Fit for Your Project | Recommendation |
|----------|---------------------|----------------|
| **Option A: CSS vars + inline styles** | Poor | Loses Tailwind utility benefits, verbose |
| **Option B: Extend @theme spacing** | **Excellent** | Native to your existing @theme setup, auto-generates utilities |
| **Option C: Component abstractions** | Good for complex cases | Use selectively for compound patterns (e.g., `<Stack spacing="panel">`) |
| **Option D: CSS-in-JS** | Poor | Runtime overhead, conflicts with Tailwind approach |

**Primary recommendation: Option B with selective Option C**

Your complete token architecture:

```css
@import "tailwindcss";

@theme {
  /* === SPACING TOKENS === */
  
  /* Primitives (base scale, rarely used directly) */
  --spacing: 0.25rem;  /* 4px base unit */
  
  /* Semantic layout tokens */
  --spacing-modal: 1rem;
  --spacing-modal-header: 0.75rem;
  --spacing-modal-actions: 1rem;
  --spacing-view: 0.75rem;
  --spacing-panel: 0.5rem;
  --spacing-panel-gap: 0.5rem;
  
  /* Semantic component tokens */
  --spacing-info-bar-x: 0.75rem;
  --spacing-info-bar-y: 0.5rem;
  --spacing-control-padding: 0.5rem;
  --spacing-button-x: 0.75rem;
  --spacing-button-y: 0.375rem;
  
  /* Audio-specific tokens */
  --spacing-fader-track: 0.25rem;
  --spacing-meter-gap: 0.125rem;
  --spacing-channel-strip: 0.5rem;
  --spacing-transport-controls: 0.75rem;
}
```

For compound patterns, create thin component abstractions:

```tsx
// Semantic stack component for consistent vertical rhythm
interface StackProps {
  spacing?: 'panel' | 'view' | 'modal';
  children: React.ReactNode;
}

export const Stack = ({ spacing = 'panel', children }: StackProps) => (
  <div className={`flex flex-col gap-${spacing}`}>
    {children}
  </div>
);
```

---

## Common mistakes to avoid

**Over-tokenization** is the primary anti-pattern. Nate Baldwin warns that creating tokens for every possible value leads to a "taxonomy nightmare." Start with **50-100 essential tokens** and grow based on actual usage—your audit-driven approach is exactly right.

**Single-use tokens** waste cognitive overhead. If a spacing value appears only in one component with no expectation of reuse, keep it as a raw Tailwind class or local CSS variable.

**Inconsistent naming** creates confusion. Avoid mixing patterns like `spacing-10px` with `padding-small`. Your existing color token naming conventions should extend to spacing.

**Hardcoded duplicates** between CSS and TypeScript cause drift. Use CSS as source of truth, with TypeScript reading values via `getComputedStyle()` or Style Dictionary generation.

**Responsive tokens in @theme** don't work—you cannot nest `@theme` inside `@media`. Instead, define separate tokens (`--spacing-modal-compact`, `--spacing-modal`) and use responsive utility variants (`p-modal-compact md:p-modal`).

---

## Conclusion

The world-class approach for your Tailwind 4 audio production PWA is **semantic spacing tokens defined in @theme**, following the three-tier hierarchy validated by Shopify Polaris, GitHub Primer, and Adobe Spectrum. Tailwind 4's `--spacing-*` namespace automatically generates the utility classes you need (`p-modal`, `gap-panel-gap`), while your existing @theme infrastructure for color tokens provides the integration pattern.

Start with your audit findings—`p-4` becomes `--spacing-modal`, `px-3 py-2` becomes `--spacing-info-bar-x/y`, `p-3` becomes `--spacing-view`. This progressive migration preserves working code while establishing semantic meaning. For JavaScript layout calculations, read CSS variables at runtime or use Style Dictionary to generate synchronized TypeScript constants.

The critical insight from production systems: **primitives provide options, semantic tokens encode decisions**. Your modal padding isn't "16 pixels"—it's "the appropriate inset for modal content," which happens to resolve to 16px today but could evolve as your design system matures.
