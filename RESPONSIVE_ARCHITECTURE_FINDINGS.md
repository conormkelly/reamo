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

## Phase 2: Timeline View (Complete)

### ViewLayout Adoption

**Refactored TimelineView to use ViewLayout component**:

```tsx
<ViewLayout
  viewId="timeline"
  className="bg-bg-app text-text-primary p-3"
  header={headerContent}
  footer={footerContent}
  scrollable={false}
>
  {/* Main timeline content */}
</ViewLayout>
```

**Key structural changes**:
1. Header (ViewHeader with BankSelector, TimelineModeToggle) extracted to `headerContent`
2. Footer (Toolbar + Filter + BankNavigator) extracted to `footerContent`
3. Main content properly structured with:
   - Timeline canvas with `shrink-0` (fixed height)
   - Info bars section with `flex-1 min-h-0 overflow-y-auto` (scrollable if needed)

### Responsive Timeline Height

**Added orientation-aware timeline height**:
- Portrait: 200px (default)
- Landscape: 240px (taller to utilize horizontal screen space)

```tsx
const TIMELINE_HEIGHT_PORTRAIT = 200;
const TIMELINE_HEIGHT_LANDSCAPE = 240;

const TIMELINE_HEIGHT = isLandscape ? TIMELINE_HEIGHT_LANDSCAPE : TIMELINE_HEIGHT_PORTRAIT;
```

### Responsive Waveform Density

**Already implemented via containerWidth**:
- ResizeObserver tracks timeline container width
- `peaksSubscriptionOptions` includes viewport width for adaptive peak resolution
- More peak samples requested when zoomed in (better detail)
- Fewer samples when zoomed out (performance optimization)

### Z-Index Decisions

**Internal z-index values (z-10, z-20, z-30, z-40) kept as-is**:
- These are internal stacking for playhead, regions, markers, track labels
- They form a coherent local stacking context
- No benefit to making them semantic since they don't interact with global layers

**z-50 in RegionInfoBar.tsx (line 574)**: Used for dropdown popover, should be migrated to `z-popover` in future cleanup.

### Files Modified in Phase 2 Timeline

| File | Changes |
|------|---------|
| `src/views/timeline/TimelineView.tsx` | Adopted ViewLayout, added responsive height, added useIsLandscape |

---

## Phase 2 Agent Notes

### For Timeline Agent (Agent A) - COMPLETE
- ✅ ViewLayout adopted
- ✅ Responsive timeline height (landscape/portrait)
- ✅ Waveform density already responsive via containerWidth
- Internal z-index values kept numeric (per Phase 1 decision)

### For Instruments Agent (Agent F)
- InstrumentsView has `flex-1 min-h-0` at line 773
- Has orientation-related code that needs to integrate with new `useIsLandscape` hook
- `OrientationHint` component is ready for use

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
