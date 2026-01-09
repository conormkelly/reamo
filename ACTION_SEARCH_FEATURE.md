# Action Search Feature - Implementation Plan & Work Log

> **Living Document**: This plan serves as both implementation guide and work log. Update after each phase with lessons learned. If context is lost, another Claude can resume from here.

## Quick Links - Read These First

| Document | Purpose |
|----------|---------|
| [DEVELOPMENT.md](../../DEVELOPMENT.md) | Architecture, conventions, common pitfalls |
| [API.md](../../extension/API.md) | WebSocket protocol, existing action commands |
| [research/REVERSE_NAME_LOOKUP_BUFFER.md](../../research/REVERSE_NAME_LOOKUP_BUFFER.md) | Buffer size research for ReverseNamedCommandLookup |

## Problem Statement

Users currently must know REAPER action IDs to add custom toolbar buttons. We want searchable action discovery with proper handling of:
- **Native REAPER actions**: ~2500+ built-in, numeric IDs are stable
- **SWS/ReaPack/Scripts**: Numeric IDs are **dynamic** (change on restart), must use string identifiers

## Key Research Finding: Action ID Stability

**Critical insight from [research doc](../../research/REVERSE_NAME_LOOKUP_BUFFER.md):**

| Action Type | Numeric ID Stable? | String ID | Storage Strategy |
|-------------|-------------------|-----------|------------------|
| Native REAPER | ✅ Yes | NULL | Store `"40001"` |
| SWS Extension | ❌ No | `_SWS_*` | Store `"_SWS_SAVESEL"` |
| ReaScripts | ❌ No | `_RS*` | Store `"_RS7f8a2b..."` |
| Custom Actions | ❌ No | `_` + 32 hex | Store `"_113088d1..."` |

**Buffer size**: 128 bytes is the SWS-established safe limit (`SNM_MAX_ACTION_CUSTID_LEN`). Longest observed: 47 chars.

**API quirk**: `ReverseNamedCommandLookup` returns pointer to internal string **without** leading underscore. Must prepend `_` when storing.

---

## Phase 1: Backend Changes (Pre-requisite)

### 1.1 Add ReverseNamedCommandLookup binding

**Files:**
- `extension/src/reaper/raw.zig` - C function pointer
- `extension/src/reaper/real.zig` - RealBackend wrapper
- `extension/src/reaper/mock/` - MockBackend implementation

**C signature:**
```c
const char* ReverseNamedCommandLookup(int command_id)
// Returns internal pointer (NOT caller buffer), NULL for native actions
// Returned string EXCLUDES leading underscore
```

**Zig implementation notes:**
```zig
// raw.zig - add to function pointer struct
ReverseNamedCommandLookup: ?*const fn (c_int) callconv(.c) ?[*:0]const u8 = null,

// real.zig wrapper
pub fn reverseNamedCommandLookup(self: *const RealBackend, cmd_id: c_int) ?[]const u8 {
    const f = self.inner.ReverseNamedCommandLookup orelse return null;
    const ptr = f(cmd_id) orelse return null;
    return std.mem.span(ptr);
}
```

### 1.2 Update `action/getActions` response format

**File:** `extension/src/commands/actions.zig`

**Current format:** `[cmd_id, section, name, is_toggle]`
**New format:** `[cmd_id, section, name, is_toggle, named_id]`

```zig
// Buffer for copying named_id (128 bytes per SWS standard)
var named_id_buf: [128]u8 = undefined;

// In enumeration loop:
const raw_named_id = api.reverseNamedCommandLookup(cmd_id);
const named_id: ?[]const u8 = if (raw_named_id) |id| blk: {
    // Prepend underscore - API returns without it
    named_id_buf[0] = '_';
    const len = @min(id.len, 126); // Leave room for _ and null
    @memcpy(named_id_buf[1..][0..len], id[0..len]);
    break :blk named_id_buf[0 .. len + 1];
} else null;

// JSON output: named_id as string or null
if (named_id) |nid| {
    // Write: ,"_SWS_SAVESEL"
    try writer.print(",\"{s}\"", .{nid});
} else {
    try writer.writeAll(",null");
}
```

### 1.3 Add `sectionId` parameter to execute commands

**File:** `extension/src/commands/actions.zig`

**`action/execute`:**
```zig
// Parse optional sectionId (default: 0)
const section_id = cmd.params.getInt("sectionId") orelse 0;

// Execute in correct section
if (section_id == 0 or section_id == 100) {
    api.runCommand(command_id);
} else {
    // MIDI Editor sections need different execution
    api.runCommandEx(section_id, command_id);
}
```

