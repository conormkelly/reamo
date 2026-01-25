# Frontend Cleanup Phase 1 - Dead Code Analysis Findings

**Date:** 2025-01-25
**Status:** Analysis Complete - Ready for Removal (with corrections)

---

## Executive Summary

- **Total component files scanned:** 131 (excluding test files)
- **Barrel export (index.ts) files:** 16
- **Confirmed dead code:** 17 files, ~1,652 LOC
- **Keep (unique functionality):** 1 file (TimeSignatureButton - 203 LOC)
- **Fix required:** 1 file (Toast - needs re-integration, not removal)

---

## Methodology

1. **Inventory** - Glob all .tsx files in `frontend/src/components/`
2. **Barrel analysis** - Read all index.ts files to understand export tree
3. **Import graph** - Grep for each component's usage across codebase
4. **Dynamic import check** - Search for `lazy()`, `React.lazy`, `import()` patterns
5. **Functionality duplication** - Deep analysis of whether functionality exists elsewhere
6. **Git history** - Check recent commits for context on component evolution

---

## CRITICAL: Fix Required (Do NOT Remove)

### Toast System - Needs Re-Integration

| File | LOC | Status |
|------|-----|--------|
| `Toast/Toast.tsx` | 91 | **FIX NEEDED** - Do not remove |

**Issue:** The Toast system (undo/redo feedback toasts) was **accidentally disconnected** when the legacy StudioView was removed. The component is complete and working - it just needs to be wired back into the app.

**TODO:** Re-integrate Toast/Toast.tsx:
1. Import `ToastContainer` and `useToast` in App.tsx or appropriate location
2. Wire up undo/redo actions to show toast feedback
3. The component provides: auto-dismiss, undo/redo icons, slide-up animation

**Do NOT delete this file - it's needed functionality that was lost during refactoring.**

---

## Confirmed Dead Code - Safe to Remove

### Category 1: Legacy Components (Replaced by New Architecture)

| File | LOC | Status | Replacement |
|------|-----|--------|-------------|
| `SideRail/SideRailActions.tsx` | 58 | Commented out of barrel | ContextRail system |
| `SideRail/SideRailBankNav.tsx` | 73 | Commented out of barrel | ContextRail system |
| `Portal.tsx` | 32 | Never used | Direct `createPortal()` + `usePortalPosition()` hook |
| `Track/TrackFilter.tsx` | 85 | Superseded | `SecondaryPanel/ExpandableSearch.tsx` |

**Notes:**

- SideRail components explicitly marked "Legacy subcomponents - kept for reference during transition"
- Portal.tsx was created in commit 537f91b but immediately superseded by direct createPortal pattern
- **TrackFilter history:** Was used in the past when filter was always visible. Now replaced by ExpandableSearch which provides a more compact, collapsible design. Safe to remove.

### Category 2: Feature Components Never Integrated / Superseded

| File | LOC | Status | Notes |
|------|-----|--------|-------|
| `Mixer/SendStrip.tsx` | 168 | Exported, never imported | Channel strip for Sends mode - mentioned in comment only |
| `OrientationHint.tsx` | 74 | Exported, never imported | Rotation suggestion banner - only in JSDoc example |
| `Regions/RegionDisplay.tsx` | 68 | Exported, never imported | Shows current region at playhead - never integrated |
| `Regions/RegionNavigation.tsx` | 54 | Exported, never imported | Prev/next region buttons - requires SWS extension |
| `Timeline/MultiSelectInfoBar.tsx` | 192 | Superseded | **History:** Was used in past for multi-item selection. All functionality now exists in NavigateItemInfoBar. Safe to remove. |

### Category 3: Duplicate Functionality (Implemented Inline Elsewhere)

| File | LOC | Duplicate Location | Evidence |
|------|-----|-------------------|----------|
| `Actions/SaveButton.tsx` | 63 | QuickActionsPanel.tsx:41-46, 143-155 | Save action inline |
| `Actions/RepeatButton.tsx` | 48 | QuickActionsPanel.tsx:64-66, 205-217 + TransportBar.tsx:82, 175-182 | Repeat toggle inline |
| `Actions/TapTempoButton.tsx` | 225 | QuickActionsPanel.tsx:68-125, 224-270 | Full tap tempo + dialog inline |
| `Actions/MetronomeButton.tsx` | 202 | QuickActionsPanel.tsx:60-62, 191-203 | Metronome toggle inline (legacy from StudioView) |
| `Actions/UndoRedoButtons.tsx` | 117 | QuickActionsPanel.tsx (undo/redo handlers) | Undo/redo inline |
| `Actions/MarkerButtons.tsx` | 84 | Timeline.tsx:206-212, MarkerNavigationPanel | Prev/next marker inline + list navigation |
| `Actions/MixerButtons.tsx` | 55 | Never used | ClearSelectionButton never integrated |
| `Markers/MarkerNavigation.tsx` | 54 | Timeline.tsx:206-212 | `action.execute(40172)` and `action.execute(40173)` inline |

