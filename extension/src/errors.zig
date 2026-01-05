const std = @import("std");

// =============================================================================
// Error Type Hierarchy for Reamo Extension
// =============================================================================
//
// Design principles:
// 1. Errors carry semantic meaning - not just "something went wrong"
// 2. Error sets compose at module boundaries
// 3. No silent failures - every error must be handled or propagated
// 4. Errors should be actionable - a developer can understand what to do
//
// Usage:
//   - FFI layer uses FFIError for C API boundary issues
//   - State modules use composed error sets (FFIError || ReaperStateError)
//   - Commands can return ReamoError for full flexibility
// =============================================================================

/// Errors from C FFI boundary - invalid data from REAPER APIs
pub const FFIError = error{
    /// C API returned null where a valid pointer was expected
    NullPointer,
    /// Float value is NaN (not a number)
    FloatIsNaN,
    /// Float value is infinite (+Inf or -Inf)
    FloatIsInf,
    /// Float value is outside the representable range for target integer type
    IntegerOverflow,
    /// Negative float value cannot be converted to unsigned integer type
    NegativeToUnsigned,
    /// Pointer failed REAPER's ValidatePtr2 check
    InvalidPointer,
};

/// Errors related to REAPER project/track/item state
pub const ReaperStateError = error{
    /// Track pointer is stale (track was deleted)
    TrackDeleted,
    /// Item pointer is stale (item was deleted)
    ItemDeleted,
    /// Take pointer is stale (take was deleted)
    TakeDeleted,
    /// No project is currently open
    NoActiveProject,
    /// Project state is inconsistent or corrupt
    InvalidProject,
    /// Requested index is out of bounds
    IndexOutOfBounds,
};

/// Errors related to resource allocation and limits
pub const ResourceError = error{
    /// Memory allocation failed
    OutOfMemory,
    /// Fixed-size buffer is full
    BufferFull,
    /// Command queue is at capacity
    QueueOverflow,
    /// Maximum concurrent clients reached
    TooManyClients,
    /// Maximum items/tracks/markers limit exceeded
    LimitExceeded,
};

/// Errors related to protocol/serialization
pub const ProtocolError = error{
    /// JSON serialization failed
    SerializationFailed,
    /// JSON parsing failed
    ParseError,
    /// Required field missing from message
    MissingField,
    /// Field value is invalid
    InvalidValue,
};

/// Composed error set for poll operations (FFI + State)
pub const PollError = FFIError || ReaperStateError;

/// Composed error set for command handlers (all errors possible)
pub const ReamoError = FFIError || ReaperStateError || ResourceError || ProtocolError;

// =============================================================================
// Error Code Registry
// =============================================================================
//
// Numeric codes for client-side error handling and logging.
// Ranges:
//   1xxx - Poll/timing errors
//   2xxx - Connection errors
//   3xxx - State errors (track/item/project)
//   4xxx - Client/protocol errors
//   5xxx - System/resource errors
// =============================================================================

