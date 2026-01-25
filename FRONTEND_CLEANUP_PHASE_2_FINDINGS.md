# Frontend Cleanup Phase 2: Spacing Token System

**Date:** 2025-01-25
**Scope:** Analyze spacing usage across `frontend/src/` and propose semantic spacing tokens

---

## 1. Current State Analysis

### 1.1 Spacing Class Frequency

Based on grep analysis of all `.tsx` files in `frontend/src/`:

#### Padding Classes (Most Common)
| Class | Approx Count | Primary Use Cases |
|-------|-------------|-------------------|
| `p-2` | ~60+ | Icon buttons, small controls |
| `p-3` | ~45+ | Content areas, view containers, cards |
| `p-4` | ~40+ | Modal content, panels, forms |
| `p-1` | ~25+ | Minimal padding (toggles, pills) |
| `p-1.5` | ~20+ | Small buttons, icon buttons |
| `p-6` | ~3 | Large containers (error modals) |
| `p-8` | ~5 | Loading/empty states |

#### Padding X/Y Combinations
| Pattern | Approx Count | Primary Use Cases |
|---------|-------------|-------------------|
| `px-3 py-2` | ~30+ | Form controls, inputs, small buttons |
| `px-4 py-2` | ~25+ | Standard buttons, modal footer buttons |
| `px-3 py-1.5` | ~20+ | Pills, tags, compact buttons |
| `px-4 py-3` | ~10+ | Modal footer container |
| `px-2 py-1` | ~15+ | Tiny buttons (side rail) |
| `px-3 py-3` | ~10+ | List items, navigation items |

#### Gap Classes
| Class | Approx Count | Primary Use Cases |
|-------|-------------|-------------------|
| `gap-2` | ~80+ | General spacing (most common) |
| `gap-1` | ~45+ | Tight layouts (mixer strips, icon groups) |
| `gap-3` | ~40+ | Button groups, section content |
| `gap-1.5` | ~25+ | Icon + text combinations |
| `gap-4` | ~15+ | Section separators |

#### Space Classes
| Class | Approx Count | Primary Use Cases |
|-------|-------------|-------------------|
| `space-y-4` | ~25+ | Modal content sections (default) |
| `space-y-2` | ~15+ | Form field groups |
| `space-y-1` | ~8+ | Tight vertical lists |

#### Margin Classes (Common)
| Class | Approx Count | Primary Use Cases |
|-------|-------------|-------------------|
| `mb-2` | ~40+ | Section headers, labels |
| `mb-4` | ~35+ | Section separators |
| `mb-1` | ~30+ | Labels, helper text |
| `mb-3` | ~25+ | Form groups, subsections |
| `mt-1` | ~20+ | Helper text, secondary info |
| `mt-2` | ~15+ | Secondary content |
| `mt-3` | ~10+ | Section starts |
| `my-2` | ~5 | Divider lines |
| `my-4` | ~5 | Section dividers |

### 1.2 Top 10 Most-Used Spacing Patterns

1. **`p-2`** - Icon button padding (universal)
2. **`gap-2`** - Default flex gap
3. **`p-3`** - Panel/content padding
4. **`p-4`** - Modal content padding
5. **`px-3 py-2`** - Form control padding
6. **`px-4 py-2`** - Button padding
7. **`gap-1`** - Tight grouping (mixer, icons)
8. **`gap-3`** - Section gaps
9. **`mb-2`** - Label/header margins
10. **`space-y-4`** - Modal section spacing

### 1.3 Outliers and Inconsistencies

1. **Fractional values used inconsistently:**
   - `gap-0.5` appears rarely (TextSizeControl)
   - `p-0.5` used for pill containers
   - `py-2.5` in RecordingActionsBar (could be py-3)

2. **Arbitrary pixel values detected:**
   - `min-w-[32px]`, `min-w-[48px]` etc. in ToolbarButton sizes
   - `h-[44px]` for SecondaryPanel header (could be a token)
   - `min-h-[36px]` for FolderBreadcrumb

3. **Inconsistent button padding:**
   - `px-4 py-2` (standard)
   - `px-3 py-2` (compact)
   - `px-5 py-2.5` (RecordingActionsBar - larger)
   - `px-6 h-12` (QuickActionsPanel - fixed height)

