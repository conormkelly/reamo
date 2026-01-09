# Design Tokens / CSS Variables Refactor

**Status:** ✅ COMPLETE (2026-01-09)
**Priority:** Medium
**Final Build Size:** 1,048.58 kB (under 1,050 kB budget)

## Completion Summary

**Phase 1:** Extracted hex colors to CSS variables and shared constants
**Phase 2:** Converted ALL Tailwind color classes to semantic tokens

### Final Statistics
- **129 semantic design tokens** defined in `@theme` block
- **Zero remaining Tailwind color classes** (`bg-gray-X`, `text-blue-X`, `ring-purple-X`, etc.)
- **~60+ component files** updated
- **36 token categories** covering all UI states and components

### Final Grep Audit (2026-01-09)
```bash
# All return zero matches:
rg "(bg|text|border|ring)-(gray|blue|green|red|yellow|purple|amber|orange|pink)-[0-9]" frontend/src
```

---

## Token Categories (129 total)

### Core UI (17 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Backgrounds** | 6 | `bg-app`, `bg-deep`, `bg-surface`, `bg-elevated`, `bg-hover`, `bg-disabled` |
| **Text** | 5 | `text-primary`, `text-secondary`, `text-tertiary`, `text-muted`, `text-disabled` |
| **Borders** | 3 | `border-default`, `border-subtle`, `border-muted` |
| **Primary (blue)** | 3 | `primary`, `primary-hover`, `primary-active` |

### REAPER-Specific (10 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Timeline** | 4 | `playhead`, `marker-default`, `region-default`, `item-default` |
| **Status** | 6 | `success`, `success-action`, `warning`, `warning-bright`, `error`, `error-action` |

### Region/Purple Theme (6 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Accent Region** | 3 | `accent-region`, `accent-region-hover`, `accent-region-dark` |
| **Region Navigation** | 3 | `region-nav`, `region-nav-hover`, `region-nav-active` |

### Recording States (23 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Recording** | 8 | `record`, `record-text`, `record-dim`, `record-dim-50`, `record-hover`, `record-hover-70`, `record-ring`, `record-ring-dim` |
| **Recording Actions** | 15 | Scrap (5), Retake (5), Keep (5) - bg, hover, border, text, text-hover each |

### Network & Connection (6 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Network Quality** | 6 | `network-optimal`, `network-good`, `network-moderate`, `network-poor`, `network-degraded`, `network-reconnecting` |

### Timeline Editing (17 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Selection/Insert** | 3 | `selection-preview`, `selection-border`, `insert-indicator` |
| **Delta Display** | 6 | `delta-positive-bg/text/border`, `delta-negative-bg/text/border` |
| **Count-In** | 6 | `count-in-record-bg/text/hover`, `count-in-play-bg/text/hover` |
| **Sync** | 2 | `sync-border`, `sync-text` |

### Track Controls (15 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Level Meter** | 4 | `meter-clip`, `meter-hot`, `meter-good`, `meter-low` |
| **Fader/Pan** | 4 | `control-ring`, `control-indicator`, `control-indicator-selected`, `fader-fill` |
| **Solo** | 2 | `solo`, `solo-text` |
| **Monitor** | 2 | `monitor-auto-bg`, `monitor-auto-text` |
| **Toggle** | 3 | `toggle-yellow`, `toggle-yellow-hover`, `toggle-yellow-text` |

### Warnings & Errors (18 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Memory Warning** | 5 | `memory-warning-bg/icon/text/btn/btn-hover` |
| **External Change** | 7 | `external-border/text`, `external-bar-bg/border/text`, `external-btn/btn-hover` |
| **Error Display** | 3 | `error-display-bg/border/text` |
| **Counter** | 2 | `counter-warning`, `counter-error` |
| **Error Text** | 1 | `error-text` |

