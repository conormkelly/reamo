# Extension Resilience Plan

This document is a living plan for systematically rearchitecting the Reamo Zig extension for resilience, testability, and stability. It will be passed to sequential Claude sessions to maintain context.

## Prime Directive

**Never crash REAPER.** A crash means potential data loss for the user. Every design decision flows from this principle.

## Core Principles (from Research)

1. **Never silently swallow errors** - Errors must propagate with context for debugging
2. **Never send fake "safe default" data to clients** - Explicit nulls and error codes, not fabricated values
3. **Validate at trust boundaries** - REAPER C API returns are untrusted; validate immediately
4. **Allocation-free error paths** - Use stack buffers for error context, pre-allocated ring buffers for logging
5. **Graceful degradation** - Partial data with error markers is better than crash or fake data
6. **Testability** - Every module should be unit-testable with mocked REAPER API

## Current Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                           main.zig                                   │
│  - ReaperPluginEntry (startup/shutdown)                             │
│  - initTimerCallback (deferred init, WebSocket server start)        │
│  - processTimerCallback (30Hz polling loop, command dispatch)       │
│  - Global state: g_api, g_server, g_shared_state, g_last_*          │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
┌──────────────────────┐  ┌─────────────────┐  ┌───────────────────┐
│     reaper.zig       │  │  ws_server.zig  │  │   commands/*.zig  │
│  - Api struct        │  │  - Server       │  │  - Handler funcs  │
│  - C API wrappers    │  │  - SharedState  │  │  - ResponseWriter │
│  - REAPER constants  │  │  - Client       │  │  - Per-domain     │
└──────────────────────┘  │  - Ring buffer  │  └───────────────────┘
                          └─────────────────┘
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
┌──────────────────────┐  ┌─────────────────┐  ┌───────────────────┐
│   transport.zig      │  │   tracks.zig    │  │   markers.zig     │
│   project.zig        │  │   items.zig     │  │   tempomap.zig    │
│   (State structs     │  │   (State poll   │  │   project_notes   │
│    with poll/toJson) │  │    + JSON)      │  │   gesture_state   │
└──────────────────────┘  └─────────────────┘  └───────────────────┘
```

### Threading Model
- **Main Thread**: REAPER context, timer callbacks, API calls, command processing
- **WebSocket Thread**: Detached, handles connections, queues commands via mutex
- **SharedState**: Mutex-protected command queue and client list

## Identified Issues (from EXTENSION_STABILITY_REVIEW.md)

### Critical (Crash Vectors)
1. **Shutdown race condition** - WebSocket thread may access freed SharedState
2. **Missing @intFromFloat protection** - `getTrackSolo()`, `getTrackRecMon()` can panic
3. **Beat calculation overflow** - `@intFromFloat` in `transport.zig` without validation

### High-Risk
4. **JSON injection in ExtState** - Unescaped values in JSON output
5. **setTimePreciseFn race** - No atomic/mutex on function pointer access
6. **Allocation failure silent drops** - `catch {}` throughout codebase

### Medium-Risk
7. **Large stack allocations** - 64KB+ buffers on stack
8. **Fixed limits with silent truncation** - MAX_ITEMS=512, MAX_MARKERS=256
9. **Active take index cast** - Could panic on negative value

---

## Phase 1: Foundation - Error Types and FFI Validation

**Goal**: Create the error infrastructure and validate at REAPER API boundary

### 1.1 Create Error Infrastructure
- [ ] Create `extension/src/errors.zig`:
  - `ReamoError` - Composed error set for all modules
  - `FFIError` - NullPointer, FloatIsNaN, FloatIsInf, IntegerOverflow
  - `ReaperStateError` - TrackDeleted, ItemDeleted, InvalidProject
  - `ResourceError` - OutOfMemory, BufferFull, QueueOverflow
- [ ] Create `extension/src/error_context.zig`:
  - `ErrorContext` - Stack-based error context (no allocation)
  - 256-byte message buffer, API name, source location, timestamp
  - `errdefer` integration pattern

### 1.2 Create FFI Validation Layer
- [ ] Create `extension/src/ffi.zig`:
  - `safeFloatToInt()` - Returns error on NaN/Inf/out-of-range
  - `sanitizeFloat()` - Returns error on NaN/Inf
  - `requirePtr()` - Converts nullable to error
  - `validateTrack()` - Checks for deleted tracks via ValidatePtr2
- [ ] Update `reaper.zig`:
  - Import and use FFI validation in all wrappers
  - `getTrackSolo()` → returns `FFIError!c_int`
  - `getTrackRecMon()` → returns `FFIError!c_int`
  - `timeToBeats()` → validate time parameter before call, validate return
  - Every `@intFromFloat` wrapped with safe version

### 1.3 Unit Tests for FFI Layer
- [ ] Test `safeFloatToInt` with NaN, Inf, overflow, normal values
- [ ] Test `sanitizeFloat` with edge cases
- [ ] Test error propagation patterns

**Validation**: `zig build test` passes, no panics possible from FFI layer

---

## Phase 2: State Module Resilience

**Goal**: Make poll() functions return partial data with explicit error markers

### 2.1 Define Result Types
- [ ] Create result types that can express partial success:
  ```zig
  const PollResult = struct {
      data: ?State,
      errors: ErrorList, // Stack-allocated, fixed-size
      stale: bool,
  };
  ```

### 2.2 Update transport.zig
- [ ] `poll()` validates all values from REAPER
- [ ] Return explicit null/error for corrupt position_beat
- [ ] `toJson()` and `toTickJson()` handle null beat data
- [ ] Remove the "plaster" `safeScaledBeat()` - replace with proper error handling
- [ ] Add tests with mocked corrupt API responses

### 2.3 Update tracks.zig
- [ ] Validate volume, pan, mute, solo for each track
- [ ] Skip tracks with errors, continue iteration
- [ ] Track which tracks had errors in response
- [ ] Add tests

### 2.4 Update markers.zig, items.zig, tempomap.zig
- [ ] Same pattern: validate at poll, propagate errors
- [ ] Handle limit exceeded with explicit error (not silent truncation)
- [ ] Add tests for each

**Validation**: Each module has tests proving it doesn't panic on corrupt data

---

## Phase 3: Error Propagation to Clients

**Goal**: Clients receive actionable error information

### 3.1 Define Error Event Protocol
- [ ] Add error event type to protocol:
  ```json
  {
    "type": "event",
    "event": "error",
    "payload": {
      "code": 3001,
      "severity": "warning",
      "title": "Track unavailable",
      "detail": "Track 5 returned corrupt data",
      "context": {"trackIndex": 5},
      "transient": true
    }
  }
  ```
- [ ] Define error code registry (1xxx=poll, 2xxx=connection, 3xxx=state, 4xxx=client, 5xxx=system)

### 3.2 Update ResponseWriter
- [ ] Add `warn()` method for non-fatal errors
- [ ] Add `sendError()` for broadcast errors (not just per-command)

### 3.3 Update main.zig Poll Loop
- [ ] When poll returns errors, aggregate and broadcast
- [ ] Implement error rate limiting (max 1 per error type per second)

### 3.4 Frontend Error Display (DECIDED)

**Decision**: Inline indicators + toasts for iPad. Reserve overlays for fatal connection loss only.

- No Sentry
- **Inline indicators**: Stale data gets visual treatment (opacity, timestamp badge)
- **Toasts**: Non-fatal errors auto-dismiss after 3-8s based on severity
- **Overlay**: Only for fatal connection loss requiring user action
- Error codes surfaced in Network Stats modal for debugging

**Validation**: WebSocket test client can receive error events

---

## Phase 4: JSON Safety

**Goal**: No JSON injection possible

### 4.1 Audit All JSON Output
- [ ] List all locations building JSON manually
- [ ] extstate.zig: Use `protocol.writeJsonString()` for values
- [ ] project_notes.zig: Same treatment
- [ ] All state modules: Verify string escaping

### 4.2 Consider std.json Migration
- [ ] Evaluate if `std.json.writeStream` is feasible
- [ ] May require allocator - assess impact
- [ ] If not feasible, ensure manual escaping is complete

**Validation**: Test with ExtState values containing `"`, `\`, newlines

---

## Phase 5: Allocation Failure Handling

**Goal**: No silent `catch {}` for allocation failures

### 5.1 Audit All Allocation Sites
- [ ] grep for `catch {}` and `catch return`
- [ ] Categorize: critical vs non-critical operations

### 5.2 Critical Path Hardening
- [ ] Command queue overflow → return error to client
- [ ] SharedState allocation failure → log and fail gracefully
- [ ] Pre-allocate emergency buffers for shutdown cleanup

### 5.3 Non-Critical Path Handling
- [ ] Log allocation failures with context
- [ ] Degrade gracefully (skip broadcast, continue)

**Validation**: Simulate OOM conditions in tests

---

## Phase 6: Thread Safety

**Goal**: Eliminate race conditions

### 6.1 Atomic for time_precise_fn
- [ ] Use `std.atomic.Value` for `time_precise_fn` pointer
- [ ] `.release` on store, `.acquire` on load

### 6.2 Shutdown Ordering (DECIDED: No hot reload)

**Decision**: Hot reload is not supported and is explicitly dangerous.

When REAPER loads a native extension via `dlopen()`, macOS **memory-maps** the `.dylib` file, loading pages on demand. If you overwrite the `.dylib` while REAPER is running:
- Pages already in memory contain **old code**
- Pages not yet loaded will come from the **new file**
- You now have a **Frankenstein binary**—part old, part new

This causes impossible-to-debug issues: crashes in code you didn't touch, log output that doesn't match source, functions returning wrong values, struct layouts silently mismatched.

**The only safe workflow is: rebuild → restart REAPER → test.**

- [ ] Create `make dev` command that automates: kill REAPER → build → install → relaunch
- [ ] Launch REAPER directly (`/Applications/REAPER.app/Contents/MacOS/REAPER`) to keep stdout attached
- [ ] Document this in DEVELOPMENT.md

**Validation**: ThreadSanitizer pass (if available) or manual audit

---

## Phase 7: Logging Infrastructure

**Goal**: Runtime-configurable logging for production debugging

**Decision**: Log to `GetResourcePath()/Logs/reamo.log` with rotation. This is the most discoverable, cross-platform approach and matches where users expect REAPER extension data to live.

### 7.1 Create Logging Module
- [ ] Create `extension/src/logging.zig`:
  - Runtime log level from `REAMO_LOG_LEVEL` env var
  - File logging to `GetResourcePath()/Logs/reamo.log`
  - Log rotation (keep last N files or max size)
  - Pre-allocated crash ring buffer (64 entries × 256 bytes)

### 7.2 Custom Panic Handler
- [ ] Override Zig panic handler
- [ ] Flush ring buffer to file before abort
- [ ] Include last N log entries for context

### 7.3 Integrate Throughout Codebase
- [ ] Replace `std.debug.print` with new logging
- [ ] Add logging at key decision points
- [ ] Log all errors with context

**Validation**: Crash produces readable log file

---

## Phase 8: Testability Infrastructure

**Goal**: Every module testable without REAPER

### 8.1 Create Mock API
- [ ] Create `extension/src/mock_api.zig`:
  - Same interface as `reaper.Api`
  - Configurable return values
  - Can inject NaN/Inf/null
  - Tracks API calls for assertions

### 8.2 Update State Modules for Testability
- [ ] `poll()` takes API interface, not concrete type
- [ ] OR: Compile-time switching between real and mock

### 8.3 Integration Test Harness
- [ ] Create test that simulates full poll cycle
- [ ] Inject corrupt data, verify no panic
- [ ] Verify error events are generated

**Validation**: `zig build test` covers all state modules with mock

---

## File-by-File Audit Checklist

Each file needs:
- [ ] All `@intFromFloat` calls use safe version
- [ ] All C API returns validated
- [ ] No silent `catch {}`
- [ ] JSON strings properly escaped
- [ ] Stack allocations reasonable (<16KB typically)
- [ ] Unit tests for error paths

### Core Files
- [ ] `main.zig` - Entry points, timer loop, shutdown
- [ ] `reaper.zig` - All API wrappers
- [ ] `ws_server.zig` - WebSocket handling, SharedState
- [ ] `protocol.zig` - JSON parsing/building

### State Modules
- [ ] `transport.zig` - Transport state polling
- [ ] `tracks.zig` - Track state + metering
- [ ] `markers.zig` - Markers and regions
- [ ] `items.zig` - Media items and takes
- [ ] `project.zig` - Project-level state
- [ ] `tempomap.zig` - Tempo markers
- [ ] `project_notes.zig` - Notes with subscriptions
- [ ] `gesture_state.zig` - Undo coalescing
- [ ] `toggle_subscriptions.zig` - Action state tracking

### Command Handlers
- [ ] `commands/mod.zig` - Dispatch and registry
- [ ] `commands/transport.zig`
- [ ] `commands/tracks.zig`
- [ ] `commands/markers.zig`
- [ ] `commands/regions.zig`
- [ ] `commands/items.zig`
- [ ] `commands/takes.zig`
- [ ] `commands/time_sel.zig`
- [ ] `commands/tempo.zig`
- [ ] `commands/timesig.zig`
- [ ] `commands/extstate.zig`
- [ ] `commands/undo.zig`
- [ ] `commands/actions.zig`
- [ ] `commands/gesture.zig`
- [ ] `commands/toggle_state.zig`
- [ ] `commands/midi.zig`
- [ ] `commands/project_notes.zig`
- [ ] `commands/repeat.zig`
- [ ] `commands/metronome.zig`
- [ ] `commands/master.zig`

---

## Testing Strategy

### Unit Tests (zig build test)
- All FFI validation functions
- All state module poll() with mock API
- JSON escaping edge cases
- Error context building
- Ring buffer operations

### Integration Tests (websocat)
- Send commands, verify responses
- Simulate clock sync
- Test error responses
- Test rate limiting

### Manual Testing
- Build extension, load in REAPER
- Exercise all features via Reamo UI
- Monitor console for errors
- Test with large projects (many tracks/items/markers)

---

## Progress Tracking

### Current Phase: 4 (JSON Safety)

### Completed

**Phase 1: Foundation** ✓
- [x] Initial stability review (EXTENSION_STABILITY_REVIEW.md)
- [x] Research on resilience patterns (EXT_STABILITY_RESEARCH.md, RESILIENT_ZIG_EXTENSION.md)
- [x] Created this plan document
- [x] Decided on hot reload (no), error UI (inline+toasts), logging location (GetResourcePath)
- [x] Create `make dev` command for rapid restart cycle (cross-platform, runs all tests)
- [x] Create `errors.zig` - error type hierarchy with ErrorCode registry
- [x] Create `ffi.zig` - FFI validation layer (safeFloatToInt, sanitizeFloat, requirePtr)
- [x] Update `reaper.zig` - getTrackSolo/getTrackRecMon return FFIError
- [x] Update `tracks.zig` - poll() catches errors with TODO for Phase 2 nullability
- [x] Update `commands/tracks.zig` - returns error response on invalid state

**Phase 2: State Module Resilience** ✓
- [x] transport.zig: Made position_beat and full_beat_position nullable (?f64)
- [x] transport.zig: poll() validates beats from REAPER using ffi.isFinite()
- [x] transport.zig: toJson() and toTickJson() output explicit null for corrupt beat data
- [x] transport.zig: Added tests for null case (corrupt beat data)
- [x] tracks.zig: Made solo and rec_mon nullable (?c_int)
- [x] tracks.zig: poll() propagates errors as null instead of fallback 0
- [x] tracks.zig: toJson() outputs explicit null for corrupt solo/rec_mon
- [x] tracks.zig: Added tests for null case (corrupt state)

**Phase 3: Error Propagation to Clients** ✓
- [x] errors.zig: Added ErrorEvent struct with toJson() for error event protocol
- [x] errors.zig: Added ErrorRateLimiter for max 1 error per type per second
- [x] errors.zig: Added comprehensive tests for ErrorEvent and ErrorRateLimiter
- [x] commands/mod.zig: Added warn() method for non-fatal warnings
- [x] commands/mod.zig: Added broadcastError() and broadcastErrorFromErr() methods
- [x] main.zig: Added errors import and g_error_limiter global
- [x] main.zig: Added broadcastRateLimitedError() helper function
- [x] main.zig: Added errors.zig and ffi.zig to test imports

### In Progress
- [ ] Phase 4.1: Audit all JSON output locations
- [ ] Phase 4.2: Ensure protocol.writeJsonString() used for all user strings
- [ ] Phase 4.3: Test with ExtState values containing special characters

### Blocked
- None

---

## Decisions Made

1. **Hot reload**: NOT supported. Memory-mapping makes it dangerous. Use `make dev` for rapid restart cycle.

2. **Error UI**: Inline indicators + toasts for iPad. Overlays only for fatal connection loss.

3. **Logging location**: `GetResourcePath()/Logs/reamo.log` with rotation.

---

## Session Handoff Notes

When starting a new Claude session, provide:
1. This document (EXTENSION_RESILIENCE_PLAN.md)
2. Current phase and task
3. Any specific files being worked on
4. Test results from previous session

The assistant should:
1. Read this plan
2. Read DEVELOPMENT.md for project conventions
3. Read the specific files for current phase
4. Continue from documented progress

---

*Last updated: 2026-01-02*
*Current phase: 4 (JSON Safety)*
