# Design Tokens / CSS Variables Refactor

**Status:** Not started
**Priority:** Medium
**Scope:** ~50+ hardcoded hex colors across 23 files

---

## Overview

The REAmo frontend uses hardcoded hex color values throughout the codebase instead of design tokens. This makes theming difficult, creates inconsistency, and makes it hard to ensure visual coherence.

**Goal:** Extract all semantic colors to Tailwind v4 `@theme` design tokens, then update components to use either CSS `var(--color-*)` or Tailwind utility classes like `bg-playhead`.

### Why Tailwind v4 @theme?

Tailwind v4 introduces the `@theme` directive which creates **enforceable design tokens** that:
- Define CSS custom properties automatically
- Enable Tailwind utility classes (e.g., `--color-playhead` → `bg-playhead`, `text-playhead`)
- Can be validated with `eslint-plugin-tailwindcss` to catch arbitrary values

From FRONTEND-PROD-LIST.md:
```css
@import "tailwindcss";
@theme {
  --color-*: initial; /* Reset defaults */
  --color-playhead: #337066;
  --color-marker-default: #dc2626;
  --color-surface: oklch(0.129 0.042 264.695);
}
```

### Enforcement

Add `eslint-plugin-tailwindcss` with:
- `no-custom-classname` - Detect arbitrary values outside your config
- `no-contradicting-classname` - Catch conflicting utility classes

---

## Discovery Commands

Run these from `frontend/src/` to find all hardcoded colors:

```bash
# Find all hex colors (6-digit)
rg "#[0-9a-fA-F]{6}" --type ts --type tsx -l

# Find all hex colors with context
rg "#[0-9a-fA-F]{6}" --type ts --type tsx -n

# Count occurrences per file
rg "#[0-9a-fA-F]{6}" --type ts --type tsx -c

# Find inline style objects (often contain colors)
rg "style=\{\{" --type tsx -l

# Find backgroundColor/borderColor in style props
rg "backgroundColor:|borderColor:" --type ts --type tsx -n
```

---

## Current Color Inventory

### Semantic Colors (should become tokens)