### Interactive States (17 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Focus** | 2 | `focus-ring`, `focus-border` |
| **Selection** | 2 | `row-selected-bg`, `row-selected-border` |
| **Delete Button** | 6 | `delete-text/text-hover`, `delete-bg/bg-hover`, `delete-border`, `delete-dim-bg` |
| **Drag & Drop** | 3 | `drag-target-ring`, `edit-mode-ring`, `pending-ring` |
| **Pending Changes** | 4 | `pending-bg/border/dot/text` |

### Miscellaneous (8 tokens)
| Category | Count | Tokens |
|----------|-------|--------|
| **Metronome** | 3 | `metronome`, `metronome-bg`, `metronome-hover` |
| **Info/Accent** | 2 | `info`, `info-muted` |
| **Badges** | 2 | `midi-badge`, `locked` |
| **Waveform** | 1 | `waveform-selected-ring` |

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

---

# Phase 2: Tailwind Color Consolidation

**Status:** IN PROGRESS
**Scope:** ~400 Tailwind color class replacements across 60+ files
**Current bundle:** 1,048.66 kB (target: ≤1,050 kB)

## Goal

Consolidate scattered Tailwind color classes into a semantic design system. Instead of using arbitrary shades like `bg-gray-700`, `bg-gray-800`, `bg-gray-900`, we define purpose-based tokens that make the design intent clear and maintainable.

---

## Discovery: Full Tailwind Color Audit

### Gray Scale Usage (Most Common Pattern)

| Class | Count | Current Purpose | Proposed Semantic Token |
|-------|-------|-----------------|-------------------------|
| `bg-gray-950` | ~20 | App/view root backgrounds | `--color-bg-app` ✅ (already defined) |
| `bg-gray-900` | ~60 | Containers, modals, inputs, deep surfaces | `--color-bg-deep` |
| `bg-gray-800` | ~80 | Cards, elevated surfaces, pills, info bars | `--color-bg-surface` ✅ |
| `bg-gray-700` | ~100 | Buttons, interactive elements, toolbar items | `--color-bg-elevated` ✅ / `--color-bg-interactive` |
| `bg-gray-600` | ~30 | Hover states, active backgrounds | `--color-bg-hover` ✅ |
| `bg-gray-500` | ~10 | Disabled states, stop button active | `--color-bg-disabled` |
| `text-gray-300` | ~40 | Secondary interactive text (buttons, links) | `--color-text-secondary` ✅ |
| `text-gray-400` | ~80 | Labels, secondary info, timestamps | `--color-text-tertiary` |
| `text-gray-500` | ~50 | Placeholders, muted text, disabled text | `--color-text-muted` ✅ |
| `text-gray-600` | ~15 | Heavily muted, disabled controls | `--color-text-disabled` |
| `border-gray-600` | ~40 | Input borders, card borders | `--color-border-default` |
| `border-gray-700` | ~60 | Section dividers, modal borders | `--color-border-subtle` |
| `border-gray-800` | ~10 | Very subtle dividers | `--color-border-muted` |

### Status/Semantic Colors

#### Green (Success, Play, Save, Active)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `bg-green-500` | ~10 | Play button active, transport, connection good | `--color-success` ✅ |
| `bg-green-600` | ~15 | Save button, CTA buttons | `--color-success-action` |
| `bg-green-400` | ~5 | Connection indicator, selection line | `--color-success-light` |
| `text-green-400` | ~10 | Success text, enabled toggle | `--color-text-success` |
| `text-green-200/300` | ~5 | Recording actions text | `--color-text-success-subtle` |
| `border-green-400/500` | ~10 | Selection borders, success states | `--color-border-success` |

#### Red (Error, Delete, Record, Danger)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `bg-red-500` | ~10 | Record button active, error state | `--color-error` ✅ |
| `bg-red-600` | ~15 | Delete buttons, danger actions | `--color-error-action` |
| `bg-red-900/*` | ~10 | Record inactive, danger backgrounds | `--color-error-surface` |
| `text-red-400` | ~15 | Error text, delete icons, warning | `--color-text-error` |
| `text-red-200/300` | ~5 | Recording actions bar text | `--color-text-error-subtle` |
| `ring-red-500` | ~5 | Record mode ring | `--color-ring-error` |

