# API Test Results - 2025-12-23

Comprehensive WebSocket API testing performed using `websocat` against the Zig extension running on port 9224.

## Test Setup

```bash
# Get credentials from EXTSTATE
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/WebSocketPort"
# Returns: EXTSTATE	Reamo	WebSocketPort	9224

curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken"
# Returns: EXTSTATE	Reamo	SessionToken	5764548b75fb8e044276dffc80097ddc

# Test command helper
TOKEN="5764548b75fb8e044276dffc80097ddc"
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 echo '{"type":"command","command":"transport/play","id":"1"}'
 sleep 0.1) | websocat ws://localhost:9224
```

---

## Summary

| Category | Documented | Working | Missing |
|----------|------------|---------|---------|
| Transport | 10 | 7 | 1 (+2 untested) |
| Time Selection | 7 | 4 | 3 |
| Repeat | 2 | 2 | 0 |
| Marker | 6 | 6 | 0 |
| Region | 4 | 4 | 0 |
| Item | 10 | 5 | 4 (+1 untested) |
| Take | 4 | 4 | 0 |
| Track | 7 | 7 | 0 |
| Meter | 1 | 1 | 0 |
| Tempo | 2 | 2 | 0 |
| Metronome | 3 | 3 | 0 |
| ExtState | 4 | 4 | 0 |
| Undo | 3 | 3 | 0 |
| Action | 3 | 1 | 2 |
| **TOTAL** | **66** | **53** | **10** |

---

## Missing Commands (UNKNOWN_COMMAND errors)

These commands are documented in API.md but return `UNKNOWN_COMMAND`:

### 1. `transport/playPause`

**API.md says:**
```json
{"type": "command", "command": "transport/playPause"}
```

