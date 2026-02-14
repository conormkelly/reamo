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

## Bug 2: Add "Clipped" and "With Items" Filters ✅ FIXED

**Bug:** Add "Clipped" and "With items" to filter in mixer and timeline

**Status:** COMPLETED

**Changes Made:**

Backend (Zig):

- Added `clipped: bool` and `item_count: u16` fields to `SkeletonTrack` struct in `track_skeleton.zig`
- Polls clipping via `getTrackPeakHoldDB(track, channel, false)` — sticky until user clears
- Polls item count via `trackItemCount(track)`
- JSON serialization uses short keys: `cl` (clipped), `ic` (item_count)
- Updated mock backend with `getTrackPeakHoldDB` method

Frontend (TypeScript):

- Added `cl` and `ic` fields to `SkeletonTrack` interface in `WebSocketTypes.ts`
- Added `'builtin:clipped'` and `'builtin:with-items'` to `BuiltinBankId` type
- Added to `QUICK_FILTERS` array in `BankSelector.tsx`
- Added count logic in `QuickFilterDropdown.tsx`
- Added filter cases in `MixerView.tsx` and `TimelineView.tsx`

Documentation:

- Updated `extension/API.md` with new `trackSkeleton` event fields

---

## Bug 3 & 4: Bottom Sheet Z-Index Issues ✅ FIXED

**Bug:** FX and Routing bottom sheets have z-index issues - can see controls (filter and navbar) below them

**Status:** COMPLETED (by user)

**Changes Made:**

- Added `isolate` class to main App container to create predictable stacking context
- Changed `z-50` to `z-dropdown` in QuickFilterDropdown for semantic z-index

---

## Bug 5: Drag on Ruler for Selection ⏸️ DEFERRED

**Bug:** Add a feature where we can drag on ruler for selection (currently only long-press to seek)

**Status:** DEFERRED TO v2 - See [ROADMAP.md](../ROADMAP.md#ruler-drag-to-select)

**Reason for deferral:**

- Snap points need to be zoom-level specific
- Edge cases: selecting beyond visible viewport, auto-scroll while dragging
- Long-press-to-seek + MakeSelectionModal covers the use case for v1

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

### Completed (8/9)

- ✅ Bug 1: Folder navigation in Timeline
- ✅ Bug 2: "Clipped" and "With Items" filters
- ✅ Bugs 3 & 4: Z-index issues
- ✅ Bug 6: Tick density
- ✅ Bug 7: Toggle padding
- ✅ Bug 8: Bank display format
- ✅ Bug 9: Empty state consistency

### Deferred to v2 (1/9)

- ⏸️ Bug 5: Ruler drag for selection (see [ROADMAP](../ROADMAP.md#ruler-drag-to-select))

---

## Testing Checklist

- [x] Timeline folder navigation works same as Mixer
- [x] "Clipped" filter shows only tracks with clipping
- [x] "With Items" filter shows only tracks containing items
- [x] FX bottom sheet fully overlays TabBar and filter controls
- [x] Routing bottom sheet fully overlays TabBar and filter controls
- [x] ~~Dragging on ruler creates time selection~~ (deferred)
- [x] Tick density at 5s zoom is reasonable (not too dense)
- [x] TimelineModeToggle has visible gap from BankSelector
- [x] Bank nav shows "1 / 10" when single track visible
- [x] Actions empty state is centered like Playlist