#### Blue (Primary, Selection, Active, Focus)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `bg-blue-600` | ~50 | Primary buttons, active tabs, CTAs | `--color-primary` |
| `bg-blue-500` | ~15 | Hover states, active toggle, mute active | `--color-primary-hover` |
| `text-blue-400` | ~10 | Active links, info text | `--color-text-primary-accent` |
| `text-blue-300` | ~5 | Signed values, subtle accent | `--color-text-primary-subtle` |
| `border-blue-400/500` | ~15 | Selection borders, focus rings | `--color-border-primary` |
| `ring-blue-400/500` | ~20 | Focus rings, drag targets | `--color-ring-primary` |

#### Purple (Regions, Secondary Actions)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `bg-purple-600` | ~15 | Region buttons, add region, loop toggle | `--color-accent-region` |
| `bg-purple-500/*` | ~10 | Selected regions, region fills | `--color-accent-region-surface` |
| `bg-purple-700` | ~5 | Region navigation buttons | `--color-accent-region-dark` |
| `text-purple-200/300/400` | ~10 | Region info text | `--color-text-region` |
| `border-purple-400/500` | ~15 | Region borders, focus states | `--color-border-region` |
| `focus:border-purple-400` | ~10 | Region modal inputs focus | (use border-region) |

#### Yellow/Amber (Warning, Solo, Attention)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `bg-yellow-500` | ~5 | Solo button active, toolbar indicator | `--color-warning` ✅ |
| `bg-yellow-600` | ~3 | Mixer bypass, stronger warning | `--color-warning-action` |
| `bg-amber-900/*` | ~10 | Warning bar backgrounds | `--color-warning-surface` |
| `text-yellow-400/500` | ~10 | Warning text, sync issues | `--color-text-warning` |
| `text-amber-100/200/400` | ~10 | Memory warning text | `--color-text-warning-subtle` |
| `ring-yellow-400` | ~5 | Drag targets, attention | `--color-ring-warning` |
| `ring-amber-400` | ~5 | Pending changes indicator | `--color-ring-pending` |

#### Orange (Warning Variant, Loop, Alerts)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `bg-orange-600` | ~10 | Loop toggle active, reload button | `--color-warning-bright` ✅ |
| `text-orange-400` | ~10 | Missing region warning, external changes | `--color-text-warning-bright` |
| `border-orange-500/600` | ~5 | External change indicator | `--color-border-warning-bright` |

### Special Purpose Colors

#### Black (Full darkness)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `bg-black` | ~5 | Clock view background, overlays | Keep as-is (semantic already) |
| `bg-black/50-70` | ~25 | Modal backdrops, overlays | Keep as-is (opacity variants) |
| `text-black` | ~3 | Text on yellow/bright backgrounds | Keep as-is |

#### White (Primary text, indicators)
| Pattern | Count | Context | Proposed |
|---------|-------|---------|----------|
| `text-white` | ~150 | Primary text on dark backgrounds | `--color-text-primary` ✅ |
| `bg-white` | ~5 | Fader knob, level peak indicator | Keep as-is (literal white) |
| `bg-white/*` | ~10 | Time selection, timeline elements | Keep as-is (opacity variants) |
| `border-white` | ~15 | Selected color indicators | Keep as-is (literal white border) |
| `ring-white` | ~5 | New region indicator | Keep as-is |

---

## Consolidation Strategy

### Tier 1: Background Semantic Tokens

Map gray backgrounds to semantic purposes:

```
gray-950  →  bg-app        (view roots)
gray-900  →  bg-deep       (modals, inputs, inner containers)
gray-800  →  bg-surface    (cards, info bars, pills)
gray-700  →  bg-elevated   (buttons, interactive elements)
gray-600  →  bg-hover      (hover states)
gray-500  →  bg-disabled   (disabled elements)
```

### Tier 2: Text Semantic Tokens

