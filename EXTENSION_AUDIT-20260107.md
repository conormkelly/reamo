# Reamo Extension Production Code Audit

**Date:** 2026-01-07
**Scope:** `/extension/src/` (63 .zig files, ~23,000 lines)
**Checklist:** ZIG_PRODUCTION_REVIEW_CHECKLIST.md
**Zig Version:** 0.15

---

## Executive Summary

The extension codebase is **production-ready** with excellent foundational safety patterns. No critical issues were found that could cause immediate crashes or data loss. The architecture demonstrates thoughtful design around memory management, thread safety, and FFI boundaries.

| Severity | Count | Risk Level |
|----------|-------|------------|
| Critical | 0 | None identified |
| High | ~~3~~ 0 ✅ | All fixed |
| Medium | ~~5~~ 0 ✅ | All fixed |
| Low | ~~4~~ 0 ✅ | All documented with AUDIT comments |

**Status:** All items addressed. Ready for production.

---

## 1. Memory Safety

### Status: EXCELLENT

The arena-based memory management is well-designed with proper lifetime tracking.

#### Positive Findings

| Pattern | Location | Notes |
|---------|----------|-------|
| Double-buffered arenas | [frame_arena.zig](extension/src/frame_arena.zig) | Eliminates memcpy, proper swap timing |
| Tiered arena system | [tiered_state.zig](extension/src/tiered_state.zig) | 20-200MB bounds, dynamic sizing |
| Per-frame scratch reset | [tiered_state.zig:437](extension/src/tiered_state.zig#L437) | Reset every frame before use |
| Peak usage tracking | [tiered_state.zig:154](extension/src/tiered_state.zig#L154) | Memory warnings at 80% |

#### No Issues Found

- No pointers held across arena swap (verified by code inspection)
- ArrayList API is Zig 0.15 compliant (checked via grep)
- No large stack allocations in timer callbacks
- Arena reset uses proper pattern

---

## 2. FFI Correctness

### Status: GOOD (with recommendations)

#### Positive Findings

| Pattern | Location | Notes |
|---------|----------|-------|
| Safe float-to-int | [ffi.zig:24-44](extension/src/ffi.zig#L24-L44) | NaN/Inf/range validation |
| Pointer validation API | [real.zig:464-480](extension/src/reaper/real.zig#L464-L480) | ValidatePtr2 wrapper |
| Proper callconv(.c) | All FFI functions | Verified via grep |
| C string handling | [raw.zig](extension/src/reaper/raw.zig) | Proper span() usage |

#### HIGH: Limited ValidatePtr Usage

**Severity:** High
**Complexity:** Medium
**Risk:** Crash if track/item deleted during enumeration

**Finding:** `validateTrackPtr` is only called in one location:

```
extension/src/commands/tracks.zig:41:    if (!api.validateTrackPtr(track)) {
```

**Recommendation:** Add validation before dereferencing REAPER pointers in polling functions, especially:
- [tracks.zig:177](extension/src/tracks.zig#L177) - `getTrackByUnifiedIdx` usage
- [items.zig:13](extension/src/commands/items.zig#L13) - item access without validation
- [fx.zig:83](extension/src/fx.zig#L83) - FX polling

**Fix Complexity:** ~2-3 hours to add validation wrapper to polling loops.

---

#### ~~MEDIUM: @ptrCast Without @alignCast in Some Paths~~ ✅ DOCUMENTED

**Severity:** Medium → Low (no actual risk)
**Complexity:** N/A
**Risk:** None - u8 has alignment 1

**Locations with SAFETY comments added:**
```
extension/src/commands/mod.zig:261    // SAFETY: @alignCast unnecessary - u8 has alignment 1
extension/src/commands/undo.zig:18    // SAFETY: @alignCast unnecessary - u8 has alignment 1
extension/src/commands/extstate.zig:82 // SAFETY: @alignCast unnecessary - u8 has alignment 1
```

**Resolution:** Added SAFETY comments to document why @alignCast is unnecessary. u8 arrays always have valid alignment.

---

## 3. Thread Safety

### Status: EXCELLENT

The threading model is well-designed with proper synchronization.

#### Positive Findings

| Pattern | Location | Notes |
|---------|----------|-------|
| Fine-grained locking | [ws_server.zig:72-77](extension/src/ws_server.zig#L72-L77) | Separate mutex for commands vs clients |
| RwLock for broadcasts | [ws_server.zig:89](extension/src/ws_server.zig#L89) | Read-heavy optimization |
| All locks use defer | [ws_server.zig:185-277](extension/src/ws_server.zig#L185-L277) | No deadlock risk |
| Atomic operations | [ws_server.zig:105-113](extension/src/ws_server.zig#L105-L113) | Proper release/acquire |
| Data copied before unlock | [ws_server.zig:256](extension/src/ws_server.zig#L256) | Allocation outside lock |

#### Verified Lock Patterns

All 8 `.lock()` calls have matching `defer unlock`:
- [ws_server.zig:185](extension/src/ws_server.zig#L185), [195](extension/src/ws_server.zig#L195), [211](extension/src/ws_server.zig#L211), [226](extension/src/ws_server.zig#L226), [239](extension/src/ws_server.zig#L239), [258](extension/src/ws_server.zig#L258), [276](extension/src/ws_server.zig#L276)

---

## 4. Error Handling

### Status: GOOD (with recommendations)

#### ~~HIGH: Silent Error Swallowing in Broadcast~~ ✅ FIXED

**Severity:** High
**Complexity:** Low
**Risk:** Network errors invisible, debugging difficulty

**Resolution:** Added rate-limited logging via `logWriteError()` helper in [ws_server.zig:178-192](extension/src/ws_server.zig#L178-L192). Logs first error immediately, then rate-limits to max once per 5 seconds to avoid spam. Uses atomics for thread-safe counting without blocking broadcasts.

The `conn.close()` calls remain silent - these occur after an error condition where we're already terminating the connection, and there's nothing meaningful to do if close fails.

---

#### ~~MEDIUM: Silent catch return in Logging~~ ✅ DOCUMENTED

**Severity:** Medium → Low (intentional design)
**Complexity:** N/A
**Risk:** None - can't log a logging failure

**Resolution:** Added AUDIT comment in [logging.zig:231-232](extension/src/logging.zig#L231-L232) explaining:
- Silent catch return is intentional - can't log a logging failure
- Ring buffer provides crash recovery for truncated messages
- File write failures have no meaningful recovery path

---

#### LOW: Test-Only unreachable Patterns

**Severity:** Low (tests only)
**Complexity:** N/A

**Locations (7 in tests):**
```
extension/src/playlist.zig:828:    const serialized = p.serialize(&buf) orelse unreachable;
extension/src/playlist.zig:831:    const p2 = Playlist.deserialize(serialized) orelse unreachable;
extension/src/playlist.zig:844, :847, :965, :984
extension/src/track_skeleton.zig:224
```

**Assessment:** These are all in test blocks. Acceptable - tests should fail hard. No action required.

---

## 5. Resource Leaks

### Status: EXCELLENT

#### Positive Findings

| Resource | Create | Destroy | Verification |
|----------|--------|---------|--------------|
| AudioAccessor | [items.zig:202](extension/src/commands/items.zig#L202) | [items.zig:206](extension/src/commands/items.zig#L206) | `defer` pattern |
| Command data | [ws_server.zig:256](extension/src/ws_server.zig#L256) | [ws_server.zig:22-24](extension/src/ws_server.zig#L22-L24) | `deinit()` method |
| Arenas | [tiered_state.zig:358-371](extension/src/tiered_state.zig#L358-L371) | [tiered_state.zig:381-386](extension/src/tiered_state.zig#L381-L386) | `errdefer` + `deinit` |
| WebSocket clients | [ws_server.zig:210-222](extension/src/ws_server.zig#L210-L222) | [ws_server.zig:225-233](extension/src/ws_server.zig#L225-L233) | Tracked map |

AudioAccessor usage in [items.zig:202-206](extension/src/commands/items.zig#L202-L206):
```zig
const accessor = api.makeTakeAccessor(take) orelse {...};
defer api.destroyTakeAccessor(accessor);  // CORRECT: Always destroyed
```

---

## 6. Numeric Safety

### Status: EXCELLENT

#### Positive Findings

| Pattern | Location | Notes |
|---------|----------|-------|
| safeFloatToInt wrapper | [ffi.zig:24-44](extension/src/ffi.zig#L24-L44) | Validates NaN/Inf/range |
| roundFloatToInt wrapper | [ffi.zig:47-55](extension/src/ffi.zig#L47-L55) | Rounds and validates |
| No i32 sample positions | Verified via grep | Uses appropriate types |
| BPM clamping | N/A | No division by BPM found |
| Safe division patterns | [tiered_state.zig:291-308](extension/src/tiered_state.zig#L291-L308) | Scale factors handled |

#### ~~MEDIUM: Direct @intFromFloat Without Wrapper~~ ✅ FIXED

**Severity:** Medium
**Complexity:** Low
**Risk:** Panic on NaN/Inf from corrupt project data

**Resolution:** All @intFromFloat calls now use the ffi validation wrappers:
- transport.zig:67 - Already validated via normalizeBeats() clamping (SAFE)
- transport.zig:199,260 - Already validated via normalizeBeats() (SAFE)
- markers.zig:233,252,253 - Updated to use ffi.roundFloatToInt with error handling
- items.zig:209 - Updated to use ffi.isFinite + ffi.safeFloatToInt
- tempo.zig:108 - Updated to use ffi.roundFloatToInt with error handling

---

## 7. WebSocket Security

### Status: NEEDS IMPROVEMENT

#### HIGH: Missing Host Header Validation (DNS Rebinding)

**Severity:** High
**Complexity:** Medium
**Risk:** DNS rebinding attack allows malicious websites to access WebSocket

**Finding:** No Host header validation in [ws_server.zig](extension/src/ws_server.zig).

Grep for `host` or `Host` in ws_server.zig returns no matches.

**Attack Scenario:**
1. Attacker registers evil.com, points DNS to 127.0.0.1
2. User visits evil.com
3. JavaScript on evil.com connects to ws://localhost:9224
4. Browser allows connection (same resolved IP)
5. Attacker can control REAPER remotely

**Required Fix:**
```zig
pub fn init(h: *const websocket.Handshake, conn: *websocket.Conn, state: *SharedState) !Client {
    // REQUIRED: Validate Host header against localhost
    const host = h.headers.get("host") orelse {
        conn.close(.{ .code = 4003, .reason = "Missing Host header" }) catch {};
        return error.MissingHost;
    };
    if (!isValidLocalhost(host)) {
        conn.close(.{ .code = 4003, .reason = "Invalid Host" }) catch {};
        return error.InvalidHost;
    }
    // ... existing token validation ...
}

fn isValidLocalhost(host: []const u8) bool {
    return std.mem.startsWith(u8, host, "127.0.0.1:") or
           std.mem.startsWith(u8, host, "localhost:");
}
```

**Fix Complexity:** 1 hour

---

#### ~~MEDIUM: No Explicit max_message_size~~ ✅ FIXED

**Severity:** Medium
**Complexity:** Low
**Risk:** Memory exhaustion from large payloads

**Resolution:** Added explicit `max_message_size = 64 * 1024` in [ws_server.zig:522-525](extension/src/ws_server.zig#L522-L525).

**Note:** The websocket library already defaults to 64KB, but we now set it explicitly for auditability. This limit applies only to incoming messages — outgoing messages are bounded by our arena system.

---

#### Positive Security Findings

| Pattern | Location | Notes |
|---------|----------|-------|
| Session token auth | [ws_server.zig:126-143](extension/src/ws_server.zig#L126-L143) | Required for commands |
| Protocol version check | [ws_server.zig:358-369](extension/src/ws_server.zig#L358-L369) | Rejects mismatched clients |
| Bounded JSON parsing | [protocol.zig](extension/src/protocol.zig) | Fixed buffers, no allocations |
| Connection limiting | [ws_server.zig:12](extension/src/ws_server.zig#L12) | MAX_CLIENTS = 64 |

---

## 8. Comptime Correctness

### Status: EXCELLENT

#### Positive Findings

| Pattern | Location | Notes |
|---------|----------|-------|
| Backend validation | [backend.zig](extension/src/reaper/backend.zig) | Comptime interface check |
| State type validation | [frame_arena.zig:103-107](extension/src/frame_arena.zig#L103-L107) | Requires `empty()` method |
| Limited inline for | Commands only | Reasonable iteration counts |

No excessive `inline for` usage found. Command dispatch is bounded by registered commands (~30).

---

## 9. Testing Completeness

### Status: GOOD

#### Existing Test Coverage

| Module | Test Count | Coverage |
|--------|------------|----------|
| ffi.zig | 15 tests | Comprehensive |
| frame_arena.zig | 8 tests | Full arena patterns |
| tiered_state.zig | 18 tests | Sizing, resize, thresholds |
| protocol.zig | 27 tests | JSON parsing |
| transport.zig | 10 tests | Edge cases |
| ws_server.zig | 3 tests | Ring buffer |

#### Recommendations

1. **Add thread safety tests** - Test concurrent command/broadcast
2. **Add mock failure injection** - Test OOM paths
3. **Long-running stress test** - Verify no memory growth over hours

---

## 10. Zig 0.15 Migration

### Status: COMPLETE

The codebase is already on Zig 0.15. No migration issues found.

#### Verified Patterns

| Pattern | Status |
|---------|--------|
| ArrayList with explicit allocator | N/A (uses AutoArrayHashMap which is managed) |
| No BoundedArray usage | Confirmed |
| No async/await usage | Confirmed |
| No usingnamespace | Confirmed |
| Custom panic handler | [logging.zig:10-22](extension/src/logging.zig#L10-L22) uses 0.15 API |

---

## Summary of Recommended Fixes

### ~~Priority 1 (Before Release)~~ ✅ ALL FIXED

| Issue | Severity | Status | File |
|-------|----------|--------|------|
| DNS rebinding protection | High | ✅ Fixed | ws_server.zig |
| ValidatePtr in polling | High | ✅ Fixed | tracks.zig, items.zig, fx.zig |
| Broadcast error logging | High | ✅ Fixed | ws_server.zig |

### Priority 2 (Hardening)

| Issue | Severity | Status | File |
|-------|----------|--------|------|
| max_message_size config | Medium | ✅ Fixed | ws_server.zig |
| safeFloatToInt consistency | Medium | ✅ Fixed | markers.zig, items.zig, tempo.zig |

### No Action Required (AUDIT comments added)

- Test-only unreachable (acceptable - tests should fail hard)
- Silent logging catch return (can't log logging failure) - **AUDIT comment added to logging.zig**
- @ptrCast for u8 arrays (alignment 1 is always valid) - **SAFETY comments added to mod.zig, undo.zig, extstate.zig**

---

## Conclusion

The Reamo extension demonstrates production-quality code with excellent memory management, thread safety, and FFI handling.

**All items addressed:**
- 3 High severity: Fixed (DNS rebinding, ValidatePtr, broadcast logging)
- 2 Medium severity: Fixed (max_message_size, safeFloatToInt)
- 4 Low severity: Documented with AUDIT/SAFETY comments

The codebase is ready for production release.
