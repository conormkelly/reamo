# Toolbar Component Redesign - Implementation Plan

**Status:** Ready for implementation
**Effort:** S (half day)
**Priority:** v1.0 Release Blocker

---

## Overview

Replace the current horizontal scrolling toolbar with a slot-based paged grid system. The current implementation uses variable-width buttons and horizontal scrolling; the new design uses fixed 4×2 grids with swipe paging.

## Current State Analysis

### Existing Components
- [Toolbar.tsx](frontend/src/components/Toolbar/Toolbar.tsx) - Main toolbar with horizontal scroll
- [ToolbarButton.tsx](frontend/src/components/Toolbar/ToolbarButton.tsx) - Individual button with toggle state
- [ToolbarEditor.tsx](frontend/src/components/Toolbar/ToolbarEditor.tsx) - Modal for editing buttons
- [toolbarSlice.ts](frontend/src/store/slices/toolbarSlice.ts) - Zustand state management

### Current Issues (from ROADMAP.md)
- No slot concept — buttons sized by text content, inconsistent widths
- No overflow handling — buttons squeeze together or clip
- Padding not well thought out — items too close together

### Render Location
The toolbar renders in `TimelineView.tsx` inside the `SecondaryPanel` as a tab (line 515-521). The `SecondaryPanel` content area is 96px tall (`CONTENT_HEIGHT = EXPANDED_HEIGHT - COLLAPSED_HEIGHT`).

---

## Design Specification

### Grid Layout
```
┌──────────────────────────────────────────────────┐
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐    │
│  │ Split  │ │  Glue  │ │ Delete │ │ +Marker│    │  Row 1
│  └────────┘ └────────┘ └────────┘ └────────┘    │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐    │
│  │ Ripple │ │  Snap  │ │  Dupe  │ │        │    │  Row 2
│  │   ⟳    │ │   ⟳    │ │        │ │        │    │
│  └────────┘ └────────┘ └────────┘ └────────┘    │
├──────────────────────────────────────────────────┤
│              Page indicator: 1/2                 │
└──────────────────────────────────────────────────┘
```

### Sizing
| Property | Value | Rationale |
|----------|-------|-----------|
| Grid | 4 columns × 2 rows | Fits SecondaryPanel's 96px content area |
| Touch target | 48px minimum | Research: edge locations need ≥48pt |
| Button gap | 4-8px | Prevents mis-taps without wasting space |
| Row gap | 4px | Maximize vertical use in 96px |

### Calculations
- Available height: 96px (SecondaryPanel content area)
- 2 rows × 44px buttons + 4px gap + 4px margin = 96px ✓
- Use CSS grid: `grid-template-columns: repeat(4, 1fr)`

### Page Navigation
- Horizontal swipe gesture to change pages
- Page indicator: `1/3` format (compact for limited space)
- Intentional swipe required (not accidental from button taps)

---

## Default Actions

Pre-populate first-time users with item editing operations:

| Page | Slot 1 | Slot 2 | Slot 3 | Slot 4 |
|------|--------|--------|--------|--------|
| 1 | Split | Glue | Delete | Add Marker |
| 2 | Ripple ⟳ | Snap ⟳ | Duplicate | (empty) |

### REAPER Action IDs
| Action | Command ID | Type | Notes |
|--------|-----------|------|-------|
| Split at cursor | 40012 | Native | "Item: Split items at edit or play cursor" |
| Glue items | 40362 | Native | "Item: Glue items" |
| Delete items | 40006 | Native | "Item: Remove items" |
| Add marker | 40157 | Native | "Markers: Insert marker at current position" |
| Toggle ripple | 40310 | Toggle | "Options: Toggle ripple editing per-track" |
| Toggle snap | 1157 | Toggle | "Options: Toggle snapping" |
| Duplicate items | 41295 | Native | "Item: Duplicate items" |

**Note:** Verify exact command IDs by searching in REAPER's Actions menu. Use `_SWS_*` named commands for SWS actions.

---

## Data Model Changes

### Current `toolbarSlice.ts` Structure
```typescript
toolbarActions: ToolbarAction[];  // Flat array
```

### New Structure (Option A - Paged)
```typescript
interface ToolbarSlice {
  toolbarPages: ToolbarPage[];        // Array of pages
  toolbarCurrentPage: number;         // 0-indexed current page
  // ... existing toggle state management unchanged
}

interface ToolbarPage {
  id: string;
  slots: (ToolbarAction | null)[];    // Fixed 8 slots (4×2), null = empty
}
```

### Alternative (Option B - Computed Pages)
Keep flat array, compute pages at render time:
```typescript
toolbarActions: ToolbarAction[];      // Keep existing
toolbarCurrentPage: number;           // Add this
// Page computation: actions.slice(page * 8, (page + 1) * 8)
```