```
white      →  text-primary    (main content)
gray-300   →  text-secondary  (interactive text, button labels)
gray-400   →  text-tertiary   (labels, metadata)
gray-500   →  text-muted      (placeholders, subtle info)
gray-600   →  text-disabled   (disabled controls)
```

### Tier 3: Border Semantic Tokens

```
gray-600   →  border-default  (inputs, cards)
gray-700   →  border-subtle   (dividers, sections)
gray-800   →  border-muted    (very subtle separators)
```

### Tier 4: Status Colors (Mostly Already Defined)

Keep semantic status colors but add missing variants:
- `success`, `success-action`, `success-surface`
- `error`, `error-action`, `error-surface`
- `warning`, `warning-action`, `warning-surface`
- `primary`, `primary-hover` (blue)
- `accent-region` (purple)

---

## Decisions Made

1. **Scope**: Full replacement (~400 changes) - Maximum consistency
2. **Token naming**: Flat names (`--color-bg-surface`, `--color-text-muted`)
3. **States**: Use Tailwind modifiers (`hover:bg-hover`, `active:bg-*`) with semantic base tokens
4. **Purple role**: Regions-only - keep as `--color-accent-region`

---

## Files by Change Impact

### High Impact (10+ color classes each)
- `CuesView.tsx` - ~30 color classes
- `CuesModals.tsx` - ~25 color classes
- `ToolbarEditor.tsx` - ~25 color classes
- `MarkerEditModal.tsx` - ~25 color classes
- `MarkerInfoBar.tsx` - ~20 color classes
- `ActionsSection.tsx` - ~20 color classes
- `SectionEditor.tsx` - ~20 color classes
- `NetworkStatsModal.tsx` - ~20 color classes
- `PlaylistEntryRow.tsx` - ~15 color classes
- `ClockElementWrapper.tsx` - ~15 color classes

### Medium Impact (5-10 color classes)
- `Timeline.tsx`, `TimelineModeToggle.tsx`, `RegionInfoBar.tsx`
- `ActionSearch.tsx`, `IconPicker.tsx`, `Toolbar.tsx`
- `TransportControls.tsx`, `TransportBar.tsx`, `PersistentTransport.tsx`
- `NotesView.tsx`, `ActionsView.tsx`, `MixerView.tsx`
- Various button components

### Low Impact (< 5 color classes)
- Most individual action buttons
- Simple display components

---

## Final Token Schema (Phase 2)

Add these to `@theme` in `index.css`:

```css
@theme {
  /* === EXISTING TOKENS (from Phase 1) === */
  --color-bg-app: #1a1a1a;
  --color-bg-surface: #1f2937;      /* gray-800 */
  --color-bg-elevated: #374151;     /* gray-700 */
  --color-bg-hover: #4b5563;        /* gray-600 */
  --color-text-primary: #ffffff;
  --color-text-secondary: #9ca3af;  /* gray-400 - was wrong, should be gray-300 */
  --color-text-muted: #6b7280;      /* gray-500 */
  --color-playhead: #337066;
  --color-marker-default: #dc2626;
  --color-region-default: #688585;
  --color-item-default: #646464;
  --color-success: #22c55e;
  --color-warning: #eab308;
  --color-warning-bright: #f97316;
  --color-error: #ef4444;

  /* === NEW TOKENS (Phase 2) === */

  /* Backgrounds */
  --color-bg-deep: #111827;         /* gray-900 - modals, inputs */
  --color-bg-disabled: #6b7280;     /* gray-500 - disabled elements */
  --color-bg-active: #374151;       /* gray-700 - same as elevated, for active states */

  /* Text */
  --color-text-tertiary: #d1d5db;   /* gray-300 - button/link text */
  --color-text-disabled: #4b5563;   /* gray-600 - disabled controls */
  --color-text-placeholder: #6b7280; /* gray-500 - same as muted */

  /* Borders */
  --color-border-default: #4b5563;  /* gray-600 - inputs, cards */
  --color-border-subtle: #374151;   /* gray-700 - dividers */
  --color-border-muted: #1f2937;    /* gray-800 - very subtle */

  /* Primary (blue) - for main actions */
  --color-primary: #2563eb;         /* blue-600 */
  --color-primary-hover: #3b82f6;   /* blue-500 */
  --color-primary-active: #1d4ed8;  /* blue-700 */

  /* Region accent (purple) - regions, loop, secondary actions */
  --color-accent-region: #9333ea;   /* purple-600 */
  --color-accent-region-hover: #a855f7;  /* purple-500 */
  --color-accent-region-dark: #7c3aed;   /* purple-700 */

  /* Status variants */
  --color-success-action: #16a34a;  /* green-600 - save buttons */
  --color-error-action: #dc2626;    /* red-600 - delete buttons */
}
```

