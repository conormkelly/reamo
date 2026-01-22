# Responsive Architecture Findings

This document captures findings, discoveries, and notes from the responsive architecture implementation. Agents should update this file after each phase with important context that may be useful if context is lost.

---

## Phase 1: Foundation (Complete)

### Tailwind v4 Configuration

**Finding**: The project uses Tailwind v4 (`tailwindcss: ^4.1.17`) which has significant changes from v3:
- Configuration uses CSS-based `@theme` directive in `index.css` for design tokens
- The `tailwind.config.js` still works for `theme.extend` but is more limited
- Container queries are built-in (no plugin needed)

**Action Taken**: Added z-index scale to `tailwind.config.js` under `theme.extend.zIndex`. The semantic classes (`z-modal`, `z-toast`, etc.) work correctly.

### Z-Index Audit Results

**Current hardcoded z-index values found** (Phase 1 audit):

| Pattern | Count | Locations | Action |
|---------|-------|-----------|--------|
| `z-10` | ~15 | TabBar fade gradients, internal positioning, timeline elements | Deferred - internal component positioning |
| `z-20` | ~5 | Selected region highlighting, timeline layers | Deferred - view-specific (Phase 2) |
| `z-30` | ~3 | Timeline selection mask, playhead | Deferred - view-specific (Phase 2) |
| `z-40` | ~5 | Fixed elements, RecordingActionsBar, playhead drag | **Updated** RecordingActionsBar to `z-[310]` |
| `z-50` | ~20 | Modals, dropdowns, settings menus | **Updated** Modal, BottomSheet, Toast to semantic |

**Semantic z-index usage after Phase 1**:
- `z-modal` (500): Modal.tsx, BottomSheet.tsx
- `z-toast` (700): Toast.tsx
- `z-[310]`: RecordingActionsBar (above z-fixed at 300)

**Remaining z-50 usages** (to be migrated in Phase 2):
- `frontend/src/views/actions/components/SectionEditor.tsx:102`
- `frontend/src/views/playlist/PlaylistView.tsx:450`
- `frontend/src/components/Markers/MarkerInfoBar.tsx:247`
- `frontend/src/components/MemoryWarningBar.tsx:102`
- `frontend/src/components/Actions/TapTempoButton.tsx:186`
- `frontend/src/components/SettingsMenu.tsx:87`
- `frontend/src/components/Toolbar/ToolbarEditor.tsx:222`
- `frontend/src/components/Actions/MetronomeButton.tsx:142`
- `frontend/src/components/Actions/TimeSignatureButton.tsx:122`
- `frontend/src/components/Timeline/RegionInfoBar.tsx:574`
- `frontend/src/components/Toolbar/LazyIconPicker.tsx:24`
- `frontend/src/components/Mixer/FolderBreadcrumb.tsx:67`
- `frontend/src/components/Mixer/QuickFilterDropdown.tsx:107`

### Flex Pattern Analysis

**App.tsx already had correct pattern**:
- Line 72: `<main className="flex-1 min-h-0 overflow-auto">` - Correct!
- Changed `overflow-auto` to `overflow-hidden` to let views manage their own scrolling

**Views with correct `flex-1 min-h-0` pattern**:
- `TimelineView.tsx:366` - Has it
- `NotesView.tsx:174` - Has it
- `InstrumentsView.tsx:773` - Has it

**Views needing audit in Phase 2**:
- MixerView - Check flex chain
- PlaylistView - Check flex chain
- ActionsView - Check flex chain
- ClockView - Check flex chain

### h-screen-safe vs h-dvh

**Finding**: The codebase defines `.h-screen-safe` in CSS which is equivalent to `h-dvh`:
```css
.h-screen-safe {
  height: 100vh; /* Fallback */
  height: 100dvh;
}
```

**Action Taken**: Added `.h-dvh` utility class for consistency with Tailwind naming. Updated App.tsx and LoadingScreen to use `h-dvh`. Both classes are functionally identical.

### Safe Area Handling

**Existing implementation is good**:
- `viewport-fit=cover` already in meta tag
- Safe area utility classes already defined in index.css
- 34px fallback for WebKit timing bug already implemented

**Added**:
- CSS custom properties for programmatic access: `--safe-top`, `--safe-bottom`, etc.
- `--safe-max-bottom` for Chrome 135+ optimization
- `interactive-widget=resizes-content` to viewport meta tag

### Component Export Structure

**Pattern discovered**: Components use barrel exports from `components/index.ts` and `hooks/index.ts`. All new components/hooks should be exported from these files.

