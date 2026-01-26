# Zig 0.15 REAPER Plugin Production Code Review Checklist

**A crash in your plugin means potential data loss for REAPER users.** This checklist targets the specific architecture you described: native `.dylib` running in-process, WebSocket server with threading, arena-based memory, and FFI boundaries with REAPER's C API.

---

## 1. Memory safety (Critical)

Arena-based memory with double-buffering creates pointer invalidation windows that are easy to miss. Your 2.5MB static structs and scratch arena for JSON parsing are particular risk areas.

### Zig 0.15 breaking changes to audit immediately

The ArrayList API overhaul is **the most critical migration concern**. In 0.15, `ArrayList` no longer stores its allocator internally—every method that allocates now requires passing the allocator explicitly.

```zig
// BEFORE (0.14) - BROKEN IN 0.15
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.append('x');

// AFTER (0.15) - REQUIRED PATTERN
var list: std.ArrayList(u8) = .{};
defer list.deinit(allocator);
try list.append(allocator, 'x');
try list.appendSlice(allocator, "hello");
const slice = list.toOwnedSlice(allocator);
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | All ArrayList calls pass allocator explicitly | Silent compilation failure or wrong allocator used |
| **Critical** | No pointers held across arena swap/reset | Use-after-free when double-buffer swaps |
| **Critical** | Timer callback (~30ms) allocations use scratch arena only | Stack overflow or memory leak in host process |
| **High** | Large stack allocations moved to static storage or heap | Stack overflow in REAPER's timer callback stack |
| **High** | Arena lifetime outlives all pointers obtained from it | Dangling pointers after `arena.reset()` |
| **Medium** | `arena.reset(.{ .retain_with_limit = N })` used instead of `.free_all` | Performance: avoid repeated mmap calls |

### Double-buffer swap timing audit

Your double-buffer pattern is dangerous at the swap boundary:

```zig
// DANGEROUS: Pointer obtained before swap, used after
const data = arena_a.allocator().alloc(u8, 100);
swapArenas();  // arena_a becomes arena_b, arena_b gets reset
processData(data);  // USE-AFTER-FREE if data was from the reset arena

// SAFE: Ensure data processing completes before swap
const data = current_arena.allocator().alloc(u8, 100);
processData(data);  // Complete before any swap
// ...swap only happens after all current-frame work done
```

### Grep patterns for memory issues

```bash
# ArrayList missing allocator (0.15 migration)
grep -rn "\.append(" --include="*.zig" | grep -v "allocator"
grep -rn "\.deinit()" --include="*.zig" | grep -v "allocator"
grep -rn "\.toOwnedSlice()" --include="*.zig" | grep -v "allocator"

# Potential pointer invalidation across arena operations
grep -rn "arena.*reset\|arena.*deinit" --include="*.zig" -B5 -A5

# Large stack allocations (risk in 30ms callback)
grep -rn "\[[0-9]\{4,\}\]" --include="*.zig"  # Arrays >1000 elements
grep -rn "var.*:.*\[.*\].*= undefined" --include="*.zig"

# HashMap pointer invalidation risk
grep -rn "\.getPtr(" --include="*.zig"
```

### Questions to ask during review

- When exactly do arena swaps occur relative to pointer usage?
- Can the WebSocket thread hold a pointer while the main thread swaps arenas?
- What happens if JSON parsing exhausts the scratch arena mid-parse?
- Are all static storage structs (`~2.5MB`) properly aligned for SIMD if needed?

---

## 2. FFI correctness (Critical)

Your raw.zig bindings and RealBackend validation layer are the firewall between Zig safety and REAPER's C API. Every gap here is a potential crash.

### REAPER API patterns that return garbage

REAPER's `GetSetMediaTrackInfo_Value` and similar functions have specific failure modes:

```zig
// DANGEROUS: REAPER may return invalid pointer
const track = GetTrack(project, track_idx);
track.*.some_field;  // CRASH if track is null or invalid

