# MISC Bugs Fix Plan

Investigation completed. Below is a detailed plan for each bug with root cause analysis, affected files, and implementation steps.

---

## Bug 1: Folder Navigation in Timeline ✅ FIXED

**Bug:** Folder nav doesn't do anything in timeline - it should work the same way as it does in mixer view

**Status:** COMPLETED

**Changes Made:**
- Added `FolderNavSheet`, `isBuiltinBank`, `BuiltinBankId`, `useFolderHierarchy` imports
- Added folder navigation state (`folderPath`, `folderSheetOpen`)
- Updated filter logic to handle all built-in banks (muted, soloed, armed, selected, folders, with-sends)
- Added effects to auto-open folder sheet when selecting Folders bank
- Added `onFolderNavClick` to BankSelector to re-open folder sheet
- Added `FolderNavSheet` component

---

## Bug 2: Add "Clipped" and "With Items" Filters

**Bug:** Add "Clipped" and "With items" to filter in mixer and timeline

**Status:** PENDING - may require backend changes

**Root Cause:**
- QuickFilterDropdown uses `QUICK_FILTERS` array from BankSelector
- Currently only has: Muted, Soloed, Armed, Selected, With Sends
- Need to add two new filter types

**Affected Files:**
- [BankSelector.tsx](frontend/src/components/Mixer/BankSelector.tsx) - add to QUICK_FILTERS
- [QuickFilterDropdown.tsx](frontend/src/components/Mixer/QuickFilterDropdown.tsx) - add count logic
- [MixerView.tsx](frontend/src/views/mixer/MixerView.tsx) - add filter case
- [TimelineView.tsx](frontend/src/views/timeline/TimelineView.tsx) - add filter case
- Backend may need changes to provide `clipped` and `hasItems` fields in skeleton

**Complexity:** Medium - may require backend changes for clipping detection

---

## Bug 3 & 4: Bottom Sheet Z-Index Issues ✅ FIXED

**Bug:** FX and Routing bottom sheets have z-index issues - can see controls (filter and navbar) below them

**Status:** COMPLETED (by user)

**Changes Made:**
- Added `isolate` class to main App container to create predictable stacking context
- Changed `z-50` to `z-dropdown` in QuickFilterDropdown for semantic z-index

---

## Bug 5: Drag on Ruler for Selection

**Bug:** Add a feature where we can drag on ruler for selection (currently only long-press to seek)

**Status:** PENDING - feature work

**Root Cause:**
- TimelineRuler only implements long-press via `useLongPress` hook
- No drag gesture implemented for time selection

**Affected Files:**
- [TimelineRuler.tsx](frontend/src/components/Timeline/TimelineRuler.tsx)
- May need new store state for time selection range

**Complexity:** Medium-High - needs careful gesture handling to not conflict with existing long-press

---

## Bug 6: Tick Density at 5s Zoom ✅ FIXED

**Bug:** Tick density is way too dense at 5s zoom level

**Status:** COMPLETED

**Changes Made:**
- Reduced `TARGET_LABELS_RULER` from 8 to 3 (sparser ruler)
- Reduced `TARGET_LABELS_GRID` from 12 to 6 (sparser grid)
- Reduced beat display thresholds:
  - Beat labels: ≤3 bars → ≤2 bars
  - Beat ticks: ≤7 bars → ≤4 bars

---

## Bug 7: Region/Navigation Toggle Padding ✅ FIXED

**Bug:** Region and navigation toggle in timeline should have some left padding/margin - currently bunched up against the bank edit button

**Status:** COMPLETED

**Changes Made:**
- Added `ml-3` to TimelineModeToggle's outer div

---

## Bug 8: Bank Display "1 / 10" Instead of "1-1 / 10" ✅ FIXED

**Bug:** If one track shown in a bank nav (e.g., showing 1 track on timeline), display "1 / 10" instead of redundant "1-1 / 10"

**Status:** COMPLETED

**Changes Made:**
- Updated `useBankNavigation.ts` to show single number when `bankStart === bankEnd`
- Updated `effectiveBankDisplay` in both TimelineView and MixerView for filtered mode consistency

---

## Bug 9: Playlist vs Actions Empty State Consistency ✅ FIXED

**Bug:** Playlist vs actions placement in empty view state needs consistency - should fix Actions page to be the same as Playlist?

**Status:** COMPLETED

**Changes Made:**
- Changed ActionsView empty state from `justify-end pb-6` to `justify-center` to match PlaylistView

---

## Summary

### Completed (7/9)
- ✅ Bug 1: Folder navigation in Timeline
- ✅ Bugs 3 & 4: Z-index issues
- ✅ Bug 6: Tick density
- ✅ Bug 7: Toggle padding
- ✅ Bug 8: Bank display format
- ✅ Bug 9: Empty state consistency

### Remaining (2/9)
- ⏳ Bug 2: "Clipped" and "With Items" filters (needs backend)
- ⏳ Bug 5: Ruler drag for selection (new feature)

---

## Testing Checklist

- [x] Timeline folder navigation works same as Mixer
- [ ] "Clipped" filter shows only tracks with clipping
- [ ] "With Items" filter shows only tracks containing items
- [x] FX bottom sheet fully overlays TabBar and filter controls
- [x] Routing bottom sheet fully overlays TabBar and filter controls
- [ ] Dragging on ruler creates time selection
- [x] Tick density at 5s zoom is reasonable (not too dense)
- [x] TimelineModeToggle has visible gap from BankSelector
- [x] Bank nav shows "1 / 10" when single track visible
- [x] Actions empty state is centered like Playlist
