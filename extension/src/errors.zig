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