| Current Value | Usage | Proposed Token |
|--------------|-------|----------------|
| `#337066` | Playhead (REAPER's playhead color) | `--color-playhead` |
| `#dc2626` | Marker default (red-600) | `--color-marker-default` |
| `#6b7280` | Gray fallback, disabled state (gray-500) | `--color-muted` |
| `#1a1a1a` | App background | `--color-bg-app` |
| `#ffffff` | Primary text | `--color-text-primary` |
| `#374151` | Default button/toolbar bg (gray-700) | `--color-bg-button` |
| `#9ca3af` | Secondary text (gray-400) | `--color-text-secondary` |

### REAPER-Specific Colors

| Current Value | Usage | Proposed Token |
|--------------|-------|----------------|
| `#688585` | Default region color (REAPER native) | `--color-region-default` |
| `#337066` | Playhead | `--color-playhead` |

### UI State Colors

| Current Value | Usage | Proposed Token |
|--------------|-------|----------------|
| `#eab308` | Warning/connecting (yellow-500) | `--color-warning` |
| `#f97316` | Warning pulse (orange-500) | `--color-warning-bright` |
| `#22c55e` | Success/connected (green-500) | `--color-success` |
| `#ef4444` | Error/recording (red-500) | `--color-error` |

### Item Color Palette (ItemInfoBar.tsx)

These are preset colors for media items - may stay as array but could be tokenized:
```
#FF6B6B, #FFE66D, #4ECDC4, #45B7D1,
#96CEB4, #FFEAA7, #DDA0DD, #98D8C8,
#F7DC6F, #BB8FCE, #85C1E9, #F8B500
```

---

## Files to Update

### High Priority (frequently used colors)

| File | Colors Found | Notes |
|------|--------------|-------|
| `index.css` | `#1a1a1a`, `#ffffff` | Root app colors - define tokens here |
| `components/Timeline/TimelinePlayhead.tsx` | `#337066`, `#6b7280` | Playhead color used 4x |
| `components/Timeline/TimelineMarkers.tsx` | `#dc2626`, `#6b7280` | Marker colors |
| `components/Toolbar/ToolbarButton.tsx` | `#374151`, `#FFFFFF` | Button defaults |
| `views/cues/components/PlaylistEntryRow.tsx` | `#6b7280` | Fallback color |
| `views/cues/components/CuesModals.tsx` | `#6b7280` | Fallback color |

### Medium Priority

| File | Colors Found | Notes |
|------|--------------|-------|
| `components/Timeline/TimelineRegions.tsx` | `#688585` | REAPER default region |
| `components/Timeline/DeleteRegionModal.tsx` | `#6b7280` | Fallback |
| `components/Timeline/MarkerEditModal.tsx` | Various | Modal styling |
| `components/Markers/MarkerInfoBar.tsx` | Various | Marker UI |
| `components/Track/TrackStrip.tsx` | Various | Track colors |
| `components/ConnectionStatus.tsx` | `#eab308`, `#f97316` | Status indicator animation |
| `views/actions/components/ActionsSection.tsx` | `#9ca3af` | Section header |
| `views/actions/components/SectionEditor.tsx` | `#374151`, `#9ca3af` | Editor defaults |

### Lower Priority

| File | Colors Found | Notes |
|------|--------------|-------|
| `store/slices/toolbarSlice.ts` | `#000000`, `#FFFFFF`, `#374151` | Default values in types - may keep as strings |
| `components/ItemsTimeline/ItemInfoBar.tsx` | `#646464`, color palette array | Item colors |
| `App.tsx` | SVG colors for loading splash | Could tokenize or leave |
| `utils/color.ts` | `#808080` | Fallback in utility - may keep |

---

## Implementation Plan

### Phase 1: Define Tokens in index.css using @theme

Add to `index.css` after the `@import "tailwindcss";` line:

```css
@import "tailwindcss";

@theme {
  /* Reset Tailwind's default color palette to enforce our tokens */
  --color-*: initial;

  /* === Background === */
  --color-bg-app: #1a1a1a;
  --color-bg-surface: #374151;    /* gray-700 */
  --color-bg-elevated: #4b5563;   /* gray-600 */

  /* === Text === */
  --color-text-primary: #ffffff;
  --color-text-secondary: #9ca3af; /* gray-400 */
  --color-text-muted: #6b7280;     /* gray-500 */

  /* === REAPER-specific === */
  --color-playhead: #337066;
  --color-marker-default: #dc2626;  /* red-600 */
  --color-region-default: #688585;

  /* === Status === */
  --color-success: #22c55e;   /* green-500 */
  --color-warning: #eab308;   /* yellow-500 */
  --color-error: #ef4444;     /* red-500 */

  /* === Interactive === */
  --color-button-bg: #374151;
  --color-button-hover: #4b5563;
}
```

This enables both:
- CSS: `style={{ backgroundColor: 'var(--color-playhead)' }}`
- Tailwind: `className="bg-playhead text-text-primary"`

### Phase 2: Update Components (order of priority)

1. **TimelinePlayhead.tsx** - Most visible, playhead color
2. **TimelineMarkers.tsx** - Marker colors
3. **ToolbarButton.tsx** - Button defaults
4. **index.css body styles** - App background
5. **ConnectionStatus.tsx** - Status colors
6. Continue with remaining files...

### Phase 3: Audit and Cleanup

- Search for any remaining hardcoded colors
- Verify dark mode / theme compatibility (if planned)
- Update any dynamic color calculations to use tokens where appropriate

---

## Progress Tracking

**Status:** Complete
**Bundle size:** 1,021 kB (target: 1,050 kB)

### Completed

| File | Date | Notes |
|------|------|-------|
| `index.css` | 2026-01-09 | Added `@theme` block with 17 design tokens |
| `constants/colors.ts` | 2026-01-09 | NEW - Shared color palettes for markers/items |
| `TimelinePlayhead.tsx` | 2026-01-09 | `--color-playhead`, `--color-text-muted`, `--color-marker-default` |
| `TimelineMarkers.tsx` | 2026-01-09 | `--color-marker-default`, `--color-text-muted` |
| `TimelineRegions.tsx` | 2026-01-09 | Import `DEFAULT_REGION_COLOR_RGB` |
| `AddRegionModal.tsx` | 2026-01-09 | Import `DEFAULT_REGION_COLOR` |
| `RegionInfoBar.tsx` | 2026-01-09 | Import `DEFAULT_REGION_COLOR` |
| `DeleteRegionModal.tsx` | 2026-01-09 | `--color-text-muted` |
| `MarkerInfoBar.tsx` | 2026-01-09 | Import `MARKER_COLORS`, `DEFAULT_MARKER_COLOR` |
| `MarkerEditModal.tsx` | 2026-01-09 | Import `MARKER_COLORS`, use `DEFAULT_MARKER_COLOR` for fallback (FIXED palette inconsistency) |
| `ItemInfoBar.tsx` | 2026-01-09 | Import `ITEM_COLORS`, `DEFAULT_ITEM_COLOR` |
| `WaveformItem.tsx` | 2026-01-09 | Import `DEFAULT_ITEM_COLOR_RGB` |
| `ToolbarButton.tsx` | 2026-01-09 | `--color-bg-elevated`, `--color-text-primary` |
| `TrackStrip.tsx` | 2026-01-09 | `--color-text-muted`, `--color-bg-elevated`, `--color-bg-surface` |
| `ConnectionStatus.tsx` | 2026-01-09 | `--color-warning`, `--color-warning-bright` |
| `PlaylistEntryRow.tsx` | 2026-01-09 | `--color-text-muted` |
| `CuesModals.tsx` | 2026-01-09 | `--color-text-muted` |
| `ActionsSection.tsx` | 2026-01-09 | `--color-text-secondary` |
| `ToolbarEditor.tsx` | 2026-01-09 | Comment update only (hex needed for color picker) |
| `SectionEditor.tsx` | 2026-01-09 | `--color-text-secondary` for icon fallback (hex kept for color picker) |

### Skipped (intentionally)

| File | Reason |
|------|--------|
| `App.tsx` | Loading screen SVG - isolated, one-time view |
| `utils/color.ts` | Utility fallback - functional default |
| `store/slices/toolbarSlice.ts` | Comments only |
| `ItemDensityBlobs.tsx` | Specific design choice - different gray |

### Bug Fixed

**Marker palette inconsistency** - `MarkerEditModal.tsx` used -600 Tailwind variants while `MarkerInfoBar.tsx` used -500 variants. Both now import from shared `MARKER_COLORS` constant.

### Final Hex Color Audit (2026-01-09)

All remaining hex colors in the codebase are intentional and documented:

| Location | Count | Category | Reason |
|----------|-------|----------|--------|
| `index.css` @theme | 15 | Token definitions | Source of truth for design tokens |
| `constants/colors.ts` | 22 | Shared palettes | 8 MARKER_COLORS + 12 ITEM_COLORS + 2 defaults |
| `ToolbarEditor.tsx` | 3 | Color picker | Needs hex string for `<input type="color">` |
| `SectionEditor.tsx` | 1 | Color picker | Needs hex string for `<input type="color">` |
| `App.tsx` SVG | 4 | Loading screen | Isolated one-time splash screen |
| `react.svg` | 1 | Asset file | SVG asset |
| `toolbarSlice.ts` | 3 | Type comments | Documentation only |
| `utils/color.ts` | 4 | Utility docs | JSDoc examples and fallback default |
| `ItemDensityBlobs.tsx` | 1 | Comment | Explains specific color choice |

**Total: 54 hex occurrences** - All categorized, none orphaned.

---

## Notes

### Colors to NOT tokenize

- **Dynamic REAPER colors** - Colors from `reaperColorToHex()` are user-defined in REAPER, don't replace
- **Tailwind classes** - `bg-gray-700`, `text-white` etc. are fine, Tailwind handles these
- **SVG assets** - react.svg colors can stay

### Important: Do NOT use `--color-*: initial;`

The wildcard reset `--color-*: initial;` clears ALL Tailwind default colors, breaking any usage of `bg-gray-*`, `text-white`, etc. Our custom tokens are **added alongside** Tailwind's defaults, not replacing them entirely.

### ESLint Setup (optional but recommended)

After defining tokens, add enforcement:

```bash
npm install -D eslint-plugin-tailwindcss
```

```js
// eslint.config.js
import tailwindcss from 'eslint-plugin-tailwindcss';

export default [
  // ... existing config
  {
    plugins: { tailwindcss },
    rules: {
      'tailwindcss/no-custom-classname': 'warn',
      'tailwindcss/no-contradicting-classname': 'error',
    },
  },
];
```

### Testing

After each file update:
```bash
cd frontend && npm run build && npm run test
```

Build should stay under 1,050 kB. Final: 1,021 kB.

---

## Related Docs

- `research/FRONTEND_AUDIT_PROGRESS.md` - Parent audit tracking
- `research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md` - Full checklist