// SAFE: Always validate REAPER pointers
const track = GetTrack(project, track_idx);
if (@intFromPtr(track) == 0) return null;
if (!ValidatePtr(@ptrCast(track), "MediaTrack*")) return null;
// Now safe to use
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | All `extern struct` layouts verified with `@offsetOf`/`@sizeOf` against C headers | Silent memory corruption |
| **Critical** | `ValidatePtr` called before using any REAPER object pointer | Crash on deleted track/item |
| **Critical** | C string returns converted with `std.mem.span()` immediately | Read past buffer if not null-terminated |
| **Critical** | AudioAccessor created/destroyed on main thread only | Race condition crash |
| **High** | All callback functions have `callconv(.C)` | ABI mismatch crash |
| **High** | No Zig slices passed directly to C (use `.ptr` after null-termination) | Missing null terminator |
| **High** | C error codes mapped to Zig errors at FFI boundary | Silent failure propagation |
| **Medium** | Use `c_int`, `c_long`, etc. instead of Zig integer types for FFI | Platform-specific size mismatch |

### Critical REAPER resources requiring cleanup

```zig
// AudioAccessor MUST be destroyed - leak = eventual crash
const accessor = CreateTakeAudioAccessor(take);  // Main thread only!
defer DestroyAudioAccessor(accessor);            // Main thread only!

// Check for stale state before using
if (AudioAccessorStateChanged(accessor)) {
    AudioAccessorUpdate(accessor);
}
```

### Validation patterns possibly missing

Your `safeFloatToInt` handles NaN/Inf, but verify these additional cases:

```zig
pub fn safeFloatToInt(comptime T: type, f: f64) ?T {
    // Your existing checks
    if (std.math.isNan(f) or std.math.isInf(f)) return null;
    
    // ALSO CHECK: Value fits in target type
    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));
    if (f < min_val or f > max_val) return null;
    
    return @intFromFloat(f);
}
```

### Grep patterns for FFI issues

```bash
# Missing callconv on FFI functions
grep -rn "fn.*\*const fn" --include="*.zig" | grep -v "callconv"
grep -rn "export fn" --include="*.zig" | grep -v "callconv"

# Direct [*c] usage (should be converted to Zig types immediately)
grep -rn "\[\*c\]" --include="*.zig" | grep -v "@cImport"

# @ptrCast without @alignCast (alignment issue)
grep -rn "@ptrCast" --include="*.zig" | grep -v "@alignCast"

# Potential null pointer dereference from C
grep -rn "extern fn.*\*" --include="*.zig" | grep -v "?\*"

# Missing ValidatePtr before REAPER object use
grep -rn "GetTrack\|GetMediaItem\|GetTake" --include="*.zig"
```

### Questions to ask during review

- Does every REAPER object pointer get `ValidatePtr` checked before dereference?
- Are there any code paths where AudioAccessor outlives its parent take/track?
- Do all extern struct definitions match REAPER's actual memory layout?
- What happens when REAPER returns `IP_TRACKNUMBER = -1` (master track)?

---

## 3. Thread safety (Critical)

Your architecture has two threads: main thread for REAPER API via timer callback, WebSocket thread for commands. The mutex-protected queue is the critical synchronization point.

### Memory ordering in Zig

Zig uses LLVM's atomic orderings. For your producer-consumer queue:

```zig
// WebSocket thread (producer) - use release to publish
queue.mutex.lock();
defer queue.mutex.unlock();
@atomicStore(bool, &has_data, true, .release);

// Main thread (consumer) - use acquire to observe
if (@atomicLoad(bool, &has_data, .acquire)) {
    queue.mutex.lock();
    defer queue.mutex.unlock();
    // Process commands
}
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | Mutex always unlocked with `defer mutex.unlock()` | Deadlock on error path |
| **Critical** | No REAPER API calls from WebSocket thread | REAPER is not thread-safe |
| **Critical** | Data copied from queue before mutex unlock, not just pointer taken | Use-after-free |
| **High** | Reference count incremented while holding lock (if using refcounting) | Race condition |
| **High** | Atomics use `.seq_cst` unless performance-critical path with proven ordering | Subtle ordering bugs |
| **Medium** | Lock held for minimum duration | UI responsiveness |

### Thread-safe queue pattern audit

```zig
// DANGEROUS: Pointer escapes mutex scope
fn dequeueCommand(self: *Queue) ?*Command {
    self.mutex.lock();
    defer self.mutex.unlock();
    const cmd = self.head orelse return null;
    self.head = cmd.next;
    return cmd;  // DANGER: cmd may be from arena that gets reset
}

// SAFE: Copy data while holding lock
fn dequeueCommand(self: *Queue, dest: *Command) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const cmd = self.head orelse return false;
    self.head = cmd.next;
    dest.* = cmd.*;  // Copy data, not pointer
    return true;
}
```

### Grep patterns for thread safety issues

```bash
# Missing defer unlock (potential deadlock)
grep -rn "\.lock()" --include="*.zig" -A1 | grep -v "defer.*unlock"

# Potential data race (shared state without atomic/mutex)
grep -rn "var.*:.*= " --include="*.zig" | grep -v "const\|mutex\|atomic"

# Functions that might be called from wrong thread
grep -rn "pub fn" --include="*.zig" | xargs -I {} grep -l "REAPER\|reaper"
```

### Questions to ask during review

- Can any code path hold the queue mutex while calling REAPER API? (deadlock risk)
- If WebSocket thread enqueues while main thread processes, is the queue properly protected?
- Are there any "check-then-act" patterns without holding the lock?
- What memory ordering is used for the queue's empty/full signals?

---

## 4. Error handling (High)

Silent `catch return` is the enemy of debuggability. In a plugin that runs for hours, you need to know why things fail.

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | No `catch unreachable` in production code paths | UB in ReleaseFast builds |
| **High** | Every `catch return` logs the error first | Silent failures impossible to debug |
| **High** | `errdefer` used for cleanup that must happen on error path | Resource leaks on error |
| **Medium** | Error unions used for recoverable failures, `@panic` only for unrecoverable | Crashes vs graceful degradation |
| **Medium** | Error context logged before propagation | Stack trace alone insufficient |

### Anti-patterns to eliminate

```zig
// ANTI-PATTERN: Silent error swallowing
fn processTrack(track: *Track) void {
    getTrackData(track) catch return;  // WHY did it fail?
}

// ANTI-PATTERN: unreachable in production (UB in release!)
const data = allocateBuffer() catch unreachable;

// GOOD: Log then return
fn processTrack(track: *Track) void {
    getTrackData(track) catch |err| {
        std.log.warn("Track processing failed: {}", .{err});
        return;
    };
}

// GOOD: Panic with message if truly unrecoverable
const data = allocateBuffer() catch @panic("Critical buffer allocation failed");
```

### Graceful degradation verification

Your pattern of "skip entities when arena full, never crash" is correct. Verify:

```zig
// CORRECT PATTERN for your architecture
fn enumerateTracks(arena: *Arena, project: *Project) []Track {
    var tracks: std.ArrayList(Track) = .{};
    
    for (0..CountTracks(project)) |i| {
        const track = getTrackInfo(arena, i) catch |err| {
            std.log.warn("Skipping track {}: {}", .{i, err});
            continue;  // Skip, don't crash
        };
        tracks.append(arena.allocator(), track) catch {
            std.log.warn("Arena full at track {}, returning partial", .{i});
            break;  // Return what we have
        };
    }
    return tracks.items;
}
```

### Grep patterns for error handling issues

```bash
# Silent catch (must log or handle explicitly)
grep -rn "catch return;" --include="*.zig"
grep -rn "catch {}" --include="*.zig"
grep -rn "catch |_| {}" --include="*.zig"