**Recommendation:** Option B (computed pages) - simpler migration, less breaking change.

---

## Implementation Steps

### Phase 1: Grid Layout (no paging yet)

1. **Modify `Toolbar.tsx`**
   - Replace `flex gap-1.5 overflow-x-auto` with CSS grid
   - Use `grid-template-columns: repeat(4, 1fr)` and `grid-template-rows: repeat(2, 1fr)`
   - Set explicit height to fill available space
   - Remove alignment options (not needed with fixed grid)

2. **Modify `ToolbarButton.tsx`**
   - Remove size variants, use single fixed size
   - Make button fill grid cell (`w-full h-full`)
   - Adjust icon/text sizing for new dimensions

3. **Update `ToolbarHeaderControls`**
   - Remove alignment buttons (left/center/right no longer applicable)
   - Keep Edit and Add buttons

### Phase 2: Paging

4. **Add page state to `toolbarSlice.ts`**
   ```typescript
   toolbarCurrentPage: number;
   setToolbarCurrentPage: (page: number) => void;
   ```

5. **Add page navigation to `Toolbar.tsx`**
   - Compute `totalPages = Math.ceil(actions.length / 8)`
   - Show only current page's 8 actions
   - Add page indicator (e.g., `1/3`)
   - Add swipe gesture handler using `onTouchStart`, `onTouchEnd`

6. **Swipe gesture implementation**
   - Track touch start X position
   - On touch end, if deltaX > 50px, change page
   - Prevent page change during button drag in edit mode

### Phase 3: Default Actions

7. **Add default actions in `toolbarSlice.ts`**
   - On first load (no localStorage), populate with defaults
   - Add `initializeDefaultToolbar()` function
   - Call during `loadToolbarFromStorage()` if no saved data

### Phase 4: Polish

8. **Empty slot rendering**
   - Show subtle dashed border for empty slots in edit mode
   - In normal mode, empty slots are invisible but still occupy space

9. **Page indicator styling**
   - Compact format: `1/3`
   - Position: below grid or integrated into header controls
   - Touch target for page indicator to cycle pages

10. **Edit mode improvements**
    - Drag to reorder within grid (existing logic should work)
    - Add to specific slot (optional enhancement)

---

## Files to Modify

| File | Changes |
|------|---------|
| `frontend/src/components/Toolbar/Toolbar.tsx` | Grid layout, paging logic, swipe handler |
| `frontend/src/components/Toolbar/ToolbarButton.tsx` | Remove size variants, full-cell sizing |
| `frontend/src/store/slices/toolbarSlice.ts` | Add page state, default actions |
| `frontend/src/views/timeline/TimelineView.tsx` | Remove `ToolbarHeaderControls` wrapper changes (if needed) |

## Files to NOT Modify

| File | Reason |
|------|--------|
| `ToolbarEditor.tsx` | Works as-is for editing individual actions |
| `ActionSearch.tsx` | Works as-is |
| `actionsViewSlice.ts` | Separate feature (ActionsView), not affected |

---

## Testing Checklist

- [ ] 4×2 grid renders correctly in SecondaryPanel (96px height)
- [ ] Buttons have consistent sizing (fill cells)
- [ ] Page indicator shows correct count
- [ ] Swipe left/right changes pages
- [ ] Swipe doesn't interfere with button taps
- [ ] Edit mode: buttons show edit overlay
- [ ] Edit mode: drag reorder works within page
- [ ] Edit mode: Add button opens editor
- [ ] Toggle state indicators work (colored dot)
- [ ] Default actions appear on first use
- [ ] localStorage persistence works across page reloads
- [ ] Works in landscape and portrait orientations

---

## Research Reference

Full UX research with forum quotes, touch target guidelines, and competitor analysis:
[research/archived/ui-ux/MOBILE_TOOLBAR_UX.md](../../research/archived/ui-ux/MOBILE_TOOLBAR_UX.md)

Key findings:
- 48-54pt touch targets for edge locations
- Text + icon preferred over icon-only (REAPER has thousands of actions)
- Horizontal swipe paging is most natural touch gesture
- Pre-built defaults with customization option (users spend 5-15 min on initial setup)

---

## Out of Scope (Future Work)

These are explicitly NOT part of this implementation:

- **Fixed bottom row** (Logic Remote pattern) - Would require architectural change
- **Dense mode** (smaller buttons, more visible) - Defer to density modes feature
- **Page templates** (Recording, Mixing, Editing presets) - Future enhancement
- **Import/export configuration** - Future enhancement
- **Color coding by category** - User can set colors per-button already