**`action/executeByName`:**
```zig
// Parse optional sectionId (default: 0)
const section_id = cmd.params.getInt("sectionId") orelse 0;

// Lookup current numeric ID from string
const cmd_id = api.namedCommandLookup(name);
if (cmd_id == 0) {
    response.err("NOT_FOUND", "Named command not found");
    return;
}

// Execute in correct section
api.runCommandEx(section_id, cmd_id);
```

### 1.4 Update API.md

Document:
- New 5-element array format for `action/getActions`
- `sectionId` parameter for `action/execute` and `action/executeByName`
- Section ID reference table

---

## Phase 2: Frontend - Store & Data Layer

### 2.1 Create Actions Slice

**File:** `frontend/src/store/slices/actionsSlice.ts` (new)

```typescript
export interface ReaperAction {
  commandId: number;
  sectionId: number;
  name: string;
  isToggle: boolean;
  namedId: string | null;  // "_SWS_*" for SWS, null for native
}

interface ActionsSlice {
  actionCache: ReaperAction[];
  actionCacheLoading: boolean;
  actionCacheError: string | null;

  // Actions
  setActionCache(actions: ReaperAction[]): void;
  setActionCacheLoading(loading: boolean): void;
  setActionCacheError(error: string | null): void;
}
```

### 2.2 Wire up fetch on connect

**File:** `frontend/src/store/index.ts`

After successful `hello` response:
```typescript
// Fetch action cache during splash screen
connection.sendAsync('action/getActions', {}).then((response) => {
  if (response.success && Array.isArray(response.payload)) {
    const actions = response.payload.map(([cmdId, secId, name, isToggle, namedId]) => ({
      commandId: cmdId,
      sectionId: secId,
      name,
      isToggle: isToggle === 1,
      namedId: namedId ?? null,
    }));
    useReaperStore.getState().setActionCache(actions);
  }
});
```

### 2.3 Add Section Constants

**File:** `frontend/src/core/constants.ts`

```typescript
export const REAPER_SECTIONS: Record<number, string> = {
  0: 'Main',
  100: 'Main (Alt)',
  32060: 'MIDI Editor',
  32061: 'MIDI Event List',
  32062: 'MIDI Inline',
  32063: 'Media Explorer',
};

export const REAPER_SECTION_SHORT: Record<number, string> = {
  0: 'Main',
  100: 'Alt',
  32060: 'MIDI',
  32061: 'MIDI List',
  32062: 'MIDI Inline',
  32063: 'Explorer',
};
```

### 2.4 Update ToolbarAction Type

**File:** `frontend/src/store/slices/toolbarSlice.ts`

```typescript
// Unified action type - stores stable identifier
type ToolbarAction =
  | (ToolbarActionBase & {
      type: 'reaper_action';
      actionId: string;      // "40001" (native) or "_SWS_SAVESEL" (SWS/script)
      sectionId: number;     // 0 = main, etc.
    })
  | (ToolbarActionBase & { type: 'midi_cc'; cc: number; value: number; channel: number; })
  | (ToolbarActionBase & { type: 'midi_pc'; program: number; channel: number; });

// Migration: old format had commandId: number
function migrateToolbarAction(action: any): ToolbarAction {
  if (action.type === 'reaper_action' && typeof action.commandId === 'number') {
    return {
      ...action,
      actionId: String(action.commandId),
      sectionId: action.sectionId ?? 0,
    };
  }
  if (action.type === 'reaper_action_name') {
    // Old "action by name" type - convert to unified format
    return {
      ...action,
      type: 'reaper_action',
      actionId: action.name,  // Already has underscore prefix
      sectionId: action.sectionId ?? 0,
    };
  }
  return action;
}
```

### 2.5 Update WebSocket Commands

**File:** `frontend/src/core/WebSocketCommands.ts`

```typescript
export const actionCmd = {
  execute: (commandId: number, sectionId?: number) => ({
    command: 'action/execute',
    params: { commandId, ...(sectionId !== undefined && sectionId !== 0 && { sectionId }) },
  }),

  executeByName: (name: string, sectionId?: number) => ({
    command: 'action/executeByName',
    params: { name, ...(sectionId !== undefined && sectionId !== 0 && { sectionId }) },
  }),

  getActions: () => ({
    command: 'action/getActions',
    params: {},
  }),
};
```

---

## Phase 3: Frontend - UI Components

### 3.1 Create ActionSearch Component

**File:** `frontend/src/components/Toolbar/ActionSearch.tsx` (new)

