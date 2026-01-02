# Extension Stability Review

## Critical Issues (Potential Crash Vectors)

### 1. Shutdown Race Condition

**Location:** [ws_server.zig:430-437](extension/src/ws_server.zig#L430-L437) + [main.zig:461-518](extension/src/main.zig#L461-L518)

The `Server.stop()` function is a no-op (does nothing):

```zig
pub fn stop(self: *Server) void {
    // ...just let the OS clean up when the process exits
    _ = self;
}
```

During shutdown in main.zig:

1. Timer is unregistered (stops main thread processing)
2. `server.stop()` is called (does nothing)
3. SharedState is freed
4. **WebSocket thread may still be running** and accessing freed memory

This is fine if REAPER exits entirely, but if the extension is unloaded while REAPER keeps running (hot reload), the detached WebSocket thread will crash accessing freed `SharedState`.

---

### 2. Missing `@intFromFloat` Protection

**Location:** [reaper.zig:964](extension/src/reaper.zig#L964), [reaper.zig:986](extension/src/reaper.zig#L986)

You have `safeFloatToInt()` defined but these methods don't use it:

```zig
// Line 964 - VULNERABLE
pub fn getTrackSolo(self: *const Api, track: *anyopaque) c_int {
    const f = self.getMediaTrackInfo_Value orelse return 0;
    return @intFromFloat(f(track, "I_SOLO"));  // Panics on NaN/Inf!
}

// Line 986 - VULNERABLE
pub fn getTrackRecMon(self: *const Api, track: *anyopaque) c_int {
    const f = self.getMediaTrackInfo_Value orelse return 0;
    return @intFromFloat(f(track, "I_RECMON"));  // Panics on NaN/Inf!
}
```

If REAPER returns corrupted data (NaN/Inf), Zig's `@intFromFloat` will panic and crash REAPER.

---

### 3. Potential Integer Overflow in Beat Calculations

**Location:** [commands/tempo.zig:111-112](extension/src/commands/tempo.zig#L111-L112)

```zig
const scaled: u32 = @intFromFloat(@round((beats_info.beats_in_measure + 1.0) * 100.0));
```

If `beats_in_measure` is NaN/Inf (from `api.timeToBeats()` returning corrupt data), this crashes.

---

## High-Risk Issues

### 4. JSON Injection in ExtState

**Location:** [commands/extstate.zig:34](extension/src/commands/extstate.zig#L34)

```zig
const payload = std.fmt.bufPrint(&payload_buf, "{{\"value\":\"{s}\"}}", .{value}) catch {
```

The `value` from REAPER's ExtState is inserted directly into JSON without escaping. If an ExtState value contains `"` or `\`, the JSON will be malformed and clients may crash parsing it.

---

### 5. setTimePreciseFn Race

**Location:** [ws_server.zig:140-142](extension/src/ws_server.zig#L140-L142)

Comment claims "set once at startup before any clock sync requests", but there's no guarantee. The websocket server starts immediately after being created, and a client could send a clockSync request before `setTimePreciseFn()` is called. The null check returns 0 (not a crash), but timing will be wrong.

---

### 6. Allocation Failure Silent Drops

**Location:** Multiple locations

In [gesture_state.zig](extension/src/gesture_state.zig) and [toggle_subscriptions.zig](extension/src/toggle_subscriptions.zig):

```zig
to_remove.append(...) catch {};  // Silent failure
self.ref_counts.put(cmd_id, count - 1) catch {};  // Silent failure
```

If allocation fails, gestures/subscriptions may never be cleaned up, causing memory leaks and stale state.

---

## Medium-Risk Issues

### 7. Large Stack Allocations

Several functions use large stack buffers that could cause stack overflow on constrained systems:

- [items.zig](extension/src/items.zig): `[65536]u8` for peak data
- [project_notes.zig](extension/src/project_notes.zig): `[65536]u8` buffers
- [main.zig](extension/src/main.zig): `[32768]u8` for item JSON

---

### 8. Fixed Limits with Silent Truncation

- `MAX_ITEMS = 512` - Projects with more items silently lose data
- `MAX_MARKERS = 256` - Same issue
- `MAX_TRACKS = 128` (inferred from metering) - Same issue

---

### 9. items.zig Active Take Index Cast

**Location:** Line ~162

```zig
take.is_active = (take_idx == @as(usize, @intCast(item.active_take_idx)));
```

If `active_take_idx` is somehow negative (shouldn't happen but...), the cast to `usize` could wrap or panic depending on safety settings.

---

## Observations (Low Risk but Notable)

### 10. Thread Detach Pattern

The WebSocket thread is detached immediately:

```zig
pub fn start(self: *Server) !void {
    const thread = try self.server.listenInNewThread(self.state);
    thread.detach();
}
```

This prevents clean shutdown, which is the root cause of issue #1.

---

### 11. Error Suppression Pattern

Many handlers use `catch return` or `catch {}` to suppress errors for robustness, which is good for not crashing but makes debugging difficult.

---

## Recommendations (Priority Order)

1. **Fix `@intFromFloat` calls** - Use `safeFloatToInt()` in `getTrackSolo()` and `getTrackRecMon()`

2. **Add JSON escaping for ExtState** - Escape `"`, `\`, and control chars in extstate response values

3. **Consider shutdown ordering** - Document that extension reload requires REAPER restart, or implement a proper cleanup signal

4. **Add NaN/Inf validation at trust boundaries** - Particularly for beat/time calculations from REAPER API

---

## Most Likely Crash Cause for Your Random Crash

Given the patterns above, the most likely culprits are:

1. **`getTrackSolo()` or `getTrackRecMon()` receiving NaN/Inf** - If a track state is corrupted, polling will crash
2. **Beat calculation overflow** in tempo/marker formatting during transport polling
3. **Shutdown race condition** if you reloaded the extension without restarting REAPER

To investigate further:

- Check if crash happened during playback (beat calculations)
- Check if crash happened after extension reload
- Enable file logging (`initLogFile()` is already there) to capture last state before crash
