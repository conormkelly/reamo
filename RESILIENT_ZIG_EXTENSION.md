# Resilient error handling architecture for Reamo

A Zig native extension polling REAPER at 30Hz demands a fundamentally different error handling philosophy than typical applications. **Every error pathway must assume allocation has failed, the main thread cannot block, and crashes destroy user work.** This architecture treats the REAPER C API as an untrusted boundary, propagates errors with sufficient context for remote debugging, and ensures clients never receive fabricated data—only truthful information about what's known and what's uncertain.

## The trust boundary: validating C API returns immediately

The first line of defense sits at the FFI boundary where REAPER's C functions return values. REAPER's API can return NaN/Inf floats, null pointers for deleted tracks, and out-of-range integers without warning. Zig's `@intFromFloat` panics on NaN/Inf, and `@intCast` panics on overflow—making unvalidated FFI returns crash vectors.

**Every C API call should pass through a validation wrapper:**

```zig
pub const ReaperApiError = error{
    NullPointer,
    FloatIsNaN,
    FloatIsInf,
    IntegerOverflow,
    InvalidHandle,
    TrackDeleted,
    ApiCallFailed,
};

pub const ffi = struct {
    /// Safe float-to-int conversion that returns error on NaN/Inf/out-of-range
    pub fn safeFloatToInt(comptime T: type, value: f64) ReaperApiError!T {
        if (std.math.isNan(value)) return error.FloatIsNaN;
        if (std.math.isInf(value)) return error.FloatIsInf;
        
        const min_val: f64 = @floatFromInt(std.math.minInt(T));
        const max_val: f64 = @floatFromInt(std.math.maxInt(T));
        if (value < min_val or value > max_val) return error.IntegerOverflow;
        
        return @intFromFloat(value);
    }
    
    /// Validate float before use (for floats staying as floats)
    pub fn sanitizeFloat(value: f64) ReaperApiError!f64 {
        if (std.math.isNan(value)) return error.FloatIsNaN;
        if (std.math.isInf(value)) return error.FloatIsInf;
        return value;
    }
    
    /// Convert nullable C pointer to Zig error
    pub fn requirePtr(comptime T: type, ptr: ?*T) ReaperApiError!*T {
        return ptr orelse error.NullPointer;
    }
    
    /// Wrap MediaTrack pointer with deleted-track detection
    pub fn validateTrack(track: ?*c.MediaTrack) ReaperApiError!*c.MediaTrack {
        const t = track orelse return error.NullPointer;
        // REAPER returns specific sentinel for deleted tracks
        if (c.ValidatePtr(t, "MediaTrack*") == 0) return error.TrackDeleted;
        return t;
    }
};
```

Place validation at **both** the C API wrapper level and the poll layer (defense in depth). The wrapper catches invalid returns immediately; the poll layer catches invalid combinations or state that individual calls couldn't detect.

## Building error context without allocation

Zig errors are just enum values—they carry no payload. For debugging from error reports alone, you need context: which API failed, what parameters were passed, what value was returned. The solution uses **stack-based error context** that never touches the heap:

```zig
pub const ErrorContext = struct {
    const MAX_MSG_LEN = 256;
    
    code: anyerror,
    message: [MAX_MSG_LEN]u8 = undefined,
    message_len: u8 = 0,
    api_name: [32]u8 = undefined,
    api_name_len: u8 = 0,
    source: std.builtin.SourceLocation,
    timestamp_ms: i64,
    
    pub fn init(src: std.builtin.SourceLocation) ErrorContext {
        return .{ 
            .code = error.Unknown,
            .source = src,
            .timestamp_ms = std.time.milliTimestamp(),
        };
    }
    
    pub fn setApi(self: *ErrorContext, name: []const u8) void {
        const len = @min(name.len, 32);
        @memcpy(self.api_name[0..len], name[0..len]);
        self.api_name_len = @intCast(len);
    }
    
    pub fn format(self: *ErrorContext, comptime fmt: []const u8, args: anytype) void {
        var fbs = std.io.fixedBufferStream(&self.message);
        fbs.writer().print(fmt, args) catch {};
        self.message_len = @intCast(fbs.pos);
    }
    
    pub fn getMessage(self: *const ErrorContext) []const u8 {
        return self.message[0..self.message_len];
    }
};
```