**Requirements:**
- Mobile-first design (touch targets, virtual keyboard aware)
- Text input with instant filtering (debounced 150ms)
- Matches: action name (case-insensitive) OR commandId (prefix match)
- Virtualized list using **tanstack-virtual** (already a dependency)
- Row shows: toggle indicator, action name, section badge, command ID
- Tap to select → calls `onSelect(action)` callback
- Loading state while cache fetches
- Empty state for no results

**Component structure:**
```typescript
interface ActionSearchProps {
  onSelect: (action: ReaperAction) => void;
  selectedActionId?: string;  // Highlight current selection
}

function ActionSearch({ onSelect, selectedActionId }: ActionSearchProps) {
  const actionCache = useReaperStore((s) => s.actionCache);
  const loading = useReaperStore((s) => s.actionCacheLoading);
  const [query, setQuery] = useState('');
  const debouncedQuery = useDebounce(query, 150);

  const filtered = useMemo(() => {
    if (!debouncedQuery) return actionCache;
    const q = debouncedQuery.toLowerCase();
    return actionCache.filter(a =>
      a.name.toLowerCase().includes(q) ||
      String(a.commandId).startsWith(q)
    );
  }, [actionCache, debouncedQuery]);

  // tanstack-virtual setup for 10k+ items
  const parentRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: filtered.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 56,  // Row height
    overscan: 5,
  });

  // ... render virtualized list
}
```

### 3.2 Update ToolbarEditor

**File:** `frontend/src/components/Toolbar/ToolbarEditor.tsx`

**Changes:**
- Remove "REAPER Action" and "Action by Name" tabs → single "Action" tab
- Replace Command ID input with `<ActionSearch onSelect={...} />`
- Show selected action with section badge
- Read-only display of underlying ID (collapsible/advanced)

**Tab structure:**
```
[Action] [MIDI CC] [MIDI PC]
```

**Selected action display:**
```
┌─────────────────────────────────────────────────┐
│ ✓ Options: Toggle metronome              [Main] │
│   ID: 40364                              Change │
└─────────────────────────────────────────────────┘
```

### 3.3 Update ToolbarButton Execution

**File:** `frontend/src/components/Toolbar/ToolbarButton.tsx`

```typescript
case 'reaper_action':
  if (action.actionId.startsWith('_')) {
    // SWS/script - use named command (string ID is stable)
    sendCommand(actionCmd.executeByName(action.actionId, action.sectionId));
  } else {
    // Native REAPER - use numeric ID (stable for built-in actions)
    sendCommand(actionCmd.execute(parseInt(action.actionId, 10), action.sectionId));
  }
  break;
```

---

## File Checklist

### Backend
- [x] `extension/src/reaper/raw.zig` - Add ReverseNamedCommandLookup, NamedCommandLookup bindings
- [x] `extension/src/reaper/real.zig` - Add wrappers
- [x] `extension/src/reaper/backend.zig` - Add to validateBackend()
- [x] `extension/src/reaper/mock/` - Add mock implementations
- [x] `extension/src/commands/actions.zig` - Update getActions, execute, executeByName
- [x] `extension/API.md` - Document new format and parameters
- [x] Run `make test-extension` to verify

### Frontend
- [x] `frontend/src/store/slices/actionsSlice.ts` - New slice
- [x] `frontend/src/store/index.ts` - Wire up slice, fetch on connect
- [x] `frontend/src/core/constants.ts` - Section ID maps
- [x] `frontend/src/core/WebSocketCommands.ts` - Update command builders
- [x] `frontend/src/store/slices/toolbarSlice.ts` - Update ToolbarAction type (no migration - pre-release)
- [x] `frontend/src/components/Toolbar/ActionSearch.tsx` - New component with tanstack-virtual
- [x] `frontend/src/components/Toolbar/ToolbarEditor.tsx` - Integrated ActionSearch, replaced manual ID input
- [x] `frontend/src/components/Toolbar/ToolbarButton.tsx` - Update execution logic
- [x] Run `npm run build` to verify

---

## Testing Checklist

1. **Verify all actions appear** - Native REAPER + SWS + ReaScripts
2. **Verify named IDs** - SWS actions show `_SWS_*` identifiers
3. **Test section execution** - MIDI Editor actions should only work when editor is open
4. ~~**Migration test** - Old toolbar configs with `commandId: number` should auto-migrate~~ (skipped - pre-release)
5. **Large list performance** - Virtualization should handle 10k+ actions smoothly on mobile
6. **Reconnect behavior** - Action cache skips refetch if already populated

---

## Work Log