---

## Replacement Mapping

### Backgrounds
| Tailwind Class | Semantic Token | Usage |
|----------------|----------------|-------|
| `bg-gray-950` | `bg-bg-app` | View roots |
| `bg-gray-900` | `bg-bg-deep` | Modals, inputs, inner containers |
| `bg-gray-800` | `bg-bg-surface` | Cards, info bars, pills |
| `bg-gray-700` | `bg-bg-elevated` | Buttons, interactive elements |
| `bg-gray-600` | `bg-bg-hover` | Hover states |
| `bg-gray-500` | `bg-bg-disabled` | Disabled elements |
| `bg-blue-600` | `bg-primary` | Primary buttons, active tabs |
| `bg-blue-500` | `bg-primary-hover` | Hover on primary |
| `bg-green-600` | `bg-success-action` | Save buttons |
| `bg-green-500` | `bg-success` | Play active, connected |
| `bg-red-600` | `bg-error-action` | Delete buttons |
| `bg-red-500` | `bg-error` | Record active, error state |
| `bg-purple-600` | `bg-accent-region` | Region buttons |
| `bg-purple-500` | `bg-accent-region-hover` | Region hover |

### Text
| Tailwind Class | Semantic Token | Usage |
|----------------|----------------|-------|
| `text-white` | `text-text-primary` | Main content |
| `text-gray-300` | `text-text-tertiary` | Button labels, interactive text |
| `text-gray-400` | `text-text-secondary` | Labels, metadata |
| `text-gray-500` | `text-text-muted` | Placeholders, subtle |
| `text-gray-600` | `text-text-disabled` | Disabled controls |

### Borders
| Tailwind Class | Semantic Token | Usage |
|----------------|----------------|-------|
| `border-gray-600` | `border-border-default` | Inputs, cards |
| `border-gray-700` | `border-border-subtle` | Dividers, sections |
| `border-gray-800` | `border-border-muted` | Very subtle |

### Keep As-Is (don't replace)
- `bg-black`, `bg-black/*` - backdrop overlays
- `text-black` - text on bright backgrounds
- `bg-white`, `bg-white/*` - literal white elements
- `border-white`, `ring-white` - selection indicators
- Focus rings (`ring-blue-*`, `ring-purple-*`) - keep specific
- Opacity variants with `/` syntax

---

## Implementation Order

### Step 1: Add New Tokens to index.css
Add the Phase 2 tokens to the `@theme` block.