Use `errdefer` with error capture to log context when errors propagate:

```zig
pub fn getTrackVolume(track_idx: i32) ReaperApiError!f64 {
    var ctx = ErrorContext.init(@src());
    ctx.setApi("GetTrackInfo_Value");
    
    errdefer |err| {
        ctx.code = err;
        crash_log.writeContext(&ctx);
    }
    
    const track = try ffi.validateTrack(c.GetTrack(null, track_idx));
    const volume = c.GetMediaTrackInfo_Value(track, "D_VOL");
    
    if (std.math.isNan(volume)) {
        ctx.format("track={d} returned NaN for D_VOL", .{track_idx});
        return error.FloatIsNaN;
    }
    
    return try ffi.sanitizeFloat(volume);
}
```

## Error type hierarchy for composability

Design error sets per module boundary, compose them at API boundaries:

```zig
// Low-level FFI errors
pub const FFIError = error{ NullPointer, FloatIsNaN, FloatIsInf, IntegerOverflow };

// REAPER-specific state errors  
pub const ReaperStateError = error{ TrackDeleted, ItemDeleted, InvalidProject, NoActiveProject };

// Resource errors
pub const ResourceError = error{ OutOfMemory, BufferFull, QueueOverflow };

// Composed at public API boundary
pub const ReamoError = FFIError || ReaperStateError || ResourceError || error{
    PollTimeout,
    SerializationFailed,
    WebSocketError,
};
```

Zig allows `@errorCast` to upcast specific errors to composed sets, enabling functions to return domain-specific errors that compose cleanly.

## Recovery strategy: partial data with error flags

When the poll loop encounters invalid data from one track while others succeed, **skip the invalid item but continue the cycle**. Clients receive partial data with explicit error markers—never fake values:

```zig
pub const TrackState = struct {
    volume: ?f64,      // null = unavailable
    pan: ?f64,
    mute: ?bool,
    error_code: ?u16,  // non-null if this track had errors
};

pub const PollResult = struct {
    frame_id: u64,
    timestamp_ms: i64,
    transport: TransportState,
    tracks: []TrackState,
    errors: []ErrorEvent,      // aggregated errors this cycle
    staleness: StalenessInfo,
    
    pub const StalenessInfo = struct {
        stale: bool,
        age_ms: u32,
        last_successful_poll_ms: i64,
    };
};
```

The client receives explicit nulls for unavailable data, never interpolated or default values. Error codes travel alongside data so the UI can decide how to render each track.

## Circuit breaker prevents cascading failure

Implement a state machine for system health that prevents one component's failure from bringing down polling entirely:

```
HEALTHY ──(3 consecutive failures)──▶ DEGRADED
    ▲                                      │
    │                                      │
(5 successes)                    (5 more failures)
    │                                      │
    │                                      ▼
RECOVERING ◀──(probe succeeds)──── ERROR
```

**Circuit breaker configuration for 30Hz:**

```zig
pub const CircuitBreaker = struct {
    state: enum { closed, open, half_open } = .closed,
    failure_count: u8 = 0,
    success_count: u8 = 0,
    last_failure_ms: i64 = 0,
    
    const FAILURE_THRESHOLD = 5;
    const RESET_TIMEOUT_MS = 2000;  // 60 cycles
    const SUCCESS_THRESHOLD = 3;
    
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.failure_count = 0;
        if (self.state == .half_open) {
            self.success_count += 1;
            if (self.success_count >= SUCCESS_THRESHOLD) {
                self.state = .closed;
            }
        }
    }
    
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.success_count = 0;
        self.failure_count +|= 1;
        self.last_failure_ms = std.time.milliTimestamp();
        
        if (self.failure_count >= FAILURE_THRESHOLD) {
            self.state = .open;
        }
    }
    
    pub fn shouldAttempt(self: *CircuitBreaker) bool {
        return switch (self.state) {
            .closed => true,
            .open => blk: {
                const elapsed = std.time.milliTimestamp() - self.last_failure_ms;
                if (elapsed > RESET_TIMEOUT_MS) {
                    self.state = .half_open;
                    break :blk true;
                }
                break :blk false;
            },
            .half_open => true,
        };
    }
};
```