pub const ErrorCode = enum(u16) {
    // 1xxx - Poll/timing
    poll_timeout = 1001,
    frame_drop = 1002,
    clock_sync_failed = 1003,

    // 2xxx - Connection
    connection_lost = 2001,
    reconnecting = 2002,
    authentication_failed = 2003,

    // 3xxx - State
    track_unavailable = 3001,
    item_unavailable = 3002,
    float_nan = 3003,
    float_inf = 3004,
    integer_overflow = 3005,
    null_pointer = 3006,
    project_invalid = 3007,
    index_out_of_bounds = 3008,
    negative_to_unsigned = 3009,

    // 4xxx - Client/protocol
    invalid_command = 4001,
    missing_parameter = 4002,
    rate_limited = 4003,
    parse_error = 4004,

    // 5xxx - System
    internal_error = 5001,
    out_of_memory = 5002,
    buffer_full = 5003,
    limit_exceeded = 5004,

    /// Convert error to code for client transmission
    pub fn fromError(err: anyerror) ErrorCode {
        return switch (err) {
            error.NullPointer => .null_pointer,
            error.FloatIsNaN => .float_nan,
            error.FloatIsInf => .float_inf,
            error.IntegerOverflow => .integer_overflow,
            error.NegativeToUnsigned => .negative_to_unsigned,
            error.InvalidPointer => .null_pointer,
            error.TrackDeleted => .track_unavailable,
            error.ItemDeleted => .item_unavailable,
            error.TakeDeleted => .item_unavailable,
            error.NoActiveProject => .project_invalid,
            error.InvalidProject => .project_invalid,
            error.IndexOutOfBounds => .index_out_of_bounds,
            error.OutOfMemory => .out_of_memory,
            error.BufferFull => .buffer_full,
            error.QueueOverflow => .buffer_full,
            error.LimitExceeded => .limit_exceeded,
            error.SerializationFailed => .internal_error,
            error.ParseError => .parse_error,
            error.MissingField => .missing_parameter,
            error.InvalidValue => .invalid_command,
            else => .internal_error,
        };
    }

    /// Get human-readable title for error code
    pub fn title(self: ErrorCode) []const u8 {
        return switch (self) {
            .poll_timeout => "Poll timeout",
            .frame_drop => "Frame dropped",
            .clock_sync_failed => "Clock sync failed",
            .connection_lost => "Connection lost",
            .reconnecting => "Reconnecting",
            .authentication_failed => "Authentication failed",
            .track_unavailable => "Track unavailable",
            .item_unavailable => "Item unavailable",
            .float_nan => "Invalid float value (NaN)",
            .float_inf => "Invalid float value (Infinity)",
            .integer_overflow => "Integer overflow",
            .negative_to_unsigned => "Negative value for unsigned type",
            .null_pointer => "Null pointer from REAPER",
            .project_invalid => "Project invalid",
            .index_out_of_bounds => "Index out of bounds",
            .invalid_command => "Invalid command",
            .missing_parameter => "Missing parameter",
            .rate_limited => "Rate limited",
            .parse_error => "Parse error",
            .internal_error => "Internal error",
            .out_of_memory => "Out of memory",
            .buffer_full => "Buffer full",
            .limit_exceeded => "Limit exceeded",
        };
    }

    /// Is this error transient (may resolve on retry)?
    pub fn isTransient(self: ErrorCode) bool {
        return switch (self) {
            .poll_timeout, .frame_drop, .clock_sync_failed, .reconnecting, .rate_limited => true,
            else => false,
        };
    }

    /// Severity level for UI display
    pub fn severity(self: ErrorCode) Severity {
        return switch (self) {
            .connection_lost, .authentication_failed, .out_of_memory => .@"error",
            .track_unavailable, .item_unavailable, .project_invalid, .index_out_of_bounds => .warning,
            .poll_timeout, .frame_drop, .clock_sync_failed, .reconnecting => .info,
            else => .warning,
        };
    }
};