# Dangerous unreachable (UB in release)
grep -rn "catch unreachable" --include="*.zig"
grep -rn "orelse unreachable" --include="*.zig"

# Missing try (ignored error)
grep -rn "= [a-z_]*(" --include="*.zig" | grep -v "try\|catch\|const\|var"
```

### Questions to ask during review

- For each `catch return`, is the caller aware the operation didn't complete?
- Does logging work in the release build? Is it rate-limited?
- What state is the plugin in after graceful degradation?
- Can the user tell when track enumeration was truncated?

---

## 5. Resource leaks (High)

In hour-long REAPER sessions, small leaks compound. Your arena-based approach helps, but REAPER resources and file descriptors need explicit management.

### REAPER API resources requiring cleanup

| Resource | Create | Destroy | Thread |
|----------|--------|---------|--------|
| AudioAccessor | `CreateTakeAudioAccessor` | `DestroyAudioAccessor` | Main only |
| MIDI Event | Manual creation | Manual free | Any |
| preview_register_t | Manual init | Deinit critical section | Any |
| Timer registration | `plugin_register("timer", fn)` | `plugin_register("-timer", fn)` | Main |
| Custom action | `plugin_register("custom_action", ...)` | Prefix with "-" | Main |

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | Every AudioAccessor has matching DestroyAudioAccessor | Memory leak, eventual crash |
| **Critical** | All plugin_register calls have matching "-" unregistration | Crash on unload |
| **High** | WebSocket connections tracked and cleaned on shutdown | Socket/FD leak |
| **High** | Arena reset called at appropriate intervals | Unbounded memory growth |
| **Medium** | JSON parsing uses scratch arena that resets per-message | Memory accumulation |

### WebSocket connection cleanup

```zig
// websocket.zig guarantees close() called exactly once
const Handler = struct {
    conn: *ws.Conn,
    resources: ?*AllocatedResources = null,
    
    pub fn close(self: *Handler) void {
        // Guaranteed to be called - cleanup here
        if (self.resources) |res| {
            res.deinit();
        }
        // Handler itself managed by websocket.zig
    }
};
```

### Leak detection for Zig

```zig
// Development: Use GeneralPurposeAllocator for leak detection
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
defer {
    const check = gpa.deinit();
    if (check == .leak) {
        std.log.err("Memory leak detected!", .{});
    }
}

// In tests: std.testing.allocator auto-detects leaks
test "no leaks" {
    const allocator = std.testing.allocator;
    const buffer = try allocator.alloc(u8, 100);
    defer allocator.free(buffer);  // Missing this = test failure
}
```

### Grep patterns for resource leaks

```bash
# AudioAccessor without destroy
grep -rn "CreateTakeAudioAccessor\|CreateTrackAudioAccessor" --include="*.zig"
grep -rn "DestroyAudioAccessor" --include="*.zig"
# Count should match

# Allocations without defer free
grep -rn "try.*\.alloc\|try.*\.create" --include="*.zig" -A2 | grep -v "defer.*free\|defer.*destroy"

# File opens without close
grep -rn "openFile\|createFile" --include="*.zig" -A2 | grep -v "defer.*close"

# plugin_register without unregister tracking
grep -rn 'plugin_register.*"[^-]' --include="*.zig"
```

### Questions to ask during review

- How long do AudioAccessors live? Are they created per-request or cached?
- What's the maximum number of concurrent WebSocket connections?
- When does the scratch arena reset? Before or after JSON response is sent?
- Is there a connection cleanup timeout for abandoned WebSocket clients?

---

## 6. Numeric safety (High)

Your `safeFloatToInt` and NaN/Inf checks are good. These patterns catch the remaining edge cases for long sessions and beat/time calculations.

### Beat.ticks precision issues

```zig
// PROBLEM: Accumulated float error in tick calculations
var position: f64 = 0;
for (0..many_ticks) |_| {
    position += tick_duration;  // Error compounds!
}