**Actual response:**
```json
{"type":"response","id":"t4","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Add command handler in transport module.

---

### 2. `timeSelection/setByBars`

**API.md says:**
```json
{"type": "command", "command": "timeSelection/setByBars", "startBar": 1, "endBar": 9}
```

**Actual response:**
```json
{"type":"response","id":"ts2","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Implement bar-based time selection using `TimeMap_timeToBeats` / `TimeMap_beatsToTime`.

---

### 3. `timeSelection/setStartAtCursor`

**API.md says:**
```json
{"type": "command", "command": "timeSelection/setStartAtCursor"}
```

**Actual response:**
```json
{"type":"response","id":"ts3","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Get cursor position with `GetCursorPosition()`, then call `GetSet_LoopTimeRange2()` preserving end.

---

### 4. `timeSelection/setEndAtCursor`

**API.md says:**
```json
{"type": "command", "command": "timeSelection/setEndAtCursor"}
```

**Actual response:**
```json
{"type":"response","id":"ts4","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Get cursor position, call `GetSet_LoopTimeRange2()` preserving start.

---

### 5. `item/setColor`

**API.md says:**
```json
{"type": "command", "command": "item/setColor", "trackIdx": 0, "itemIdx": 0, "color": 16711680}
```

**Actual response:**
```json
{"type":"response","id":"i3","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Use `SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color | 0x1000000)`.

---

### 6. `item/setLock`

**API.md says:**
```json
{"type": "command", "command": "item/setLock", "trackIdx": 0, "itemIdx": 0, "locked": 1}
```

**Actual response:**
```json
{"type":"response","id":"i4","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Use `SetMediaItemInfo_Value(item, "C_LOCK", locked)`. Toggle if param omitted.

---

### 7. `item/setNotes`

**API.md says:**
```json
{"type": "command", "command": "item/setNotes", "trackIdx": 0, "itemIdx": 0, "notes": "text"}
```

**Actual response:**
```json
{"type":"response","id":"i5","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Use `GetSetMediaItemInfo_String(item, "P_NOTES", notes, true)`.

---

### 8. `item/select`

**API.md says:**
```json
{"type": "command", "command": "item/select", "trackIdx": 0, "itemIdx": 0}
```

**Actual response:**
```json
{"type":"response","id":"i7","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Call `SelectAllMediaItems(0, false)` then `SetMediaItemSelected(item, true)`.

---

### 9. `action/getToggleState`

**API.md says:**
```json
{"type": "command", "command": "action/getToggleState", "commandId": 40364}
```

**Actual response:**
```json
{"type":"response","id":"a1","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Use `GetToggleCommandState(commandId)`. Returns -1/0/1.

---

### 10. `action/executeByName`

**API.md says:**
```json
{"type": "command", "command": "action/executeByName", "name": "_SWS_ABOUT"}
```

**Actual response:**
```json
{"type":"response","id":"a3","success":false,"error":{"code":"UNKNOWN_COMMAND","message":"Command not found"}}
```

**Fix needed:** Use `NamedCommandLookup(name)` to get ID, then `Main_OnCommand(id, 0)`.

---

## Bugs Found

### 1. ~~`extstate/projGet` returns only first character~~ FIXED

**Root cause:** REAPER's `GetProjExtState()` returns an incorrect length (always 1) but writes the full value to the buffer. The fix is to ignore REAPER's return value and find the null terminator ourselves using `std.mem.indexOfScalar()`.

**Fix location:** `src/reaper.zig` - `getProjExtStateValue()` function.

---

### 2. ~~API.md documents wrong parameter name for action/execute~~ FIXED

**Status:** Fixed after rebuild. `action/execute` now accepts `commandId` as documented.

---

## Commands Not Tested (Destructive)

These weren't tested to avoid data loss:

1. `transport/record` - Would start recording
2. `transport/stopAndDelete` - Deletes recorded media
3. `item/delete` - Deletes items

---

## Working Commands (Verified)

### Transport
- ✅ `transport/play`
- ✅ `transport/stop`
- ✅ `transport/pause`
- ✅ `transport/seek`
- ✅ `transport/seekBeats`
- ✅ `transport/goStart`
- ✅ `transport/goEnd`

### Time Selection
- ✅ `timeSelection/set`
- ✅ `timeSelection/goStart`
- ✅ `timeSelection/goEnd`
- ✅ `timeSelection/clear`

### Repeat
- ✅ `repeat/set`
- ✅ `repeat/toggle`

### Marker
- ✅ `marker/add`
- ✅ `marker/update`
- ✅ `marker/delete`
- ✅ `marker/goto`
- ✅ `marker/next`
- ✅ `marker/prev`

### Region
- ✅ `region/add`
- ✅ `region/update`
- ✅ `region/delete`
- ✅ `region/goto`

### Item
- ✅ `item/setActiveTake`
- ✅ `item/move`
- ✅ `item/goto`
- ✅ `item/selectInTimeSel`
- ✅ `item/unselectAll`

### Take
- ✅ `take/next`
- ✅ `take/prev`
- ✅ `take/delete`
- ✅ `take/cropToActive`

### Track
- ✅ `track/setVolume`
- ✅ `track/setPan`
- ✅ `track/setMute`
- ✅ `track/setSolo`
- ✅ `track/setRecArm`
- ✅ `track/setRecMon`
- ✅ `track/setFxEnabled`

### Meter
- ✅ `meter/clearClip`

### Tempo
- ✅ `tempo/set`
- ✅ `tempo/tap`

### Metronome
- ✅ `metronome/toggle`
- ✅ `metronome/getVolume`
- ✅ `metronome/setVolume`

### ExtState
- ✅ `extstate/get`
- ✅ `extstate/set`
- ✅ `extstate/projSet`
- ⚠️ `extstate/projGet` (buggy - returns only first char)

### Undo
- ✅ `undo/add`
- ✅ `undo/begin`
- ✅ `undo/end`

### Action
- ✅ `action/execute` (with `commandId` param - FIXED)

---

## Implementation Priority

### High Priority (Core functionality gaps)
1. `transport/playPause` - Common toggle action
2. `item/select` - Essential for item operations
3. `extstate/projGet` bug fix - Data corruption

### Medium Priority (Convenience features)
4. `timeSelection/setByBars` - Bar-based selection
5. `timeSelection/setStartAtCursor` - Common workflow
6. `timeSelection/setEndAtCursor` - Common workflow
7. `action/getToggleState` - UI state checking
8. `action/executeByName` - SWS/custom action support

### Low Priority (Nice to have)
9. `item/setColor` - Visual customization
10. `item/setLock` - Protection feature
11. `item/setNotes` - Metadata

### Documentation fixes
- Update `commandId` → `actionId` in API.md
- Remove `action/executeCommand` reference