**Investigation Details:**

**QuickActionsPanel** implements these features inline:
- Save project (action 40026)
- Repeat toggle (toggleRepeat from store)
- Tap tempo with BPM display, increment/decrement, input dialog
- Metronome toggle (action 40364)
- Undo/Redo with canUndo/canRedo state

**Timeline.tsx** implements marker navigation:
```typescript
const handlePrevMarker = useCallback(() => {
  sendCommand(action.execute(40172)); // Go to previous marker/project start
}, [sendCommand]);

const handleNextMarker = useCallback(() => {
  sendCommand(action.execute(40173)); // Go to next marker/project end
}, [sendCommand]);
```

---

## Technical Debt Note: Action Constants

**Issue:** The codebase uses magic numbers for REAPER actions:
```typescript
action.execute(40172)  // What is this?
action.execute(40173)  // What is this?
action.execute(40026)  // What is this?
```

**TODO (Future Phase):** Create a dedicated action constants file:
```typescript
// constants/reaperActions.ts
export const REAPER_ACTIONS = {
  MARKER_PREV: 40172,
  MARKER_NEXT: 40173,
  PROJECT_SAVE: 40026,
  METRONOME_TOGGLE: 40364,
  // ... etc
} as const;
```

This would make code self-documenting and easier to maintain.

---

## Keep - Unique Functionality

| File | LOC | Reason |
|------|-----|--------|
| `Actions/TimeSignatureButton.tsx` | 203 | **UNIQUE**: Time signature editor modal with presets (3/4, 4/4, 6/8), numerator/denominator controls. No duplicate exists anywhere in codebase. |

**TimeSignatureButton Features:**
- Displays current time signature from store
- Opens modal with increment/decrement controls
- Preset buttons for common time signatures
- Sends `timesig/set` command to REAPER

**TODO:** Add time signature editing functionality to QuickActionsPanel. Keep this component for reference during integration.

---

## Deep Investigation Results

### Portal Pattern Evolution

**Commit 537f91b** added Portal.tsx but the codebase immediately evolved to use direct `createPortal()`:

**Current best practice (per FRONTEND_DEVELOPMENT.md §8):**
```typescript
// For dropdowns/popovers - use usePortalPosition hook
const { position } = usePortalPosition(triggerRef, isOpen, {
  placement: 'bottom-end',
  offset: 4
});

return isOpen && createPortal(
  <div style={{ top: position.top, left: position.left }}>
    Content
  </div>,
  document.body
);
```

**Components using this pattern:** SettingsMenu, QuickFilterDropdown, FolderBreadcrumb, MarkerInfoBar, RegionInfoBar, Modal, BottomSheet

### TrackFilter → ExpandableSearch Migration

**TrackFilter.tsx** was the original track filter implementation (always visible input). It was superseded by ExpandableSearch which provides:

1. **ExpandableSearch** in SecondaryPanel provides:
   - Collapsible UI (icon → expanded input) - more compact design
   - Badge dot when filter active while collapsed
   - Mobile-optimized with auto-focus

2. **Filtering logic** moved directly into views:
   - MixerView.tsx lines 139-250
   - TimelineView.tsx lines 139-219
   - Supports: text search, built-in banks, smart banks, custom banks, folder navigation

### Action Button Components vs QuickActionsPanel

The Actions folder contains many button components that were designed for potential reuse but were superseded by inline implementations in QuickActionsPanel:

| Component | QuickActionsPanel Implementation |
|-----------|----------------------------------|
| SaveButton | Lines 41-46, 143-155 |
| RepeatButton | Lines 64-66, 205-217 |
| TapTempoButton | Lines 68-125, 224-270 |
| MetronomeButton | Lines 60-62, 191-203 |
| UndoRedoButtons | Inline handlers with store state |

**MetronomeButton history:** Originally created for legacy StudioView (predated Timeline/Mixer views). QuickActionsPanel now provides the metronome toggle. The component's extra features (volume control, count-in toggles) were never exposed in any UI.

### Navigation Components Analysis

**MarkerNavigation vs Timeline implementation:**
- MarkerNavigation.tsx calls `marker.prev()` and `marker.next()`
- Timeline.tsx calls `action.execute(40172)` and `action.execute(40173)` (same underlying REAPER actions)
- MarkerNavigationPanel provides superior list-based navigation with search

**RegionNavigation:**
- Requires SWS Extension (`_SWS_SELPREVREG`, `_SWS_SELNEXTREG`)
- No UI ever exposed this functionality
- Combined marker+region navigation available in MarkerNavigationPanel instead

**MultiSelectInfoBar vs NavigateItemInfoBar:**
- MultiSelectInfoBar was the original multi-item selection component
- NavigateItemInfoBar (which IS used) now handles all multi-select with batch operations
- MultiSelectInfoBar is superseded - safe to remove