4. **Mixed approaches for same component type:**
   - Info bars: `px-3 py-2` (MarkerInfoBar, TrackInfoBar, NavigateItemInfoBar) - consistent!
   - Modals: `p-4` (ModalContent) - consistent!
   - Menu items: `px-3 py-2` (SettingsMenu, OverflowMenu) - consistent!

---

## 2. Pattern Analysis by Component Type

### 2.1 Modals and Sheets

| Component | Container | Content | Footer |
|-----------|-----------|---------|--------|
| Modal | - | `p-4 space-y-4` | `px-4 py-3` |
| BottomSheet | - | `px-4 pb-6` | - |
| TrackDetailSheet | - | `px-4 pb-6 space-y-4` | - |
| SectionEditor | `p-4` | `p-4 space-y-4` | `p-4` |
| TimelineSettingsSheet | - | - (via ModalContent) | - |

**Pattern:** Modal content uses `p-4`, footers use `px-4 py-3`

### 2.2 Info Bars

| Component | Container Padding | Internal Gap |
|-----------|-------------------|--------------|
| MarkerInfoBar | `px-3 py-2` | `gap-2`, `gap-3` |
| RegionInfoBar | `px-3 py-2` | `gap-2`, `gap-3` |
| TrackInfoBar | `px-3 py-2` | `gap-2`, `gap-3` |
| NavigateItemInfoBar | `px-3 py-2` | `gap-2`, `gap-3` |

**Pattern:** All info bars use `px-3 py-2` - very consistent!

### 2.3 Buttons

| Button Type | Padding Pattern |
|-------------|-----------------|
| Standard button | `px-4 py-2` |
| Compact button | `px-3 py-1.5` |
| Icon button | `p-2` |
| Small icon button | `p-1.5` |
| Tiny icon button | `p-1` |
| Large action button | `px-5 py-2.5` |

### 2.4 Lists and Navigation

| Component | Item Padding | Gap Between |
|-----------|--------------|-------------|
| Settings menu items | `px-3 py-2` | implicit via block |
| Navigation panel items | `px-3 py-3` | `space-y-1` |
| FX list items | `py-3 px-3` | `space-y-2` |
| Playlist entries | `p-3 pt-4` | - |

### 2.5 View Containers

| View | Container Padding |
|------|-------------------|
| MixerView | `p-3` |
| TimelineView | `p-3` |
| ActionsView | `p-3` / `p-4 pt-0` |
| NotesView | `p-3` |
| ClockView | `p-2` / `p-3` |
| PlaylistView | `p-3` |

**Pattern:** Views consistently use `p-3` as base padding

### 2.6 Common Combinations

| Combination | Usage |
|-------------|-------|
| `px-4 py-3 border-t` | Modal footer pattern |
| `gap-1.5 text-xs` | Icon + label indicator |
| `p-3 space-y-2` | Card with stacked content |
| `gap-2 flex-wrap` | Pill/tag groups |
| `mb-4 pt-1` | Panel header with top margin |

---

## 3. Recommended Token System

> **Research Update (2025-01-25):** External design system research confirmed **Option B (Tailwind theme extension)** as the world-class approach. See `research/FRONTEND_SPACING_DESIGN.md` for full analysis of Shopify Polaris, GitHub Primer, Adobe Spectrum, Radix UI, and others.

### 3.1 Key Insight: Tailwind 4's `--spacing-*` Namespace

Tailwind 4's `@theme` directive has a **magic namespace**: any variable starting with `--spacing-` automatically generates ALL spacing utility classes.

```css
@theme {
  --spacing-modal: 1rem;  /* This single line generates: */
}
/* p-modal, px-modal, py-modal, pt-modal, pb-modal, pl-modal, pr-modal,
   m-modal, mx-modal, my-modal, mt-modal, mb-modal, ml-modal, mr-modal,
   gap-modal, gap-x-modal, gap-y-modal, w-modal, h-modal, space-x-modal,
   space-y-modal, and ALL other spacing-related utilities */
```

This means `<div class="p-modal">` works natively - no inline styles, no config changes.

### 3.2 Three-Tier Token Hierarchy (Industry Standard)

Production design systems (Shopify Polaris, GitHub Primer, Adobe Spectrum) converge on this pattern:

| Tier | Purpose | Example | Direct Use |
|------|---------|---------|------------|
| **Primitive** | Raw scale values | `--spacing-1: 0.25rem` | Rarely |
| **Semantic** | Intent-based aliases | `--spacing-modal: 1rem` | Primary |
| **Component** | Highly specific | `--spacing-fader-track: 0.25rem` | When needed |

### 3.3 Proposed Tokens for index.css

Add to `index.css` inside the existing `@theme` block:

```css
@theme {
  /* ... existing 150+ color tokens ... */

  /* =============================================================================
   * SPACING TOKENS
   * Tailwind 4's --spacing-* namespace auto-generates utility classes.
   * Usage: p-modal, px-infobar-x, gap-panel, etc.
   * ============================================================================= */

  /* --- Semantic Layout Tokens --- */
  --spacing-modal: 1rem;             /* 16px - modal content padding */
  --spacing-modal-footer-x: 1rem;    /* 16px - modal footer horizontal */
  --spacing-modal-footer-y: 0.75rem; /* 12px - modal footer vertical */
  --spacing-sheet-x: 1rem;           /* 16px - bottom sheet horizontal */
  --spacing-sheet-bottom: 1.5rem;    /* 24px - bottom sheet bottom padding */
  --spacing-view: 0.75rem;           /* 12px - view container padding */

  /* --- Semantic Component Tokens --- */
  --spacing-infobar-x: 0.75rem;      /* 12px - info bar horizontal */
  --spacing-infobar-y: 0.5rem;       /* 8px - info bar vertical */
  --spacing-menu-item-x: 0.75rem;    /* 12px - menu item horizontal */
  --spacing-menu-item-y: 0.5rem;     /* 8px - menu item vertical */
  --spacing-control: 0.5rem;         /* 8px - form control padding */

  /* --- Gap Tokens --- */
  --spacing-panel-gap: 0.5rem;       /* 8px - gap between panel items */
  --spacing-section-gap: 1rem;       /* 16px - gap between sections */
  --spacing-inline-gap: 0.5rem;      /* 8px - inline element gap */
  --spacing-tight-gap: 0.25rem;      /* 4px - tight groupings */

  /* --- Audio-Specific Tokens --- */
  --spacing-fader-track: 0.25rem;    /* 4px - fader track width */
  --spacing-meter-gap: 0.125rem;     /* 2px - meter segment gap */
  --spacing-channel-strip: 0.5rem;   /* 8px - mixer channel padding */
  --spacing-transport: 0.75rem;      /* 12px - transport control spacing */
}
```

### 3.4 Usage Examples

**Before (raw Tailwind):**
```tsx
<div className="p-4 space-y-4">Modal content</div>
<div className="px-3 py-2">Info bar</div>
<div className="p-3">View container</div>
```

**After (semantic tokens):**
```tsx
<div className="p-modal space-y-section-gap">Modal content</div>
<div className="px-infobar-x py-infobar-y">Info bar</div>
<div className="p-view">View container</div>
```

The semantic version communicates **intent** rather than arbitrary values.

---

## 4. Migration Plan

### 4.1 Phase 2A: Define Tokens (No Code Changes)

1. Add semantic spacing tokens to `index.css` @theme block
2. Extend `tailwind.config.ts` to expose tokens as utilities
3. Document token meanings in code comments

**Files to modify:**
- `frontend/src/index.css` - Add spacing tokens
- `frontend/tailwind.config.ts` - Extend spacing theme (if customizing)

### 4.2 Phase 2B: Update Core Components (High Impact)

