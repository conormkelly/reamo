# Planned Features

## Table of Contents

- [Items Mode](#items-mode) — View/manage recorded takes without leaving the instrument
- [ID-Keyed Pending State](#id-keyed-pending-state-architectural-fix) — Fix index-based state corruption
- [Tempo Marker Support](#tempo-marker-support) — Respect tempo map during playback
- [Extension Performance Optimizations](#extension-performance-optimizations) — Idle when no clients

---

## Items Mode

### Rationale

The current app shows regions (song structure) but not what's actually recorded in them. Users must go to the computer to see/manage takes. This breaks the "stay at instrument" workflow.

### UI Concept

**Level of Detail (LOD) approach:**

**Zoomed Out (Navigate/Regions mode):**
Items shown as aggregate blobs — visual reference only, read-only.

```txt
┌─────────────────────────────────────────┐
│ Verse 1          │ Chorus               │
│ ▓▓░░▓▓▓░░▓▓     │ ▓▓▓▓░░░▓▓           │
└─────────────────────────────────────────┘
```

**Zoomed In (Items mode):**
Double-tap region or zoom to time selection. Single track view with detailed item management.

```txt
┌─────────────────────────────────────────────────────┐
│ Track: Guitar ▼              [Time Selection]       │
├─────────────────────────────────────────────────────┤
│                                                     │
│    ┌─────────────┐              ┌─────────────┐    │
│    │     1/3     │              │     2/3     │    │
│    │ ▓▓▓▓▓▓▓▓▓▓▓ │              │ ▓▓▓▓▓▓▓▓▓▓▓ │    │
│    └─────────────┘              └─────────────┘    │
│         ▲                                          │
│     (selected)                                     │
├─────────────────────────────────────────────────────┤
│ Take 1 of 3  [◀][▶]  [Crop] [🗑] [Notes] [Color]   │
└─────────────────────────────────────────────────────┘
```

**Key UI decisions:**

- Show ONE track at a time (not all tracks)
- Track dropdown shows tracks with items in the time selection
- Items shown as single bars (active take color) with take count badge ("1/3")
- No visual stacking of takes (unlike REAPER's arrange view)
- ItemInfoBar for selected item: take switching, actions

**Architecture decision:** Backend sends ALL items (no server-side filtering). Frontend filters by time selection as needed. This enables LOD overview (colored bars showing "stuff here") and avoids round-trips when switching views. Time selection is obtained from the transport event, not the items event.

> See [ITEMS_MODE_FEATURE.md](ITEMS_MODE_FEATURE.md) for detailed implementation spec.

### Supported Item Actions

| Action | Purpose | REAPER API |
|--------|---------|------------|
| Switch take | Navigate takes | `SetMediaItemInfo_Value(item, "I_CURTAKE", index)` |
| Delete take | Remove bad take | `Main_OnCommand(40129, 0)` |
| Crop to active | "This is the keeper" | `Main_OnCommand(40131, 0)` |
| Move item | Nudge position | `SetMediaItemInfo_Value(item, "D_POSITION", pos)` |
| Set color | Visual organization | `SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)` |
| Lock | Protect from accidents | `SetMediaItemInfo_Value(item, "C_LOCK", 1)` |
| Add notes | "Good energy", etc. | `GetSetMediaItemInfo_String(item, "P_NOTES", ...)` |
| Delete item | Remove entirely | `DeleteTrackMediaItem(track, item)` |

### What This Is NOT

- No comping lanes
- No crossfades
- No waveform editing
- No split/glue
- No detailed MIDI editing

Just: **"See what I recorded, tidy it up, make quick keep/trash decisions, move on."**

---

## ID-Keyed Pending State (Architectural Fix)

### The Problem

Current `pendingChanges` is keyed by **array index**, but array indices shift when the server pushes region updates (add/delete/reorder). This causes:

1. User edits region at index 2 (id=5)
2. Server pushes update: region at index 0 deleted
3. Array re-indexes: index 2 now contains different region (id=7)
4. `pendingChanges[2]` visually overlays on wrong region
5. Save is correct (uses `originalIdx` = stable ID), but **display is wrong**

### The Solution

**Key pending changes by stable entity ID, not array index.** This is the established pattern used by Apollo Client (normalized cache), Replicache (key-based storage), and TanStack Query.

```typescript
// ❌ Current: index-based (breaks when indices shift)
pendingChanges: Record<number, PendingRegionChange>  // key = array index

// ✅ Fixed: ID-based (stable forever)
pendingChanges: Map<number, PendingRegionChange>     // key = region.id (markrgnidx)
```

For new regions (not yet in REAPER), continue using negative IDs as keys.

### Implementation Checklist

**Types (`regionEditSlice.types.ts`):**
- [ ] Change `PendingChangesRecord` from `Record<number, ...>` to `Map<number, ...>`
- [ ] Remove `_pendingKey` from `DisplayRegion` (no longer needed)
- [ ] Add `baseVersion?: number` to track server state when editing began

**Slice (`regionEditSlice.ts`):**
- [ ] Update `getDisplayRegions()` to look up by `region.id` instead of array index
- [ ] Update all ripple calculation functions to use IDs
- [ ] Update `selectedRegionIndices` to store IDs, not array indices

**Ripple operations (`regionEdit/rippleOperations.ts`):**
- [ ] All functions currently take `index` parameter → change to `id` parameter
- [ ] Update internal logic to work with ID-keyed maps

**Components:**
- [ ] `TimelineRegions.tsx`: Remove `_pendingKey` usage, look up by `region.id`
- [ ] `RegionInfoBar.tsx`: Same
- [ ] `Timeline.tsx`: Update `selectedPendingKeys` computation
- [ ] `useRegionDrag.ts`: Update to use IDs

**Tests:**
- [ ] Update all region edit tests to use ID-based assertions
- [ ] Add test: server update during pending changes doesn't corrupt display

### Conflict Detection (Future Enhancement)

For the multi-device scenario (edit on iPad, changes on computer, save from iPad):

**Option 1: Optimistic Locking (Recommended for MVP)**
- Track `baseVersion` when editing begins
- On save, include expected version
- Server rejects if version changed → prompt user to refresh

**Option 2: Field-level Last-Write-Wins**
- Each field carries timestamp
- Newest value wins per field
- Use Hybrid Logical Clocks to avoid clock skew

For single-user DAW where conflicts are rare, Option 1 is sufficient.

### Why Not OT/CRDTs?

Full Operational Transformation or CRDTs add 15-500KB of library code and complexity. The core insight from CRDT research applies without the overhead: **stable IDs eliminate index-shifting problems entirely**. Once every entity has an immutable ID and all operations reference that ID, no transformation is needed.

---

## Tempo Marker Support

### The Problem

The current implementation uses `GetProjectTimeSignature2()` to fetch BPM and time signature, which **only returns project-level defaults**. This ignores tempo markers entirely.

```zig
// Current (BROKEN for tempo markers):
api.getProjectTimeSignature2(null, &bpm, &num, &denom);
// Returns: project default tempo (e.g., 120 BPM, 4/4)
// Ignores: any tempo markers in the project
```

### Correct API

`TimeMap_GetTimeSigAtTime()` returns **both** BPM and time signature at any position, fully respecting the tempo map including linear ramps:

```c
void TimeMap_GetTimeSigAtTime(
    ReaProject* proj,           // NULL for active project
    double time,                // position in seconds
    int* timesig_numOut,        // beats per measure (e.g., 4)
    int* timesig_denomOut,      // note value per beat (e.g., 4)
    double* tempoOut            // BPM at this position
);
```

**Key findings:**
- Single call returns both tempo AND time signature (no need for `TimeMap2_GetDividedBpmAtTime`)
- Handles tempo ramps (linear interpolation) automatically
- Works even with zero tempo markers (returns project defaults)
- At exact marker boundary, returns NEW values (post-marker)

### Gotchas

**Zero time sig values mean "inherit":** When a tempo marker only changes BPM (not time sig), the API returns 0 for timesig_num/denom. Always handle this:

```zig
if (timesig_num == 0) timesig_num = 4;  // Default to 4/4
if (timesig_denom == 0) timesig_denom = 4;
```

**`positionBeats` already works:** Our `TimeMap2_timeToBeats()` call already respects tempo markers - no changes needed there.

### Performance Optimization (Optional)

For projects with sparse tempo changes, cache the next change time to reduce API calls:

```c
static double s_nextChangeTime = -1;
// Only re-query if we've crossed a marker boundary
if (s_nextChangeTime < 0 || currentPos >= s_nextChangeTime) {
    TimeMap_GetTimeSigAtTime(NULL, currentPos, ...);
    s_nextChangeTime = TimeMap2_GetNextChangeTime(NULL, currentPos);
}
```

For tempo ramps, per-frame queries are still needed during interpolation.

### Implementation Checklist

**Extension (`transport.zig`):**
- [ ] Add REAPER API binding for `TimeMap_GetTimeSigAtTime`
- [ ] Replace `getProjectTimeSignature2()` with `TimeMap_GetTimeSigAtTime()`
- [ ] Pass current play position (or edit cursor when stopped)
- [ ] Handle zero timesig values (default to 4/4)

**Frontend:**
- [ ] No changes required - transport event structure unchanged

**Testing:**
- [ ] Create test project with multiple tempo markers
- [ ] Verify BPM updates when cursor crosses tempo marker during playback
- [ ] Verify time signature updates when crossing time sig marker
- [ ] Test tempo ramps (linear interpolation between markers)
- [ ] Test project with no tempo markers (should use defaults)

### Future: Tempo Map Visualization

For displaying the full tempo map in UI:

| Function | Purpose |
|----------|---------|
| `CountTempoTimeSigMarkers(proj)` | Count markers |
| `GetTempoTimeSigMarker(proj, idx, ...)` | Read marker details |
| `FindTempoTimeSigMarker(proj, time)` | Find marker at position |
| `TimeMap2_GetNextChangeTime(proj, time)` | Find next tempo change (-1 if none)

---

## Extension Performance Optimizations

### Idle When No Clients Connected

**The Problem:**
The extension currently polls REAPER state every 30ms regardless of whether any WebSocket clients are connected. This wastes CPU cycles when the frontend isn't running.

**Solution:**
Skip the polling loop when `clientCount == 0`. Only resume polling when a client connects.

**Implementation:**
```zig
// In the 30ms timer callback:
if (server.clientCount() == 0) return; // Early exit, no work to do

// ... existing polling logic ...
```

**Considerations:**
- First client connection may see a slight delay as state is gathered
- Could optionally do a single immediate poll on client connect to minimize latency
- Track `wasIdle` state to log when transitioning between idle/active

## Project Notes Support

Project notes are useful for session-level metadata: "Client: Acme Records", "Reference tempo: 128 BPM before we slowed it down", "TODO: re-record verse 2 vocals", etc. Currently requires going to the computer (`File > Project Notes...`). Should be accessible from the WebUI.

---

### REAPER API

```c
void GetSetProjectNotes(
    ReaProject* proj,      // NULL for active project
    bool set,              // false = get, true = set
    char* notesNeedBig,    // buffer for notes
    int notesNeedBig_sz    // buffer size
);
```

**Key characteristics:**

- Returns `void` — no way to query required size
- No documented max length (practically unbounded, stored as text in RPP)
- Notes may contain newlines (`\n`, `\r\n`, or `\r` depending on platform/history)
- Empty project notes = empty string (not null)

---

### Buffer Strategy

Since the API doesn't report truncation, use iterative resizing. The heuristic: if `strlen(result) >= bufferSize - 1`, the content was likely truncated.

```zig
fn getProjectNotes(allocator: Allocator) ![:0]u8 {
    var size: usize = 4096; // Start reasonable

    while (size <= 1024 * 1024) { // Cap at 1MB
        const buf = try allocator.allocSentinel(u8, size - 1, 0);
        errdefer allocator.free(buf);

        @memset(buf, 0);
        api.GetSetProjectNotes(null, false, buf.ptr, @intCast(size));

        const len = std.mem.indexOfScalar(u8, buf, 0) orelse size - 1;

        // If we didn't fill the buffer, we got everything
        if (len < size - 1) {
            // Optionally shrink to actual size
            if (allocator.resize(buf, len + 1)) |resized| {
                return resized[0..len :0];
            }
            return buf[0..len :0];
        }

        // Likely truncated — double and retry
        allocator.free(buf);
        size *= 2;
    }

    return error.NotesTooLarge;
}

fn setProjectNotes(notes: [:0]const u8) void {
    // Cast away const - REAPER doesn't modify when set=true, but signature isn't const
    const ptr: [*]u8 = @constCast(notes.ptr);
    api.GetSetProjectNotes(null, true, ptr, @intCast(notes.len + 1));
}
```

---

### Protocol Design

**Decision: On-demand, not polled.**

Unlike transport (continuous) or regions (polled for external changes), project notes:

- Change infrequently
- Can be large
- Don't need real-time sync

Use request/response pattern instead of continuous polling.

#### Messages

**Client → Server: Request notes**

```json
{
  "type": "getProjectNotes"
}
```

**Server → Client: Notes response**

```json
{
  "type": "projectNotes",
  "notes": "Session notes here...\nLine 2\nLine 3"
}
```

**Client → Server: Set notes**

```json
{
  "type": "setProjectNotes",
  "notes": "Updated notes content"
}
```

**Server → Client: Confirmation**

```json
{
  "type": "projectNotesSet",
  "success": true
}
```

Optionally, after successful set, server can echo back the saved notes (re-fetched from REAPER) to confirm round-trip integrity.

---

### UI Concept

**Access:** Button in transport bar or settings/menu area: `[📝]` or `[Notes]`

**Modal/Panel:**

```txt
┌─────────────────────────────────────────────────────┐
│ Project Notes                              [×]      │
├─────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────────────┐ │
│ │ Client: Acme Records                            │ │
│ │ Session date: 2024-01-15                        │ │
│ │                                                 │ │
│ │ TODO:                                           │ │
│ │ - Re-record verse 2 vocals                      │ │
│ │ - Fix timing on bridge guitar                   │ │
│ │                                                 │ │
│ │                                                 │ │
│ └─────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────┤
│                           [Cancel]  [Save]          │
└─────────────────────────────────────────────────────┘
```

**Behavior:**

- Opens modal or slide-out panel
- Fetches current notes on open (shows loading state)
- Textarea for editing (auto-resize or fixed with scroll)
- Cancel = discard local changes, close
- Save = send to server, wait for confirmation, close
- Dirty indicator if local changes exist (prompt to confirm before closing)

---

### Implementation Checklist

#### Extension

- [ ] Add REAPER API import: `GetSetProjectNotes`
- [ ] Implement get function with iterative buffer resize strategy
- [ ] Implement set function
- [ ] Add WebSocket message handler for `getProjectNotes` request
- [ ] Add WebSocket message handler for `setProjectNotes` request
- [ ] Send `projectNotes` response with fetched content
- [ ] Send `projectNotesSet` confirmation after successful write

#### Shared Types

```typescript
// Server → Client
interface ProjectNotesEvent {
  type: 'projectNotes';
  notes: string;
}

interface ProjectNotesSetEvent {
  type: 'projectNotesSet';
  success: boolean;
  error?: string;
}

// Client → Server
interface GetProjectNotesRequest {
  type: 'getProjectNotes';
}

interface SetProjectNotesRequest {
  type: 'setProjectNotes';
  notes: string;
}
```

#### Frontend State

**Required state fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `serverNotes` | `string \| null` | Last value fetched from server (`null` = never fetched) |
| `localNotes` | `string \| null` | Current editor content (`null` = editor closed) |
| `isLoading` | `boolean` | Fetch request in progress |
| `isSaving` | `boolean` | Save request in progress |
| `error` | `string \| null` | Last error message |

**Derived state:**

| Selector | Logic | Purpose |
|----------|-------|---------|
| `isDirty` | `localNotes !== null && localNotes !== serverNotes` | Unsaved changes exist |

#### Frontend Functionality

**Required behaviors:**

- Send `getProjectNotes` request and track loading state
- Receive `projectNotes` message, store server value, initialize local editor if open
- Track local edits in state (separate from server value)
- Send `setProjectNotes` request with local content, track saving state
- Receive `projectNotesSet` confirmation, sync local/server state, clear saving
- Discard local changes (reset editor to server value or close)
- Handle and display errors

#### UI Components

- [ ] Trigger button/icon in toolbar or menu
- [ ] Modal or panel container with open/close handling
- [ ] Textarea with controlled state binding
- [ ] Loading indicator during fetch
- [ ] Saving indicator during save (disable inputs)
- [ ] Dirty state indicator
- [ ] Confirmation prompt when closing with unsaved changes
- [ ] Error display

#### WebSocket Integration

- [ ] Handle outgoing `getProjectNotes` request
- [ ] Handle outgoing `setProjectNotes` request
- [ ] Handle incoming `projectNotes` message
- [ ] Handle incoming `projectNotesSet` message

---

### Gotchas & Edge Cases

#### Newline Normalization

REAPER may store `\r\n` (Windows) or `\r` (old Mac). Normalize to `\n` on receive for consistent textarea behavior:

```typescript
// On receive
const normalized = notes.replace(/\r\n?/g, '\n');
```

REAPER is tolerant of mixed newlines, so conversion on save is optional.

#### Empty vs Null

| State | Meaning | UI |
|-------|---------|-----|
| `serverNotes === null` | Never fetched | Show loading or fetch prompt |
| `serverNotes === ""` | Fetched, project has no notes | Show empty textarea |
| `localNotes === null` | Editor not open | N/A |
| `localNotes === ""` | User cleared all content | Empty textarea, dirty if server had content |

#### Large Notes

If someone pastes a very large amount of text:

- **Frontend:** Consider warning if content exceeds ~100KB before save
- **Extension:** Cap at 1MB, return error if exceeded
- **WebSocket:** Large messages may need consideration depending on server config

#### Concurrent Edits

If notes are open in WebUI and someone edits directly in REAPER:

**Simple approach (acceptable for single-user DAW):** Last-write-wins.

**Better UX:** Track the server value when editor was opened. On save, compare current server value — if changed, warn user:

> "Notes were modified elsewhere. Overwrite?"

Options: Overwrite / Discard my changes / Cancel

---

### Future Enhancements

- **Markdown preview:** Toggle between edit mode and rendered view
- **Auto-save draft:** LocalStorage backup of unsaved changes (survives browser refresh)
- **Timestamps:** Display "Last modified: 2 hours ago" if REAPER exposes this (it doesn't natively, but could track in extension)
- **Search:** Ctrl+F / Cmd+F within notes (browser native may suffice for textarea)
- **Character/word count:** Footer showing content length