### Pre-existing Test Failures

**Note**: 7 tests fail in the test suite, but these are pre-existing and unrelated to responsive architecture:
- `timelineTicks.test.ts` - 3 failures (zoom level calculations)
- `Timeline.test.tsx` - 4 failures (playhead viewport coordinates)

These should be investigated separately.

---

## Phase 2: Instruments View (Complete)

### Summary

Refactored InstrumentsView to use responsive architecture patterns from Phase 1.

**Key changes:**
- Wrapped with `ViewLayout` component for consistent structure
- Replaced local `useIsPortrait` hook with shared `useIsLandscape` from hooks
- Removed hard orientation blocks (fullscreen "rotate" warnings)
- Added soft `OrientationHint` banner (dismissible) for orientation suggestions
- All instruments now work in both orientations

### Orientation Strategies by Instrument

| Instrument | Preferred | Portrait Layout | Landscape Layout |
|------------|-----------|-----------------|------------------|
| Drums | Portrait | 4x4 grid fills space | Square aspect, centered |
| Piano | Landscape | Horizontal scroll, min-width 500px | Standard horizontal layout |
| Chords | Landscape | Horizontal scroll, min-width 700px, snap | Standard 7-column layout |

### Implementation Notes

**DrumPadGrid in landscape:**
- Container constrains grid to `aspect-square` within available height
- Centered with flexbox for balanced appearance
- Pads maintain square aspect naturally via CSS Grid

**PianoKeyboard in portrait:**
- Added `overflow-x-auto overscroll-x-contain` for horizontal scrolling
- Set `min-width: 500px` to ensure keys are playable (44px+ touch targets)
- Octave selector remains prominent for quick navigation
- Mod/Pitch wheels use `shrink-0` to stay visible

**Chords in portrait:**
- Added `overflow-x-auto snap-x snap-mandatory` for swipeable columns
- Set `min-width: 700px` to maintain column readability
- Each ChordColumn already has `snap-center` behavior from existing code

### File Modified

| File | Changes |
|------|---------|
| `src/views/instruments/InstrumentsView.tsx` | Adopted ViewLayout, OrientationHint, useIsLandscape. Removed hard blocks. Added responsive layouts per instrument. |

---

## Phase 2 Agent Notes (Remaining)

### For Timeline Agent (Agent A)
- TimelineView already has `flex-1 min-h-0` at line 366
- Many z-10/z-20/z-30/z-40 values for internal layering of playhead, regions, markers
- Consider whether these need semantic names or if numeric is fine for internal stacking

### For All Agents
- Use `ViewLayout` component for consistent structure
- Use semantic z-index classes where appropriate (`z-modal`, `z-toast`, `z-fixed`, `z-elevated`)
- Update this file with any new findings during your phase

---

## Files Modified in Phase 1

| File | Changes |
|------|---------|
| `tailwind.config.js` | Added semantic z-index scale |
| `src/index.css` | Added safe area CSS properties, h-dvh/h-svh utilities, container-responsive |
| `index.html` | Added `interactive-widget=resizes-content` |
| `src/App.tsx` | Refactored to h-dvh, added shrink-0 to banners, updated RecordingActionsBar z-index |
| `src/hooks/useMediaQuery.ts` | **Created** - Media query hook |
| `src/hooks/useContainerQuery.ts` | **Created** - Container query hook |
| `src/hooks/useScrollDirection.ts` | **Created** - Scroll direction hook |
| `src/hooks/useViewFooterConfig.ts` | **Created** - Per-view footer config |
| `src/hooks/index.ts` | Added exports for new hooks |
| `src/components/ViewLayout.tsx` | **Created** - Standard view layout wrapper |
| `src/components/OrientationHint.tsx` | **Created** - Dismissible orientation banner |
| `src/components/index.ts` | Added exports for ViewLayout, OrientationHint |
| `src/components/Modal/Modal.tsx` | Updated z-50 to z-modal |
| `src/components/Modal/BottomSheet.tsx` | Updated z-50 to z-modal |
| `src/components/Toast/Toast.tsx` | Updated z-50 to z-toast |

---

## Open Questions

1. **Should internal z-index values (z-10, z-20) within components be made semantic?**
   - Pros: Consistency, easier to reason about
   - Cons: These are internal stacking contexts, not global. Adding semantic names may be overkill.
   - Current decision: Defer, keep numeric for internal positioning

2. **Should we add a `cn()` utility for className merging?**
   - Codebase currently uses template literals
   - clsx/cn would be cleaner but adds a dependency
   - Current decision: Keep template literals for consistency
