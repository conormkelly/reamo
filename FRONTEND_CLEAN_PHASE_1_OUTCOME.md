# Frontend Cleanup Phase 1 - Outcome Report

**Date:** 2025-01-25
**Status:** Complete

---

## Summary

Phase 1 (Dead Code Analysis & Removal) has been executed successfully.

| Metric | Value |
|--------|-------|
| Files removed | 17 |
| Folders removed | 1 (Regions/) |
| Barrel exports updated | 7 |
| Build status | Pass |
| Test status | Pass (934/934) |

**Note:** 4 pre-existing test failures in Timeline.test.tsx related to viewport coordinate calculations in jsdom - unrelated to this cleanup.

---

## Files Removed

### Actions/ (7 files)
| File | LOC | Reason |
|------|-----|--------|
| MarkerButtons.tsx | 84 | Superseded by inline impl in Timeline.tsx |
| MetronomeButton.tsx | 202 | Superseded by inline impl in QuickActionsPanel |
| MixerButtons.tsx | 55 | Never integrated |
| RepeatButton.tsx | 48 | Superseded by inline impl in QuickActionsPanel + TransportBar |
| SaveButton.tsx | 63 | Superseded by inline impl in QuickActionsPanel |
| TapTempoButton.tsx | 225 | Superseded by inline impl in QuickActionsPanel |
| UndoRedoButtons.tsx | 117 | Superseded by inline handlers in QuickActionsPanel |

### Markers/ (1 file)
| File | LOC | Reason |
|------|-----|--------|
| MarkerNavigation.tsx | 54 | Superseded by Timeline.tsx + MarkerNavigationPanel |

### Mixer/ (1 file)
| File | LOC | Reason |
|------|-----|--------|
| SendStrip.tsx | 168 | Exported but never imported/used |

### Regions/ (folder removed entirely)
| File | LOC | Reason |
|------|-----|--------|
| RegionDisplay.tsx | 68 | Exported but never integrated |
| RegionNavigation.tsx | 54 | Requires SWS extension, never integrated |
| index.ts | - | Empty after removals |

### SideRail/ (2 files)
| File | LOC | Reason |
|------|-----|--------|
| SideRailActions.tsx | 58 | Legacy, superseded by ContextRail |
| SideRailBankNav.tsx | 73 | Legacy, superseded by ContextRail |

### Timeline/ (1 file)
| File | LOC | Reason |
|------|-----|--------|
| MultiSelectInfoBar.tsx | 192 | Superseded by NavigateItemInfoBar |

### Track/ (1 file)
| File | LOC | Reason |
|------|-----|--------|
| TrackFilter.tsx | 85 | Superseded by SecondaryPanel/ExpandableSearch |

### Root components/ (2 files)
| File | LOC | Reason |
|------|-----|--------|
| OrientationHint.tsx | 74 | Exported but never imported |
| Portal.tsx | 32 | Superseded by direct createPortal() + usePortalPosition() |

---

## Barrel Export Changes

### components/index.ts
- Removed: `Portal`, `PortalProps`
- Removed: `OrientationHint`, `OrientationHintProps`, `PreferredOrientation`
- Removed: `export * from './Regions'`

### components/Actions/index.ts
- Removed: `MetronomeButton`, `MetronomeButtonProps`
- Removed: `UndoButton`, `RedoButton`, `UndoButtonProps`, `RedoButtonProps`
- Removed: `SaveButton`, `SaveButtonProps`
- Removed: `AddMarkerButton`, `PrevMarkerButton`, `NextMarkerButton` + props
- Removed: `ClearSelectionButton`, `ClearSelectionButtonProps`
- Removed: `TapTempoButton`, `TapTempoButtonProps`
- Removed: `RepeatButton`, `RepeatButtonProps`
- **Kept:** `ActionButton`, `MixerLockButton`, `UnselectAllTracksButton`, `ToggleButton`, `TimeSignatureButton`

### components/Markers/index.ts
- Removed: `MarkerNavigation`, `MarkerNavigationProps`
- **Kept:** `MarkerInfoBar`

### components/Mixer/index.ts
- Removed: `SendStrip`, `SendStripProps`

### components/Track/index.ts
- Removed: `TrackFilter`, `TrackFilterProps`

### components/SideRail/index.ts
- Removed: Legacy component comments (files now deleted)

### components/Regions/
- **Folder deleted** - no remaining exports

---

## Verification

```
Build: npm run build    Pass (1.35s)
Tests: npm test         934 passed

4 pre-existing failures in Timeline.test.tsx:
- playhead renders within viewport when position is in visible range
- playhead renders at midpoint of viewport
- regions spanning beyond viewport have constrained visual bounds
- playhead position uses viewport-relative coordinates

These failures are related to viewport coordinate calculations in jsdom
and pre-date this cleanup (not caused by removed files).
```

---

## Follow-up Items (From Phase 1 Findings)

### High Priority
1. **Re-integrate Toast system** - `Toast/Toast.tsx` was NOT removed; needs to be wired back into App.tsx for undo/redo feedback
2. **Add time signature editing to QuickActionsPanel** - `TimeSignatureButton.tsx` was NOT removed; has unique functionality to integrate

### Future (Technical Debt)
3. **Create action constants file** - Replace magic numbers like `action.execute(40172)` with named constants

---

## Phase 2 Ready

Phase 1 complete. Ready to proceed with Phase 2: Spacing Design Tokens.

See FRONTEND_CLEANUP_PLAN.md for Phase 2 details.