---

## Files to Remove

### Total: 17 files, ~1,652 LOC

```
frontend/src/components/
├── Actions/
│   ├── MarkerButtons.tsx          (84 LOC)
│   ├── MetronomeButton.tsx        (202 LOC)
│   ├── MixerButtons.tsx           (55 LOC)
│   ├── RepeatButton.tsx           (48 LOC)
│   ├── SaveButton.tsx             (63 LOC)
│   ├── TapTempoButton.tsx         (225 LOC)
│   └── UndoRedoButtons.tsx        (117 LOC)
├── Markers/
│   └── MarkerNavigation.tsx       (54 LOC)
├── Mixer/
│   └── SendStrip.tsx              (168 LOC)
├── Regions/
│   ├── RegionDisplay.tsx          (68 LOC)
│   └── RegionNavigation.tsx       (54 LOC)
├── SideRail/
│   ├── SideRailActions.tsx        (58 LOC)
│   └── SideRailBankNav.tsx        (73 LOC)
├── Timeline/
│   └── MultiSelectInfoBar.tsx     (192 LOC)
├── Track/
│   └── TrackFilter.tsx            (85 LOC)
├── OrientationHint.tsx            (74 LOC)
└── Portal.tsx                     (32 LOC)
```

**NOT removing (keep for reference):**
- `Actions/TimeSignatureButton.tsx` (203 LOC) - unique functionality, TODO to integrate into QuickActionsPanel

**NOT removing (needs fix, not removal):**
- `Toast/Toast.tsx` (91 LOC) - re-integrate undo/redo toasts

---

## Barrel Export Updates Required

After removing files, update these barrel exports:

### `components/index.ts`

Remove:
```typescript
export { OrientationHint, type OrientationHintProps, type PreferredOrientation } from './OrientationHint';
export { Portal, type PortalProps } from './Portal';
```

### `components/Actions/index.ts`

Remove:
```typescript
export { MetronomeButton, type MetronomeButtonProps } from './MetronomeButton';
export { SaveButton, type SaveButtonProps } from './SaveButton';
export { AddMarkerButton, PrevMarkerButton, NextMarkerButton, ... } from './MarkerButtons';
export { ClearSelectionButton, type ClearSelectionButtonProps } from './MixerButtons';
export { UndoButton, RedoButton, ... } from './UndoRedoButtons';
export { TapTempoButton, type TapTempoButtonProps } from './TapTempoButton';
export { RepeatButton, type RepeatButtonProps } from './RepeatButton';
```

### `components/Markers/index.ts`

Remove:
```typescript
export { MarkerNavigation, type MarkerNavigationProps } from './MarkerNavigation';
```

### `components/Regions/index.ts`

Remove entire file (both exports are dead):
```typescript
export { RegionNavigation, type RegionNavigationProps } from './RegionNavigation';
export { RegionDisplay, type RegionDisplayProps } from './RegionDisplay';
```

### `components/Mixer/index.ts`

Remove:
```typescript
export { SendStrip, type SendStripProps } from './SendStrip';
```

### `components/Track/index.ts`

Remove:
```typescript
export { TrackFilter, type TrackFilterProps } from './TrackFilter';
```

### `components/SideRail/index.ts`

Already commented out - just delete the files

---

## Verification Checklist

Before removal, verify:
- [ ] `npm run build` succeeds after each batch of removals
- [ ] `npm run test` passes
- [ ] No TypeScript errors
- [ ] App loads and functions correctly

---

## Follow-up TODOs (Separate Tasks)

### High Priority
1. **Re-integrate Toast system** - Wire ToastContainer back into App.tsx for undo/redo feedback
2. **Add time signature editing to QuickActionsPanel** - Use TimeSignatureButton as reference

### Future (Technical Debt)
3. **Create action constants file** - Replace magic numbers like `action.execute(40172)` with named constants

---

## Future Considerations

### For Side Rail / Landscape Mode

The following actively-used components provide good patterns for future side rail work:
- **MarkerNavigationPanel** - List-based navigation with search (better than prev/next buttons)
- **NavigateItemInfoBar** - Multi-select patterns with batch operations
- **RegionInfoBar** - Inline edit patterns
- **SecondaryPanel** - Collapsible tabbed content

---

## Appendix: Search Commands Used

```bash
# Find all component files
find "frontend/src/components" -name "*.tsx" -type f ! -name "*.test.tsx"

# Check imports for a component
grep -r "ComponentName" frontend/src --include="*.tsx" --include="*.ts"

# Check for dynamic imports
grep -r "lazy\s*\(|React\.lazy|import\s*\(" frontend/src

# Check recent commits for context
git log --oneline -20 --all --grep="portal"
```

---

## Sign-off

**Analysis completed by:** Claude Code
**Corrections applied:** 2025-01-25
**Ready for:** User review and approval before removal execution