// SOLUTION: Integer ticks, convert at boundaries
var tick_count: u64 = 0;
tick_count += num_ticks;
const position = @as(f64, @floatFromInt(tick_count)) * tick_duration;
```

### Sample position overflow protection

At **48kHz**, `i32` overflows after **~12.4 hours**. Use `i64` for sample positions:

```zig
const SamplePosition = i64;  // Safe for any practical session

fn samplesToSeconds(samples: SamplePosition, sample_rate: u32) f64 {
    return @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(sample_rate));
}
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | Division operations check for zero divisor | Panic or UB |
| **Critical** | `@intFromFloat` validates NaN, Inf, and range | Panic in release |
| **High** | Sample positions use `i64`, not `i32` | Overflow after 12 hours |
| **High** | Time calculations use `f64` internally, convert to `f32` only for output | Precision loss |
| **High** | BPM and sample rate clamped to minimum values before division | Div by zero |
| **Medium** | Denormal protection for any filter/decay code | CPU performance |
| **Medium** | Saturating operators (`+|`, `*|`) for audio sample math | Clipping vs crash |

### Safe numeric conversion library

```zig
pub const SafeMath = struct {
    pub fn safeDiv(comptime T: type, a: T, b: T) ?T {
        if (b == 0) return null;
        return @divTrunc(a, b);
    }
    
    pub fn saturatingIntFromFloat(comptime T: type, f: anytype) T {
        if (std.math.isNan(f)) return 0;
        const max: @TypeOf(f) = @floatFromInt(std.math.maxInt(T));
        const min: @TypeOf(f) = @floatFromInt(std.math.minInt(T));
        if (f >= max) return std.math.maxInt(T);
        if (f <= min) return std.math.minInt(T);
        return @intFromFloat(f);
    }
    
    pub fn clampedBpm(bpm: f64) f64 {
        return @max(bpm, 1.0);  // Prevent division by near-zero
    }
};
```

### Grep patterns for numeric issues

```bash
# Division without zero check
grep -rn "/ " --include="*.zig" | grep -v "if.*== 0\|@max"
grep -rn "@divTrunc\|@divFloor\|@divExact" --include="*.zig"

# Unsafe float-to-int
grep -rn "@intFromFloat" --include="*.zig"

# Sample positions that might overflow (i32/u32)
grep -rn "sample.*: [iu]32\|position.*: [iu]32\|offset.*: [iu]32" --include="*.zig"

# Float equality comparison
grep -rn "== .*f64\|== .*f32\|f64.*==\|f32.*==" --include="*.zig"
```

### Questions to ask during review

- What's the maximum session length you've tested?
- Are beat.ticks stored as integers or accumulated floats?
- What happens when BPM is set to 0 or very small values?
- Is sample rate validated at initialization?

---

## 7. WebSocket security (High)

Localhost-only (ports 9224-9233) with session token auth is good, but DNS rebinding and connection exhaustion need explicit protection.

### DNS rebinding protection (Critical)

A malicious website can resolve to `127.0.0.1` and access your WebSocket:

```zig
pub fn init(h: *ws.Handshake, conn: *ws.Conn, app: *App) !Handler {
    // 1. REQUIRED: Validate Host header
    const host = h.headers.get("host") orelse return error.NoHost;
    if (!isValidLocalhost(host)) return error.InvalidHost;
    
    // 2. Validate Origin (if present)
    if (h.headers.get("origin")) |origin| {
        if (!isAllowedOrigin(origin)) return error.InvalidOrigin;
    }
    
    // 3. Require session token
    const auth = h.headers.get("authorization") orelse return error.NoAuth;
    const session = app.validateSession(auth) orelse return error.InvalidSession;
    
    return .{ .conn = conn, .session = session };
}

fn isValidLocalhost(host: []const u8) bool {
    return std.mem.startsWith(u8, host, "127.0.0.1:") or
           std.mem.startsWith(u8, host, "localhost:");
}
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | Host header validated against localhost allowlist | DNS rebinding attack |
| **Critical** | Session token required and validated | Unauthorized access |
| **High** | `max_message_size` configured (default 64KB) | Memory exhaustion |
| **High** | Per-IP connection limits enforced | Connection exhaustion |
| **High** | JSON parsing uses bounded allocator | DoS via deeply nested JSON |
| **Medium** | Rate limiting per connection | Command flooding |
| **Medium** | Handshake timeout configured (3 seconds) | Slowloris attack |

### JSON parsing with bounded allocator

```zig
pub fn clientMessage(self: *Handler, allocator: std.mem.Allocator, data: []const u8) !void {
    // Size check first
    if (data.len > 64 * 1024) return error.PayloadTooLarge;
    
    // Use bounded allocator to limit memory
    var buf: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    
    const parsed = std.json.parseFromSlice(
        Command, fba.allocator(), data, .{
            .ignore_unknown_fields = false,  // Reject unexpected fields
            .duplicate_field_behavior = .@"error",  // Reject duplicates
        }
    ) catch return error.InvalidJson;
    defer parsed.deinit();
    
    // Authorize action
    if (!self.session.canPerform(parsed.value.action)) {
        try self.conn.write("{\"error\":\"unauthorized\"}");
        return;
    }
    
    try self.processCommand(parsed.value);
}
```

### Grep patterns for WebSocket security issues

```bash
# Missing Host header validation
grep -rn "Handshake" --include="*.zig" -A20 | grep -v "host"

# Missing authentication check
grep -rn "pub fn init.*Handshake" --include="*.zig" -A20 | grep -v "auth\|token\|session"

# Unbounded JSON parsing
grep -rn "parseFromSlice\|parseFromValue" --include="*.zig" | grep -v "FixedBufferAllocator"

# Hard-coded ports (verify they're localhost-bound)
grep -rn "922[0-9]" --include="*.zig"
```

### Questions to ask during review

- Is the session token stored in REAPER EXTSTATE or passed each connection?
- What happens when max connections is reached?
- Is there a mechanism to revoke sessions?
- How does the frontend obtain the session token securely?

---

## 8. Comptime correctness (Medium)

Your `inline for` dispatch pattern is elegant but carries binary size and compilation time costs.

### Inline for dispatch audit

```zig
// PATTERN: Type dispatch via inline for
inline for (@typeInfo(CommandUnion).@"union".fields) |field| {
    if (std.mem.eql(u8, command_name, field.name)) {
        return @field(cmd, field.name);
    }
}

// RISK: Generates separate code for EACH field
// With 50 commands = 50x code paths
// Consider: Is runtime dispatch acceptable for your 30Hz rate?
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **High** | `inline for` limited to small iteration counts | Binary bloat |
| **High** | `anytype` parameters have comptime trait validation | Cryptic error messages |
| **Medium** | `comptime` keyword used when branch elimination expected | Both branches compiled |
| **Medium** | Cross-compilation tested (comptime uses target, not host) | Platform-specific bugs |
| **Low** | Recursive comptime functions have depth limits | Compilation timeout |

### anytype safety pattern

```zig
// BEFORE: Hidden interface requirements
fn process(writer: anytype) !void {
    try writer.write("data");  // What if writer doesn't have write?
}

// AFTER: Explicit contract
fn process(writer: anytype) !void {
    comptime {
        if (!@hasDecl(@TypeOf(writer), "write")) {
            @compileError("writer must have write() method");
        }
    }
    try writer.write("data");
}
```

### Grep patterns for comptime issues

```bash
# Large inline for (potential bloat)
grep -rn "inline for" --include="*.zig" -B2 -A5

# anytype without validation
grep -rn "anytype" --include="*.zig" | grep -v "comptime.*@TypeOf\|@hasDecl"

# Missing comptime for branch elimination
grep -rn "if.*builtin\|if.*@import.*builtin" --include="*.zig" | grep -v "comptime if"
```