### Planning Phase (Complete ✅)
- [x] Explored existing frontend toolbar implementation
- [x] Explored existing backend action commands
- [x] Researched ReverseNamedCommandLookup buffer sizes → 128 bytes safe
- [x] Identified SWS/script ID stability issue → must use string identifiers
- [x] User decisions: replace Command ID field, tanstack-virtual, fetch on connect, merge tabs

### Phase 1: Backend (Complete ✅)
- [x] Added `ReverseNamedCommandLookup` binding to raw.zig, real.zig, backend.zig, mock/
- [x] Updated `action/getActions` to return 5-element arrays: `[cmdId, sectionId, name, isToggle, namedId]`
- [x] Added `sectionId` parameter to `action/execute` and `action/executeByName` (reserved for future use)
- [x] Updated API.md with new response format and parameter docs
- [x] Tests pass

**Notes:**
- `ReverseNamedCommandLookup` returns string WITHOUT leading underscore - we prepend `_` in the JSON output
- Section-specific execution not implemented yet - using `Main_OnCommand` for all sections (works for most cases)

**Deferred APIs** (for future section-specific execution):
```c
// Main section with more control
int KBD_OnMainActionEx(int cmd, int val, int valhw, int relmode, HWND hwnd, ReaProject* proj);

// MIDI Editor actions
HWND MIDIEditor_GetActive();  // Get active MIDI editor window
bool MIDIEditor_OnCommand(HWND midieditor, int command_id);  // Execute in MIDI editor
```

### Phase 2: Frontend Store (Complete ✅)
- [x] Created `actionsSlice.ts` with `ReaperAction` interface and cache state
- [x] Created `constants.ts` with `REAPER_SECTIONS` and `REAPER_SECTION_SHORT` maps
- [x] Updated `WebSocketCommands.ts` - added `sectionId` to execute commands, added `getActions`
- [x] Wired up action cache fetch in `useReaperConnection.ts` on connect
- [x] Updated `ToolbarAction` type - unified `reaper_action` with `actionId: string` and `sectionId: number`
- [x] Removed `reaper_action_name` type (merged into `reaper_action`)
- [x] Updated `ToolbarEditor.tsx` - merged tabs, accepts numeric ID or `_SWS_*` named ID
- [x] Updated `ToolbarButton.tsx` - uses `executeByName` for `_` prefixed actionIds
- [x] Fixed toggle state subscription to filter out SWS/script actions (dynamic IDs)
- [x] Build passes

**Notes:**
- No migration needed (pre-release app, can break old format)
- Toggle states only work for native REAPER actions (stable numeric IDs)
- SWS/script actions use named IDs but can't subscribe to toggle state (numeric ID is dynamic)
- Action cache skips refetch on reconnect if already populated
- **DEV FAILSAFE**: `App.tsx` has a line in `AppContent()` to clear localStorage on init - useful when API changes break stored data or to test clean slate:
  ```typescript
  localStorage.clear(); console.warn('DEV: localStorage cleared');
  ```

### Phase 3: Frontend UI (Complete ✅)
- [x] Created `ActionSearch.tsx` with tanstack-virtual
  - 56px row height for touch-friendly targets
  - Debounced search (150ms) for smooth typing
  - Filters by: name (case-insensitive substring), commandId (prefix), namedId (substring)
  - Shows: toggle indicator, action name, section badge, ID
  - Loading/error/empty states
  - `getStableActionId()` helper exported for consistent ID handling
- [x] Integrated ActionSearch into ToolbarEditor
  - Replaced manual Action ID input with searchable picker
  - Shows selected action with name, section badge, ID
  - "Change Action" button to reopen search
  - Handles edge cases: action not in cache, no action selected
  - Auto-populates label from action name when empty
- [x] Build passes

**Notes:**
- tanstack-virtual config: `estimateSize: 56`, `overscan: 5`
- `maxHeight` prop controls search list height (300px in editor modal)
- `currentActionFromCache` useMemo lookup enables action detail display

---

## Post-Implementation: Documentation Updates (In Progress)

### Phase 4: Documentation & API Completeness (Current)
- [ ] Update `DEVELOPMENT.md` - Add "Action ID Stability" section with guidance
- [ ] Add section-specific execution APIs to backend (don't just use Main_OnCommand)
  - `KBD_OnMainActionEx` for main section with full control
  - `MIDIEditor_GetActive` + `MIDIEditor_OnCommand` for MIDI Editor actions
- [ ] Update `API.md` - Document new response format and sectionId parameters
- [ ] Update this file with completion notes

**Why this matters:**
- Currently all actions route through `Main_OnCommand` which works for most cases
- MIDI Editor actions (sectionId 32060-32062) need `MIDIEditor_OnCommand` to work when editor is focused
- Proper delegation ensures actions execute in correct context