pub const Severity = enum {
    info,
    warning,
    @"error",

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

// =============================================================================
// Error Event for Client Broadcasting
// =============================================================================
//
// Format:
// {
//   "type": "event",
//   "event": "error",
//   "payload": {
//     "code": 3001,
//     "severity": "warning",
//     "title": "Track unavailable",
//     "detail": "Track 5 returned corrupt data",
//     "transient": true
//   }
// }
// =============================================================================

/// Error event for broadcasting to clients
pub const ErrorEvent = struct {
    code: ErrorCode,
    detail: ?[]const u8 = null,

    /// Build JSON error event
    /// Returns slice of written bytes, or null on buffer overflow
    pub fn toJson(self: ErrorEvent, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        const code_val = @intFromEnum(self.code);
        const sev = self.code.severity().toString();
        const title = self.code.title();
        const transient = self.code.isTransient();

        writer.print("{{\"type\":\"event\",\"event\":\"error\",\"payload\":{{\"code\":{d},\"severity\":\"{s}\",\"title\":\"{s}\",", .{
            code_val,
            sev,
            title,
        }) catch return null;

        // Optional detail field
        if (self.detail) |d| {
            writer.writeAll("\"detail\":\"") catch return null;
            // Escape JSON string (simple escaping for common cases)
            for (d) |c| {
                switch (c) {
                    '"' => writer.writeAll("\\\"") catch return null,
                    '\\' => writer.writeAll("\\\\") catch return null,
                    '\n' => writer.writeAll("\\n") catch return null,
                    '\r' => writer.writeAll("\\r") catch return null,
                    '\t' => writer.writeAll("\\t") catch return null,
                    else => {
                        if (c >= 0x20) {
                            writer.writeByte(c) catch return null;
                        }
                    },
                }
            }
            writer.writeAll("\",") catch return null;
        }

        writer.print("\"transient\":{s}}}}}", .{if (transient) "true" else "false"}) catch return null;

        return stream.getWritten();
    }

    /// Create error event from Zig error
    pub fn fromError(err: anyerror, detail: ?[]const u8) ErrorEvent {
        return .{
            .code = ErrorCode.fromError(err),
            .detail = detail,
        };
    }
};

// =============================================================================
// Error Rate Limiter
// =============================================================================
//
// Prevents flooding clients with repeated error events.
// Limits to max 1 error per ErrorCode per second.
// =============================================================================

/// Rate limiter for error broadcasts
/// Prevents flooding clients with repeated errors
pub const ErrorRateLimiter = struct {
    /// Last broadcast timestamp (in seconds) for each error code
    /// Uses array indexed by error code value for O(1) lookup
    last_broadcast: [MAX_ERROR_CODES]i64 = [_]i64{0} ** MAX_ERROR_CODES,

    /// Minimum interval between broadcasts of same error type (in seconds)
    const MIN_INTERVAL_SECS: i64 = 1;
    /// Maximum error codes we track (covers our 1xxx-5xxx range)
    const MAX_ERROR_CODES: usize = 6000;

    /// Check if we should broadcast this error (rate limiting)
    /// Returns true if enough time has passed since last broadcast
    pub fn shouldBroadcast(self: *ErrorRateLimiter, code: ErrorCode, current_time_secs: i64) bool {
        const idx = @intFromEnum(code);
        if (idx >= MAX_ERROR_CODES) return false;

        const last = self.last_broadcast[idx];
        if (current_time_secs - last >= MIN_INTERVAL_SECS) {
            self.last_broadcast[idx] = current_time_secs;
            return true;
        }
        return false;
    }

    /// Record that an error was broadcast (if you want to separate check and record)
    pub fn recordBroadcast(self: *ErrorRateLimiter, code: ErrorCode, current_time_secs: i64) void {
        const idx = @intFromEnum(code);
        if (idx < MAX_ERROR_CODES) {
            self.last_broadcast[idx] = current_time_secs;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ErrorCode.fromError maps FFI errors" {
    try std.testing.expectEqual(ErrorCode.float_nan, ErrorCode.fromError(error.FloatIsNaN));
    try std.testing.expectEqual(ErrorCode.float_inf, ErrorCode.fromError(error.FloatIsInf));
    try std.testing.expectEqual(ErrorCode.integer_overflow, ErrorCode.fromError(error.IntegerOverflow));
    try std.testing.expectEqual(ErrorCode.null_pointer, ErrorCode.fromError(error.NullPointer));
}

test "ErrorCode.fromError maps state errors" {
    try std.testing.expectEqual(ErrorCode.track_unavailable, ErrorCode.fromError(error.TrackDeleted));
    try std.testing.expectEqual(ErrorCode.item_unavailable, ErrorCode.fromError(error.ItemDeleted));
    try std.testing.expectEqual(ErrorCode.project_invalid, ErrorCode.fromError(error.NoActiveProject));
}

test "ErrorCode.fromError maps resource errors" {
    try std.testing.expectEqual(ErrorCode.out_of_memory, ErrorCode.fromError(error.OutOfMemory));
    try std.testing.expectEqual(ErrorCode.buffer_full, ErrorCode.fromError(error.BufferFull));
    try std.testing.expectEqual(ErrorCode.limit_exceeded, ErrorCode.fromError(error.LimitExceeded));
}

test "ErrorCode.fromError returns internal_error for unknown" {
    // Some random error not in our set
    try std.testing.expectEqual(ErrorCode.internal_error, ErrorCode.fromError(error.Unexpected));
}

test "ErrorCode.title returns non-empty strings" {
    inline for (std.meta.fields(ErrorCode)) |field| {
        const code: ErrorCode = @enumFromInt(field.value);
        try std.testing.expect(code.title().len > 0);
    }
}

test "ErrorCode.isTransient identifies retryable errors" {
    try std.testing.expect(ErrorCode.poll_timeout.isTransient());
    try std.testing.expect(ErrorCode.reconnecting.isTransient());
    try std.testing.expect(!ErrorCode.out_of_memory.isTransient());
    try std.testing.expect(!ErrorCode.authentication_failed.isTransient());
}

test "Severity.toString returns valid strings" {
    try std.testing.expectEqualStrings("info", Severity.info.toString());
    try std.testing.expectEqualStrings("warning", Severity.warning.toString());
    try std.testing.expectEqualStrings("error", Severity.@"error".toString());
}

test "ErrorEvent.toJson builds valid JSON" {
    const event = ErrorEvent{
        .code = .track_unavailable,
        .detail = "Track 5 returned corrupt data",
    };

    var buf: [512]u8 = undefined;
    const json = event.toJson(&buf).?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":3001") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"severity\":\"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"title\":\"Track unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"detail\":\"Track 5 returned corrupt data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transient\":false") != null);
}

