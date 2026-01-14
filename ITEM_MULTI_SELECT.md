# Item Multi-Selection Feature

## Philosophy

Item selection in REAmo syncs with REAPER's native item selection. This means:

- REAPER is the source of truth for selection state
- Selection persists when navigating away from the timeline
- Any REAPER action/script that operates on "selected items" works automatically
- No separate "multi-select mode" - multi-select is the default behavior

## UX Behavior

### Tap to Toggle Selection

Tapping an item on the timeline **toggles** its selection:

- Tap unselected item → add to selection
- Tap selected item → remove from selection
- No "replace selection" behavior - always additive/subtractive

This enables:

- Quick single-item selection (tap one item)
- Building up a multi-selection (tap several items)
- Removing items from selection without clearing all

### Info Bar Display

The info bar adapts based on selection count:

**0 items selected:**

- Show existing placeholder

**1 item selected:**

- Show full item info bar (existing NavigateItemInfoBar)
- Track selector, color picker, lock toggle, take selector
- Prev/Next navigation within track
- Quick actions for single-item workflows

**2+ items selected:**

- Compact bar: "N items selected"
- Clear selection button (X or "Clear")
- Details button → opens bottom sheet
- Optionally: summary info (total duration, track count)

### Transition Between States

When selection changes:

- 2 → 1 items: Immediately show full info bar for remaining item
- 1 → 2 items: Switch to compact "N items selected" bar
- Transitions should feel seamless, no flicker

### Bottom Sheet (Multi-Selection Details)

Opened by tapping the details button when 2+ items selected:

**Content:**

- Items grouped by track
- Each item shows: name/take, position, duration
- Tap item row → unselect it (removes from list)
- "Clear All" button at bottom

**Behavior:**

- Sheet updates live as selection changes
- If selection drops to 0, sheet closes automatically

### Visual Indicators on Timeline

Selected items need visual distinction:

- Colored ring/border around selected item blobs (primary selection color from app theme colors, i think its some shade of blue atm)
- Consistent with existing single-selection highlighting
- Should work alongside track-colored items

---

## Backend API

### Existing Infrastructure

Already have:

- `selected: bool` on Item struct (polled from REAPER)
- Selection state broadcast to frontend at ~5Hz
- `setItemSelected(item, bool)` wrapper for REAPER API
- `getItemSelected(item)` wrapper for reading current state
- Commands: `item/select`, `item/unselectAll`, `item/selectInTimeSel`

### ItemGuidCache (New Infrastructure)

O(1) GUID → item pointer lookup, built as a byproduct of existing items polling.

**Why build this:**

- Items are already iterated at 5Hz for state polling
- Building cache in same pass adds near-zero overhead
- Enables GUID-based API for all item commands (not just toggleSelect)
- Consistent with existing track GuidCache pattern
- Safer than trackIdx/itemIdx which can shift during operations

**Data structure:**

```zig
pub const ItemGuidCache = struct {
    allocator: Allocator,
    map: std.StringHashMap(ItemLocation),

    pub const ItemLocation = struct {
        track_ptr: *anyopaque,
        item_ptr: *anyopaque,
        track_idx: c_int,
        item_idx: c_int,
    };

    pub fn resolve(self: *const ItemGuidCache, guid: []const u8) ?ItemLocation;
    pub fn clear(self: *ItemGuidCache) void;
    pub fn put(self: *ItemGuidCache, guid: []const u8, loc: ItemLocation) !void;
};
```

**Integration with items polling:**

```zig
// In items.zig poll function
fn pollInto(api: anytype, state: *State, cache: *ItemGuidCache) void {
    cache.clear();

    for (tracks) |track, track_idx| {
        for (items_on_track) |item_ptr, item_idx| {
            const guid = api.getItemGUID(item_ptr, &guid_buf);

            // Build cache as byproduct (minimal overhead)
            cache.put(guid, .{
                .track_ptr = track,
                .item_ptr = item_ptr,
                .track_idx = track_idx,
                .item_idx = item_idx,
            });

            // ... rest of item state polling ...
        }
    }
}
```

**Memory:** ~50 bytes per item. 10,000 items → ~500KB. Bounded and acceptable.

**Staleness:** Cache is rebuilt every poll cycle (5Hz). Commands must handle `null` returns gracefully (item deleted between polls).

### New Command: `item/toggleSelect`

```
Command: item/toggleSelect
Params: { guid: string }
Response: { success: true }
```

Behavior:

- Look up item by GUID via ItemGuidCache (O(1))
- Get current selection state with `getItemSelected()`
- Toggle it (selected → unselected, or vice versa)
- Does NOT unselect other items (unlike `item/select`)
- No undo point needed (selection is UI state, not project data)

Why GUID instead of trackIdx/itemIdx:

- Indices can shift when items are added/removed/reordered
- GUID is stable across changes
- Frontend already has item GUIDs from items array
- Consistent with peaks subscription pattern (uses GUIDs)
- O(1) lookup via ItemGuidCache

### Command Summary

| Command | Behavior |
|---------|----------|
| `item/toggleSelect` | Toggle single item, preserve others (NEW) |
| `item/select` | Select single item, unselect all others |
| `item/unselectAll` | Clear all item selection |
| `item/selectInTimeSel` | Select all items in time selection |

---

## Frontend Architecture

### Source of Truth

REAPER's selection state is authoritative:

- Read selection from `items.filter(i => i.selected)`
- No local `selectedItemGuids` state needed
- Derive `selectedItems` array from items store

### Computed Values

```
selectedItems = items.filter(i => i.selected)
selectedCount = selectedItems.length
isSingleSelection = selectedCount === 1
isMultiSelection = selectedCount > 1
```

### Commands to REAPER

When user taps item:

1. Send `item/toggleSelect` command
2. REAPER updates selection
3. Polling picks up change (~200ms)
4. Frontend re-renders with new selection state

### Optimistic Updates (Optional)

For snappier UX, could optimistically toggle local state while waiting for REAPER confirmation. But since polling is fast (5Hz), may not be necessary. Start without optimistic updates, add if latency feels bad.

---

## Edge Cases

### External Selection Changes

If user selects items directly in REAPER:

- Polling picks up the change
- Frontend updates automatically
- No special handling needed

### Large Selections

If user selects 100+ items (via REAPER action):

- Info bar shows "N items selected"
- Bottom sheet should handle scrolling gracefully
- Consider virtualization if performance issues arise

### Empty Project / No Items

- No items to select
- Info bar hidden or shows "No items in project"

### Item Deleted While Selected

- REAPER handles this (item disappears from items array)
- Frontend automatically updates (item no longer in selectedItems)

---

## Implementation Order

1. ✅ **Backend: ItemGuidCache** - New module, built during items poll
   - `extension/src/item_guid_cache.zig` - O(1) GUID → ItemLocation lookup
   - Integrated into items polling in `extension/src/websocket/commands/item.zig`
   - Rebuilt every poll cycle (5Hz), ~50 bytes per item

2. ✅ **Backend: `item/toggleSelect`** - Uses cache for O(1) lookup
   - Command registered in `extension/src/ws_server.zig`
   - Returns `{ success: true }` or error if item not found

3. ✅ **Frontend store**: Derive selection from `items.filter(i => i.selected)`
   - `frontend/src/store/slices/itemsSlice.ts` - removed local selectedItemGuid state
   - Added `getSelectedItems()` and `getSelectedItemGuid()` derived getters
   - `clearItemSelection()` is now no-op (selection driven by REAPER)

4. ✅ **Info bar**: Implement 0/1/2+ selection display logic
   - `frontend/src/components/Studio/TimelineSection.tsx` - handles all three cases:
     - 0 items: "Tap a marker pill or item blob to select"
     - 1 item: Shows full `NavigateItemInfoBar` with navigation/actions
     - 2+ items: Shows compact bar with "{N} items selected"

5. ✅ **Timeline**: Update tap handler to call `item/toggleSelect`
   - `frontend/src/components/Timeline/Timeline.tsx` - tap calls `item/toggleSelect`
   - `frontend/src/components/Timeline/NavigateItemInfoBar.tsx` - prev/next uses `item/select` (single-select)
   - `frontend/src/components/ItemsTimeline/ItemsTimeline.tsx` - click uses `item/toggleSelect`
   - Mutual exclusion: selecting item clears marker selection

6. ✅ **Visual indicators**: Selection highlighting
   - Single selection: ring-2 border on selected item blobs
   - Multi-selection: same ring highlighting on all selected items
   - Uses `item.selected` from REAPER state (source of truth)

7. ✅ **Bottom sheet**: Multi-selection details sheet (`MultiSelectInfoBar.tsx`)
   - Compact bar shows: "{N} items selected", clear (X) button, "Details" button
   - Details sheet shows items grouped by track
   - Each item row: position, duration; tap to deselect
   - "Clear Selection" button at bottom
   - Sheet auto-closes if selection drops to 0

8. ⏳ **Polish**: Transitions, edge cases, testing

---

## Open Questions

1. **Prev/Next navigation with multi-selection**: When 2+ items selected, should prev/next buttons be hidden, or navigate through the selection?

It shouldnt be shown, thats only for the single item selected flow as a navigational gesture.

1. **Select all on track**: Should tapping a track in the bottom sheet select all items on that track? Or is that overkill?

Hmmm, lets defer it for now.

1. **Deselect gesture**: Is tap-to-toggle sufficient, or do we need a "long-press to deselect" or similar?

Tap works fine.