**Apply bulkhead isolation** so transport polling, track polling, and meter polling have independent circuit breakers. Transport state (play/stop/position) is critical; meter data is nice-to-have. If meters fail, transport keeps flowing.

## Error event protocol for WebSocket clients

Structure error events using RFC 9457 conventions extended for real-time systems:

```json
{
  "type": "reamo://errors/track-unavailable",
  "code": 3001,
  "severity": "warning",
  "title": "Track unavailable",
  "detail": "Track 5 returned null pointer, possibly deleted",
  "operation": "poll.tracks",
  "context": {
    "trackIndex": 5,
    "lastValidValue": { "volume": -6.0, "pan": 0.0 },
    "consecutiveFailures": 3
  },
  "timestamps": {
    "serverMs": 1735827000123
  },
  "transient": true,
  "correlationId": "550e8400-e29b-41d4-a716-446655440000"
}
```

**Error code registry:**

| Range | Category | Examples |
|-------|----------|----------|
| 1xxx | Poll/timing | 1001 poll timeout, 1002 frame drop |
| 2xxx | Connection | 2001 DAW disconnected, 2002 reconnecting |
| 3xxx | State | 3001 track unavailable, 3002 invalid float received |
| 4xxx | Client | 4001 invalid command, 4003 rate limited |
| 5xxx | System | 5001 internal error, 5002 out of memory |

**Aggregate repeated errors** server-side. At 30Hz, sending every occurrence would spam clients:

```zig
pub const ErrorAggregator = struct {
    counts: std.AutoHashMap(u16, AggregatedError),
    
    pub const AggregatedError = struct {
        first_seen_ms: i64,
        last_seen_ms: i64,
        count: u32,
        last_emitted_ms: i64,
    };
    
    pub fn shouldEmit(self: *ErrorAggregator, code: u16) bool {
        const now = std.time.milliTimestamp();
        if (self.counts.getPtr(code)) |entry| {
            entry.count += 1;
            entry.last_seen_ms = now;
            // Emit at most once per second per error type
            if (now - entry.last_emitted_ms >= 1000) {
                entry.last_emitted_ms = now;
                return true;
            }
            return false;
        }
        // First occurrence - always emit
        self.counts.put(code, .{
            .first_seen_ms = now,
            .last_seen_ms = now,
            .count = 1,
            .last_emitted_ms = now,
        }) catch return true;
        return true;
    }
};
```

## Allocation-free logging with crash ring buffer

Pre-allocate a ring buffer at startup that captures the last N log entries. When a crash occurs, this buffer survives and can be dumped:

```zig
pub const CrashRingLog = struct {
    const ENTRY_SIZE = 256;
    const MAX_ENTRIES = 64;
    
    buffer: [ENTRY_SIZE * MAX_ENTRIES]u8 = undefined,
    write_pos: usize = 0,
    entry_count: usize = 0,
    
    pub fn write(self: *CrashRingLog, comptime fmt: []const u8, args: anytype) void {
        var entry: [ENTRY_SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&entry);
        const writer = fbs.writer();
        
        // Timestamp prefix
        writer.print("[{d}] ", .{std.time.milliTimestamp()}) catch {};
        writer.print(fmt, args) catch {};
        
        // Copy to ring buffer (wraps around)
        const len = fbs.pos;
        const start = self.write_pos % (ENTRY_SIZE * MAX_ENTRIES);
        @memcpy(self.buffer[start..][0..len], entry[0..len]);
        self.write_pos += ENTRY_SIZE;
        self.entry_count +|= 1;
    }
    
    pub fn dump(self: *CrashRingLog) []const u8 {
        const used = @min(self.entry_count, MAX_ENTRIES) * ENTRY_SIZE;
        return self.buffer[0..used];
    }
};

var crash_log: CrashRingLog = .{};
```

**Override the panic handler** to flush logs before crash:

```zig
pub const panic = std.debug.FullPanic(crashHandler);

fn crashHandler(msg: []const u8, return_address: ?usize) noreturn {
    @setCold(true);
    
    // Write panic to ring buffer
    crash_log.write("PANIC: {s}", .{msg});
    
    // Dump ring buffer to stderr
    std.debug.print("\n=== CRASH LOG ({d} entries) ===\n{s}\n", .{
        crash_log.entry_count,
        crash_log.dump(),
    });
    
    // Flush any file loggers
    if (file_logger) |*fl| fl.flush() catch {};
    
    std.posix.abort();
}
```

**Runtime log levels** require a wrapper since `std.log` filtering is compile-time:

```zig
var runtime_level: std.log.Level = .info;

pub fn initLogging() void {
    const env = std.posix.getenv("REAMO_LOG_LEVEL") orelse "info";
    runtime_level = std.meta.stringToEnum(std.log.Level, env) orelse .info;
}

pub fn log(comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
    // Always write to crash ring buffer regardless of level
    crash_log.write(fmt, args);
    
    // Filter based on runtime level
    if (@intFromEnum(level) <= @intFromEnum(runtime_level)) {
        std.log.scoped(.reamo).log(level, fmt, args);
    }
}
```

## React client error display strategy

For a creative workflow on iPad where users have their hands on faders, **minimize interruption**:

| Severity | Display | Duration | When |
|----------|---------|----------|------|
| Fatal | Overlay + reconnecting | Until resolved | DAW disconnected |
| Error | Inline badge + toast | Persistent until recovery | Sync failure |
| Warning | Inline indicator | Auto-dismiss 8s | Data 3s stale |
| Info | Toast | Auto-dismiss 3s | Reconnection success |

**Stale data hook:**

```typescript
const useStaleIndicator = (lastUpdate: number, thresholdMs = 1000) => {
  const [staleness, setStaleness] = useState<'fresh' | 'stale' | 'disconnected'>('fresh');
  
  useEffect(() => {
    const interval = setInterval(() => {
      const age = Date.now() - lastUpdate;
      if (age < thresholdMs) setStaleness('fresh');
      else if (age < thresholdMs * 5) setStaleness('stale');
      else setStaleness('disconnected');
    }, 100);
    return () => clearInterval(interval);
  }, [lastUpdate, thresholdMs]);
  
  return staleness;
};
```

**Visual treatment:**
- **Fresh**: Normal rendering
- **Stale**: 80% opacity, yellow timestamp badge showing "3s ago"
- **Disconnected**: 60% opacity, "Reconnecting..." banner, last-known-good values displayed

**Error boundaries isolate failures:**

```tsx
<ErrorBoundary FallbackComponent={StreamErrorFallback} onError={captureToSentry}>
  <ConnectionStatusBar />  {/* Always visible, minimal */}
  <ErrorBoundary FallbackComponent={TrackErrorFallback}>
    <MixerDisplay />
  </ErrorBoundary>
  <ToastContainer position="bottom-right" />
</ErrorBoundary>
```

Capture errors to Sentry with stream context—last successful update, reconnect attempts, recent events—so developers can debug without reproduction.

## Architecture summary

The complete error flow:

1. **REAPER C API call** → FFI wrapper validates immediately (NaN/Inf/null)
2. **Validation failure** → Error returned with stack-based context via `errdefer`
3. **Poll layer** → Records error, continues with other items, applies circuit breaker
4. **Serialization** → Partial data with error codes and staleness info
5. **WebSocket** → Aggregated errors sent alongside data frames
6. **React client** → Renders last-known-good with staleness indicators, reports to Sentry

**Key invariants maintained:**
- No heap allocation in error paths (stack buffers, pre-allocated ring)
- No blocking on main thread (circuit breakers fail fast)
- No crashes from bad C data (validation at boundary)
- No fake data (explicit nulls and error codes propagate to client)
- Full debug context from error reports alone (correlation IDs, timestamps, stack-based context)

This architecture ensures Reamo degrades gracefully—stale data with warnings is always preferable to a crash that destroys the user's session.
