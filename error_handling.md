# Silent Error Handling Audit

This document catalogs all instances of silent error handling (`catch return null`, `catch return;`) in the codebase. Use this as a checklist to systematically add proper error handling.

**Created:** 2026-01-07
**Status:** In Progress

---

## Tasks

- [x] **Update DEVELOPMENT.md** - Add "Common Pitfalls" entry prohibiting silent `catch return` patterns. *(DONE 2026-01-07 - Added as item #18)*

---

## Priority Levels

| Priority | Criteria | Action Required |
|----------|----------|-----------------|
| **HIGH** | Error is obscured, wrong error returned to caller | Log actual error, consider propagating |
| **MEDIUM** | Client never receives response/event, debugging difficult | Add warning log |
| **LOW** | Internal helper, semantics are correct | Document why acceptable, or add debug log |
| **ACCEPTABLE** | Debug/logging code, can't log own failures | No change needed |

---

## Category 1: Subscription Slot Allocation (HIGH PRIORITY)

HashMap `put` failures (could be OOM) are silently converted to `null`, then caller returns `error.TooManyClients`. The actual error is obscured.

### toggle_subscriptions.zig

- [x] **Line 77** - `getOrCreateSlot` *(FIXED 2026-01-07)*
  Now logs: `logging.warn("toggle_subscriptions: slot allocation failed for client {d}: {}", ...)`

### track_subscriptions.zig

- [x] **Line 127** - `getOrCreateSlot` (reuse slot path) *(FIXED 2026-01-07)*
  Now logs: `logging.warn("track_subscriptions: slot reuse failed for client {d}: {}", ...)`

- [x] **Line 141** - `getOrCreateSlot` (new slot path) *(FIXED 2026-01-07)*
  Now logs: `logging.warn("track_subscriptions: slot allocation failed for client {d}: {}", ...)`

---

## Category 2: ResponseWriter Methods (MEDIUM PRIORITY) *(ALL FIXED)*

Response serialization failures now log warnings before returning.

### commands/mod.zig

- [x] **Line 78-86** - `success()` *(FIXED 2026-01-07)*
  Now logs: `logging.warn("ResponseWriter.success: buffer overflow for cmd_id={s}, payload_len={d}", ...)`

- [x] **Line 126** - `successWithAction()` *(FIXED 2026-01-07)*
  Now logs: `logging.warn("ResponseWriter.successWithAction: buffer overflow for cmd_id={s}", ...)`

- [x] **Line 163** - `err()` *(FIXED 2026-01-07)*
  Now logs: `logging.warn("ResponseWriter.err: buffer overflow for cmd_id={s}, code={s}", ...)`

- [x] **Line 178** - `warn()` *(FIXED 2026-01-07)*
  Now logs: `logging.warn("ResponseWriter.warn: buffer overflow for cmd_id={s}, code={s}", ...)`

**Note:** `successLargePayload()` already had proper error handling - sends error response to client.

---

## Category 3: Event Serialization - toJson Methods (MEDIUM PRIORITY)

When serialization fails, events are silently dropped. Clients don't receive updates.

**Strategy:** Rather than logging every `catch return null` (would spam on first failure), add a single log at the function exit point.

### transport.zig

- [ ] **Lines 181-273** - `State.toJson()` (~15 instances)
  - Line 181, 185, 187, 190, 210, 212, 224, 245, 249, 251, 254, 271, 273

### project.zig

- [ ] **Lines 168-226** - `State.toJson()` (~18 instances)
  - Lines 168, 172-176, 179, 183-187, 191, 194-198, 202, 205-209, 226

### fx.zig

- [ ] **Lines 150-169** - `State.toJson()` (~8 instances)
  - Lines 150, 153, 157, 158, 159, 160, 166, 169

### tracks.zig

- [ ] **Lines 313-389** - `State.toJson()` (~30 instances)
  - Track data serialization

- [ ] **Lines 408-482** - `State.toJsonWithTotal()` (~30 instances)
  - Track data with total count

- [ ] **Lines 583-617** - `MeteringState.toJsonMap()` (~15 instances)
  - Meter data serialization

### markers.zig

- [ ] **Lines 280-327** - `State.markersToJson()` and `regionsToJson()` (~20 instances)

### playlist.zig

- [ ] **Lines 558-621** - `State.toJson()` (~25 instances)

- [ ] **Lines 126-137** - `Playlist.serialize()` (~5 instances)

### items.zig

- [ ] **Lines 221-270** - `State.toJson()` (~18 instances)

### sends.zig

- [ ] **Lines 136-152** - `State.toJson()` (~7 instances)

### track_skeleton.zig

- [ ] **Lines 114-133** - `State.toJson()` (~9 instances)

### toggle_subscriptions.zig

- [ ] **Lines 218-229** - `formatChangesEvent()` (~5 instances)

- [ ] **Lines 239-250** - `formatStatesPayload()` (~5 instances)

### tempomap.zig

- [ ] **Lines 50-67** - `State.toJson()` (~5 instances)

### errors.zig

- [ ] **Lines 257-280** - `ErrorEvent.toJson()` (~12 instances)

**Recommended fix pattern for toJson:**
```zig
pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    var writer = stream.writer();

    // All the writer.print(...) catch return null; calls

    return stream.getWritten();
}

// Change to:
pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    var writer = stream.writer();

    self.writeJson(writer) catch {
        logging.debug("transport.State.toJson: serialization failed (buffer overflow)", .{});
        return null;
    };

    return stream.getWritten();
}

fn writeJson(self: *const State, writer: anytype) !void {
    try writer.print("...", .{...});
    // ... all writes with try instead of catch return null
}
```

---

## Category 4: Command Handler Response Formatting (MEDIUM PRIORITY)

### commands/items.zig

- [x] **Lines 345-376** - `formatPeaksResponse()` *(ACCEPTABLE)*
  **Decision:** Helper function returns null, caller properly handles with `response.err()`. No change needed.

### commands/extstate.zig

- [x] **Lines 15-19** - `formatValue()` *(ACCEPTABLE)*
  **Decision:** Helper function returns null, caller properly handles with `response.err()`. No change needed.

### commands/actions.zig

- [x] **Line 16** - `handleGetToggleState()` *(FIXED 2026-01-07)*
  Now logs: `logging.warn("actions: getToggleState response format failed", ...)`

### commands/tempo.zig

- [x] **Lines 57, 86, 118, 167** - Various handlers *(FIXED 2026-01-07)*
  Now logs: `logging.warn("tempo: <handler> response format failed", ...)`

---

## Category 5: WebSocket Server (MEDIUM PRIORITY) *(ALL FIXED)*

### ws_server.zig

- [x] **Line 362** - Protocol mismatch error response *(FIXED 2026-01-07)*
  Now logs: `logging.warn("ws_server: protocol mismatch response buffer overflow", ...)`

- [x] **Line 404** - Clock sync response *(FIXED 2026-01-07)*
  Now logs: `logging.warn("ws_server: clock sync response buffer overflow", ...)`

---

## Category 6: Playlist Persistence (LOW PRIORITY) *(ALL FIXED)*

### playlist.zig

- [x] **Line 644** - `savePlaylist()` key formatting *(FIXED 2026-01-07)*
  Now logs: `logging.warn("playlist: savePlaylist key format failed for idx={d}", ...)`

- [x] **Line 665** - `clearPlaylist()` key formatting *(FIXED 2026-01-07)*
  Now logs: `logging.warn("playlist: clearPlaylist key format failed for idx={d}", ...)`

- [x] **Line 676** - `savePlaylistCount()` count formatting *(FIXED 2026-01-07)*
  Now logs: `logging.warn("playlist: savePlaylistCount format failed for count={d}", ...)`

---

## Category 7: Protocol JSON Helpers (LOW PRIORITY - ACCEPTABLE)

These are internal lookup functions where `null` = "key not found" is correct semantics.

### protocol.zig

- [x] **Lines 81, 108, 216, 250, 285, 321, 356** - Pattern buffer creation for key lookup

  **Decision:** ACCEPTABLE - These are internal helpers. Returning null for "key not found" is the intended behavior. The pattern buffer is 64 bytes which is sufficient for any reasonable JSON key.

---

## Category 8: Debug/Logging Code (ACCEPTABLE)

Cannot log failures in logging code itself.

### main.zig

- [x] **Lines 32, 36** - Debug file logging for playlist tick

  **Decision:** ACCEPTABLE - Debug code that's gated behind a flag.

### reaper/raw.zig

- [x] **Lines 379, 396** - Console output formatting

  **Decision:** ACCEPTABLE - If console output fails, nothing we can do.

### logging.zig

- [x] **Lines 158, 188, 232, 243, 277** - Log file operations

  **Decision:** ACCEPTABLE - Logger can't log its own failures.

---

## Progress Summary

| Category | Total Items | Fixed | Acceptable | Remaining |
|----------|-------------|-------|------------|-----------|
| 1. Subscription Slots | 3 | 3 | 0 | 0 |
| 2. ResponseWriter | 5 | 5 | 0 | 0 |
| 3. Event Serialization | ~150 | 0 | 0 | ~150 (DEFERRED) |
| 4. Command Handlers | 4 | 2 | 2 | 0 |
| 5. WebSocket Server | 2 | 2 | 0 | 0 |
| 6. Playlist Persistence | 3 | 3 | 0 | 0 |
| 7. Protocol Helpers | 7 | 0 | 7 | 0 |
| 8. Debug/Logging | 5 | 0 | 5 | 0 |
| **Total** | **~179** | **15** | **14** | **~150** |

**Last Updated:** 2026-01-07

**Note:** Category 3 (Event Serialization) is deferred pending best-practice decision on toJson refactoring approach.

---

## Implementation Notes

### When to use each approach:

1. **Return error to caller** - When the caller can handle it meaningfully
2. **Log + return null/void** - When failure is recoverable but should be visible
3. **Silent return** - Only for debug code or when logging would cause infinite recursion

### Logging levels:

- `logging.err()` - Should never happen, indicates bug
- `logging.warn()` - Unexpected but recoverable
- `logging.debug()` - Expected in edge cases (buffer overflow on very large data)

### Testing considerations:

After adding logging, verify:
1. Build still succeeds
2. Tests still pass
3. No log spam during normal operation
4. Errors ARE logged when buffer overflows occur (test with small buffers)