### Step 2: Fix text-secondary (CORRECTION)
Current `--color-text-secondary` is gray-400 (#9ca3af) but should be gray-300 (#d1d5db).
Rename current to `--color-text-tertiary` and make `--color-text-secondary` be gray-300.

Actually, let's keep simpler:
- `text-primary` = white
- `text-secondary` = gray-300 (interactive text)
- `text-tertiary` = gray-400 (labels)
- `text-muted` = gray-500 (subtle)
- `text-disabled` = gray-600

### Step 3: Update Components (by impact)

**Batch 1 - Highest Impact:** ✅ COMPLETE
1. `CuesView.tsx`
2. `CuesModals.tsx`
3. `ToolbarEditor.tsx`
4. `MarkerEditModal.tsx`
5. `MarkerInfoBar.tsx`

**Batch 2 - High Impact:** ✅ COMPLETE
6. `ActionsSection.tsx`
7. `SectionEditor.tsx`
8. `NetworkStatsModal.tsx`
9. `PlaylistEntryRow.tsx`
10. `NotesView.tsx`

**Batch 3 - Medium Impact:** ✅ COMPLETE
11. `RegionInfoBar.tsx`
12. `ActionSearch.tsx`
13. `IconPicker.tsx`
14. `Toolbar.tsx`
15. `ActionsView.tsx`

**Batch 4 - Transport/Track:** ✅ COMPLETE
16. Button components (ActionButton, ToggleButton, etc.)
17. Transport components
18. Track components

**Batch 5 - Remaining:** PARTIAL
19. Timeline components (partial)
20. Clock components (partial)
21. Studio components (partial)
22. Any remaining files

**Batch 6 - Grep Audit Remaining:** PENDING
See grep audit below for full list of remaining files.

**Current Build:** 1,048.66 kB (under 1,050 kB target)

### Step 4: Verification
- Run `npm run build` after each batch
- Visual check in browser
- Ensure bundle stays under 1,050 kB

---

## Risk Mitigation

1. **Test after each batch** - Don't proceed if build fails
2. **Keep Tailwind defaults** - Don't use `--color-*: initial;`
3. **Preserve hover/active/disabled** - These use Tailwind modifiers, not tokens
4. **Skip opacity variants** - `bg-white/70`, `bg-black/60` stay as-is

---

## Success Criteria

- [ ] All gray-X background classes replaced with semantic tokens
- [ ] All gray-X text classes replaced with semantic tokens
- [ ] All gray-X border classes replaced with semantic tokens
- [ ] Primary (blue) actions use `--color-primary` tokens
- [ ] Region (purple) elements use `--color-accent-region` tokens
- [ ] Bundle size ≤ 1,050 kB
- [ ] Build passes with no errors
- [ ] **Final grep shows zero remaining gray-X classes**

---

## Grep Audit Process

**Run after each batch to track progress:**
```bash
# Count remaining gray-X classes
rg "bg-gray-[0-9]+|text-gray-[0-9]+|border-gray-[0-9]+" frontend/src -c

# List files with remaining classes
rg "bg-gray-[0-9]+|text-gray-[0-9]+|border-gray-[0-9]+" frontend/src -l
```

### Latest Grep Audit (2026-01-09)

**Remaining files with gray-X classes: 45 files**

| Category | Files | Status |
|----------|-------|--------|
| App/Views | App.tsx, TimelineView.tsx, MixerView.tsx | Pending |
| Clock | BpmTimeSigDisplay.tsx, TimeDisplay.tsx, TransportControls.tsx | Pending |
| Items Timeline | ItemsTimeline.tsx, ItemInfoBar.tsx | Pending |
| Track | PanKnob.tsx, Fader.tsx, LevelMeter.tsx, TrackFilter.tsx, MonitorButton.tsx | Pending |
| Modals | DeleteRegionModal.tsx, AddRegionModal.tsx, MakeSelectionModal.tsx, ReorderSectionsModal.tsx | Pending |
| Actions | TapTempoButton.tsx, TimeSignatureButton.tsx, SaveButton.tsx, UndoRedoButtons.tsx, MixerButtons.tsx | Pending |
| Toolbar | ColorPickerInput.tsx, ToolbarButton.tsx, LazyIconPicker.tsx | Pending |
| Timeline | TimelineRegions.tsx, TimelineMarkers.tsx, TimelinePlayhead.tsx, RegionEditActionBar.tsx | Pending |
| Studio | MixerSection.tsx, CollapsibleSection.tsx, TimelineSection.tsx, VirtualizedTrackList.tsx | Pending |
| Other | SettingsMenu.tsx, TabBar.tsx, Toast.tsx, TextSizeControl.tsx, PersistentTransport.tsx, MemoryWarningBar.tsx, ErrorBoundary.tsx, RegionDisplay.tsx, MarkerNavigation.tsx, Transport/TimeDisplay.tsx | Pending |