### Questions to ask during review

- How many types does the largest `inline for` iterate over?
- What's the release binary size? Is it growing unexpectedly?
- Are there any `anytype` functions that should have concrete types?

---

## 9. Testing completeness (Medium)

Your MockBackend pattern enables testing without REAPER, but needs specific edge case coverage.

### MockBackend simulation requirements

```zig
pub const MockBackend = struct {
    // State simulation
    tracks: []MockTrack,
    project_state: ProjectState,
    
    // Failure injection
    fail_after_n_calls: ?usize = null,
    inject_nan_returns: bool = false,
    inject_null_pointers: bool = false,
    
    // Behavior simulation
    pub fn GetTrack(self: *MockBackend, idx: usize) ?*MockTrack {
        if (self.inject_null_pointers) return null;
        if (idx >= self.tracks.len) return null;
        return &self.tracks[idx];
    }
    
    // Thread timing simulation
    pub fn simulateSlowResponse(self: *MockBackend) void {
        std.time.sleep(50 * std.time.ns_per_ms);  // Slower than 30ms timer
    }
};
```

### Edge cases to test for DAW plugins

| Category | Test Case |
|----------|-----------|
| **Scale** | 3000 tracks, 10000 items, 30Hz for 1 hour |
| **Timing** | WebSocket command arrives during timer callback |
| **Memory** | Arena exhaustion mid-enumeration |
| **REAPER state** | Track deleted while enumerating |
| **Numeric** | BPM = 0, sample_rate = 0, NaN from API |
| **Network** | 100 concurrent WebSocket connections |
| **Recovery** | Command queue full, arena swap during processing |

### Testing threaded code pattern

```zig
test "queue thread safety" {
    const allocator = std.testing.allocator;
    var queue = CommandQueue.init(allocator);
    defer queue.deinit();
    
    // Producer thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(q: *CommandQueue) void {
            for (0..1000) |i| {
                q.enqueue(.{ .id = i });
            }
        }
    }.run, .{&queue});
    
    // Consumer thread
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(q: *CommandQueue) void {
            var count: usize = 0;
            while (count < 1000) {
                if (q.dequeue()) |_| count += 1;
            }
        }
    }.run, .{&queue});
    
    producer.join();
    consumer.join();
}
```

### Allocation failure testing

```zig
test "handles allocation failures gracefully" {
    // Test that every allocation failure path is handled
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        processCommand,
        .{ test_command, .{} },
    );
}
```

### Questions to ask during review

- Does MockBackend simulate all REAPER API failure modes?
- Are there integration tests that run for hours?
- What's the test coverage for error paths?
- Are thread safety tests run with ThreadSanitizer?

---

## 10. Zig 0.15 migration specifics (High)

Beyond ArrayList, these breaking changes affect your codebase:

### I/O API overhaul ("Writergate")

If you use any std.io for logging or file I/O:

```zig
// BEFORE (0.14)
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello\n", .{});

// AFTER (0.15) - Buffer required, must flush
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
try stdout_writer.interface.print("Hello\n", .{});
try stdout_writer.interface.flush();  // CRITICAL: Must flush!
```

### Format string changes

```zig
// BEFORE (0.14)
std.debug.print("{}", .{my_formatter});

// AFTER (0.15) - Custom formatters require {f}
std.debug.print("{f}", .{my_formatter});
```

### Full migration checklist

| Change | Search Pattern | Action |
|--------|---------------|--------|
| ArrayList allocator | `\.append(\|\.deinit(\|\.toOwnedSlice(` | Add allocator parameter |
| Writer API | `std.io.*writer\|getStdOut()` | Add buffer, flush calls |
| Format specifiers | Custom `format()` methods | Use `{f}` specifier |
| BoundedArray | `BoundedArray` | Migrate to ArrayList |
| `usingnamespace` | `usingnamespace` | Remove, use direct declarations |
| async/await | `async\|await` | Remove (now in std library) |