test "ErrorEvent.toJson without detail" {
    const event = ErrorEvent{
        .code = .poll_timeout,
        .detail = null,
    };

    var buf: [256]u8 = undefined;
    const json = event.toJson(&buf).?;

    // Should have code, severity, title, transient but no detail
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":1001") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transient\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"detail\"") == null);
}

test "ErrorEvent.toJson escapes special characters in detail" {
    const event = ErrorEvent{
        .code = .internal_error,
        .detail = "Error with \"quotes\" and \\backslash",
    };

    var buf: [512]u8 = undefined;
    const json = event.toJson(&buf).?;

    // Verify escaping
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\\backslash") != null);
}

test "ErrorEvent.fromError creates correct event" {
    const event = ErrorEvent.fromError(error.FloatIsNaN, "Some detail");

    try std.testing.expectEqual(ErrorCode.float_nan, event.code);
    try std.testing.expectEqualStrings("Some detail", event.detail.?);
}

test "ErrorRateLimiter allows first broadcast" {
    var limiter = ErrorRateLimiter{};
    // First broadcast should always be allowed
    try std.testing.expect(limiter.shouldBroadcast(.track_unavailable, 1000));
}

test "ErrorRateLimiter blocks rapid broadcasts of same code" {
    var limiter = ErrorRateLimiter{};
    // First should succeed
    try std.testing.expect(limiter.shouldBroadcast(.track_unavailable, 1000));
    // Same code within 1 second should be blocked
    try std.testing.expect(!limiter.shouldBroadcast(.track_unavailable, 1000));
}

test "ErrorRateLimiter allows broadcast after interval" {
    var limiter = ErrorRateLimiter{};
    // First at time 1000
    try std.testing.expect(limiter.shouldBroadcast(.track_unavailable, 1000));
    // Blocked at 1000
    try std.testing.expect(!limiter.shouldBroadcast(.track_unavailable, 1000));
    // Allowed at 1001 (1 second later)
    try std.testing.expect(limiter.shouldBroadcast(.track_unavailable, 1001));
}

test "ErrorRateLimiter tracks different codes independently" {
    var limiter = ErrorRateLimiter{};
    // First code
    try std.testing.expect(limiter.shouldBroadcast(.track_unavailable, 1000));
    // Different code should not be blocked
    try std.testing.expect(limiter.shouldBroadcast(.float_nan, 1000));
    // Original code still blocked
    try std.testing.expect(!limiter.shouldBroadcast(.track_unavailable, 1000));
}