**Priority 1: Modal System** (establishes pattern for others)
- [ModalContent.tsx:29](frontend/src/components/Modal/ModalContent.tsx#L29) - Change `p-4` to use token
- [ModalFooter.tsx:58](frontend/src/components/Modal/ModalFooter.tsx#L58) - Change `px-4 py-3` to use tokens

**Priority 2: Info Bars** (4 files, identical pattern)
- [MarkerInfoBar.tsx:190](frontend/src/components/Markers/MarkerInfoBar.tsx#L190)
- [RegionInfoBar.tsx:560](frontend/src/components/Timeline/RegionInfoBar.tsx#L560)
- [TrackInfoBar.tsx:357](frontend/src/components/Mixer/TrackInfoBar.tsx#L357)
- [NavigateItemInfoBar.tsx:353](frontend/src/components/Timeline/NavigateItemInfoBar.tsx#L353)

**Priority 3: View Containers** (establishes view pattern)
- All `*View.tsx` files using `p-3`

### 4.3 Phase 2C: Standardize Button Padding

Create button size variants in a shared style or component:
- Small: `px-3 py-1.5`
- Medium: `px-4 py-2`
- Large: `px-5 py-2.5`

Consider extracting to a `Button` component or Tailwind `@apply` preset.

### 4.4 Estimated Scope

| Category | Files | Approx Changes |
|----------|-------|----------------|
| Modal system | 3 | ~6 lines |
| Info bars | 4 | ~8 lines |
| View containers | 7 | ~7 lines |
| Menu items | 2 | ~10 lines |
| Button standardization | 30+ | ~60 lines |
| **Total** | **~45 files** | **~100 lines** |

**Risk:** Low - these are cosmetic changes that don't affect behavior.

---

## 5. Resolved Questions (from Research)

### 5.1 Token Implementation Strategy - RESOLVED

**Answer: Option B (Tailwind Theme Extension)**

The research confirmed that Tailwind 4's `--spacing-*` namespace is specifically designed for this. Variables defined with this prefix automatically generate all spacing utilities - no config changes needed.

```css
@theme {
  --spacing-modal: 1rem;  /* Generates p-modal, m-modal, gap-modal, etc. */
}
```

### 5.2 Layout Constants Integration - RESOLVED

**Answer: CSS is source of truth, TypeScript reads from CSS**

For values needed in both:
```typescript
const getSpacingToken = (tokenName: string): number => {
  const value = getComputedStyle(document.documentElement)
    .getPropertyValue(`--spacing-${tokenName}`);
  return parseFloat(value) * 16; // Convert rem to px
};
```

`layout.ts` constants for complex calculations (fader heights, panel overhead) remain separate - they're not spacing tokens, they're layout dimensions.

### 5.3 Responsive Spacing - RESOLVED

**Gotcha:** Cannot nest `@theme` inside `@media` queries.

**Solution:** Define separate tokens and use responsive utility variants:
```html
<div class="p-modal-compact md:p-modal">Responsive modal</div>
```

Or use `clamp()` for fluid scaling:
```css
--spacing-view: clamp(0.5rem, 0.25rem + 2vw, 0.75rem);
```

### 5.4 Over-Tokenization Warning

**Rule from research:** Tokenize values used **three or more times**. Single-use values stay as raw Tailwind classes.

Our audit-identified patterns (modals, info bars, views) all qualify - they appear in 3+ places each.

---

## 6. Summary

### What's Working Well

1. **Modal pattern is consistent:** `p-4` content, `px-4 py-3` footer
2. **Info bars are identical:** All use `px-3 py-2`
3. **Views use `p-3` consistently**
4. **Gap usage follows clear patterns:** `gap-1` tight, `gap-2` default, `gap-3` groups
5. **Color tokens already mature:** 150+ semantic tokens in `@theme` provide the model

### Research-Validated Approach

**Use Tailwind 4's `--spacing-*` namespace** (Option B) - not CSS variables with inline styles (Option A).

This gives us:
- Native utility classes (`p-modal`, `gap-panel-gap`) without config changes
- Consistency with our existing color token architecture
- Industry-standard three-tier hierarchy (primitive → semantic → component)

### Implementation Order

1. **Add spacing tokens to `index.css`** - see Section 3.3 for exact code
2. **Migrate high-impact components first:**
   - `ModalContent.tsx` → `p-modal`
   - `ModalFooter.tsx` → `px-modal-footer-x py-modal-footer-y`
   - Info bars (4 files) → `px-infobar-x py-infobar-y`
   - View containers → `p-view`
3. **Progressive adoption** - keep raw Tailwind for low-frequency patterns
4. **Optional: ESLint rule** to warn on raw `p-[0-9]` in new code

### Gotchas to Avoid

1. **Over-tokenization** - only tokenize values used 3+ times
2. **Responsive tokens in @theme** - doesn't work, use responsive variants instead
3. **Duplicating layout.ts values** - CSS is source of truth, JS reads via `getComputedStyle()`

---

*Phase 2 Spacing Audit - Updated with research findings from `research/FRONTEND_SPACING_DESIGN.md`*