### Run `zig fmt` for automatic migrations

```bash
# Auto-upgrade inline assembly clobbers
zig fmt src/
```

---

## Automated CI checks

### GitHub Actions workflow

```yaml
name: Plugin Safety Checks

on: [push, pull_request]

jobs:
  safety:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install Zig 0.15
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.0
      
      - name: Build (Debug with safety checks)
        run: zig build -Doptimize=Debug
      
      - name: Run tests with leak detection
        run: zig build test
      
      - name: Run tests with allocation failure injection
        run: zig build test -Dfail-allocations
      
      - name: Static analysis - silent catch
        run: |
          if grep -rn "catch return;" --include="*.zig" src/; then
            echo "ERROR: Silent catch return found"
            exit 1
          fi
      
      - name: Static analysis - catch unreachable
        run: |
          if grep -rn "catch unreachable" --include="*.zig" src/; then
            echo "ERROR: catch unreachable in production code"
            exit 1
          fi
      
      - name: Static analysis - missing ValidatePtr
        run: |
          # Custom script to verify REAPER pointer validation
          ./scripts/check_reaper_pointers.sh
```

### Pre-commit hooks

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Check for anti-patterns
if grep -rn "catch return;\|catch {}\|catch unreachable" --include="*.zig" src/; then
    echo "Commit blocked: Error handling anti-pattern detected"
    exit 1
fi

# Run quick tests
zig build test || exit 1

echo "Pre-commit checks passed"
```

### Continuous testing script

```bash
#!/bin/bash
# scripts/long_running_test.sh

# Run for 2 hours, checking memory periodically
timeout 7200 zig build run-stress-test &
PID=$!

while kill -0 $PID 2>/dev/null; do
    # Check memory growth
    RSS=$(ps -o rss= -p $PID)
    if [ "$RSS" -gt 1000000 ]; then  # 1GB limit
        echo "FAIL: Memory exceeded limit"
        kill $PID
        exit 1
    fi
    sleep 60
done

wait $PID
echo "Long-running test passed"
```

---

## Quick reference card

### Severity definitions

- **Critical**: Can crash REAPER or corrupt user data
- **High**: Can cause silent failures or security issues
- **Medium**: Performance, maintainability, or edge case issues
- **Low**: Code quality and best practices

### Top 10 grep commands for quick audit

```bash
# 1. Silent error handling
grep -rn "catch return;\|catch {}" --include="*.zig"

# 2. Dangerous unreachable
grep -rn "catch unreachable\|orelse unreachable" --include="*.zig"

# 3. ArrayList 0.15 migration
grep -rn "\.append(\|\.deinit()" --include="*.zig" | grep -v "allocator"

# 4. FFI alignment issues
grep -rn "@ptrCast" --include="*.zig" | grep -v "@alignCast"

# 5. Missing mutex unlock
grep -rn "\.lock()" --include="*.zig" -A1 | grep -v "defer.*unlock"

# 6. Division without zero check
grep -rn "@divTrunc\|@divFloor\|@divExact" --include="*.zig"

# 7. Float-to-int without validation
grep -rn "@intFromFloat" --include="*.zig"

# 8. Sample position overflow risk
grep -rn "sample.*: [iu]32\|position.*: [iu]32" --include="*.zig"

# 9. WebSocket auth
grep -rn "Handshake" --include="*.zig" -A20 | grep -v "host\|auth"

# 10. REAPER pointer usage
grep -rn "GetTrack\|GetMediaItem" --include="*.zig" | grep -v "ValidatePtr"
```

This checklist targets the specific risks of your architecture: in-process plugin crashes, arena pointer invalidation, REAPER API validation, WebSocket security, and Zig 0.15 migration. Adapt severity levels based on your actual usage patterns—if you don't use AudioAccessor, deprioritize that section; if sessions regularly exceed 12 hours, elevate sample position overflow to Critical.
