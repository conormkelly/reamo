const std = @import("std");
const errors = @import("errors.zig");

// =============================================================================
// FFI Validation Layer
// =============================================================================
//
// All data crossing the REAPER C API boundary is untrusted. This module provides
// safe wrappers that convert C-style return values (nullable pointers, floats
// that may be NaN/Inf) into Zig errors.
//
// Key insight: Zig's @intFromFloat PANICS on NaN/Inf/out-of-range. We must
// validate BEFORE calling @intFromFloat, never after.
//
// Usage:
//   const track = try ffi.requirePtr(api.getTrack(0));
//   const solo = try ffi.safeFloatToInt(c_int, api.getTrackInfo(track, "I_SOLO"));
// =============================================================================

pub const FFIError = errors.FFIError;

/// Convert float to integer safely, returning error on NaN/Inf/out-of-range.
///
/// This MUST be used instead of @intFromFloat for any value from REAPER APIs.
/// Zig's @intFromFloat panics on invalid input - this function returns an error.
///
/// Example:
///   const solo_state = try ffi.safeFloatToInt(c_int, getMediaTrackInfo_Value(track, "I_SOLO"));
///
pub fn safeFloatToInt(comptime T: type, value: f64) FFIError!T {
    if (std.math.isNan(value)) return error.FloatIsNaN;
    if (std.math.isInf(value)) return error.FloatIsInf;

    // For unsigned types, explicitly reject negative values with specific error
    if (@typeInfo(T).int.signedness == .unsigned and value < 0) {
        return error.NegativeToUnsigned;
    }

    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));

    if (value < min_val or value > max_val) return error.IntegerOverflow;

    return @intFromFloat(value);
}

/// Validate a float value, returning error on NaN/Inf.
///
/// Use this when the value stays as a float but needs validation.
///
/// Example:
///   const volume = try ffi.sanitizeFloat(getMediaTrackInfo_Value(track, "D_VOL"));
///
pub fn sanitizeFloat(value: f64) FFIError!f64 {
    if (std.math.isNan(value)) return error.FloatIsNaN;
    if (std.math.isInf(value)) return error.FloatIsInf;
    return value;
}

/// Check if a float is valid (not NaN or Inf).
///
/// Use this for conditional checks without errors.
///
/// Example:
///   if (!ffi.isFinite(value)) {
///       log.warn("Skipping track with invalid volume", .{});
///       continue;
///   }
///
pub fn isFinite(value: f64) bool {
    return std.math.isFinite(value);
}

/// Convert nullable pointer to non-null, returning error if null.
///
/// Example:
///   const track = try ffi.requirePtr(api.getTrack(idx));
///
pub fn requirePtr(comptime T: type, ptr: ?*T) FFIError!*T {
    return ptr orelse error.NullPointer;
}

/// Convert nullable const pointer to non-null, returning error if null.
pub fn requireConstPtr(comptime T: type, ptr: ?*const T) FFIError!*const T {
    return ptr orelse error.NullPointer;
}

/// Convert nullable anyopaque pointer to non-null, returning error if null.
///
/// Many REAPER APIs return *anyopaque for tracks, items, etc.
///
/// Example:
///   const track = try ffi.requireOpaquePtr(api.getTrack(idx));
///
pub fn requireOpaquePtr(ptr: ?*anyopaque) FFIError!*anyopaque {
    return ptr orelse error.NullPointer;
}

/// Safely clamp a float to a range before converting to int.
///
/// Use when you want clamping behavior instead of errors for out-of-range.
/// Still returns error for NaN/Inf.
///
/// Example:
///   const percent = try ffi.clampFloatToInt(u8, value, 0, 255);
///
pub fn clampFloatToInt(comptime T: type, value: f64, min: T, max: T) FFIError!T {
    if (std.math.isNan(value)) return error.FloatIsNaN;
    if (std.math.isInf(value)) return error.FloatIsInf;

    const min_f: f64 = @floatFromInt(min);
    const max_f: f64 = @floatFromInt(max);
    const clamped = @max(min_f, @min(max_f, value));

    return @intFromFloat(clamped);
}

/// Round and convert to int, returning error on NaN/Inf/out-of-range.
///
/// Example:
///   const ticks = try ffi.roundFloatToInt(u32, beats * 100.0);
///
pub fn roundFloatToInt(comptime T: type, value: f64) FFIError!T {
    if (std.math.isNan(value)) return error.FloatIsNaN;
    if (std.math.isInf(value)) return error.FloatIsInf;

    const rounded = @round(value);

    // For unsigned types, explicitly reject negative values with specific error
    if (@typeInfo(T).int.signedness == .unsigned and rounded < 0) {
        return error.NegativeToUnsigned;
    }

    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));

    if (rounded < min_val or rounded > max_val) return error.IntegerOverflow;

    return @intFromFloat(rounded);
}

// =============================================================================
// Tests
// =============================================================================

test "safeFloatToInt handles normal values" {
    try std.testing.expectEqual(@as(c_int, 42), try safeFloatToInt(c_int, 42.0));
    try std.testing.expectEqual(@as(c_int, -10), try safeFloatToInt(c_int, -10.0));
    try std.testing.expectEqual(@as(c_int, 0), try safeFloatToInt(c_int, 0.0));
    try std.testing.expectEqual(@as(c_int, 0), try safeFloatToInt(c_int, 0.9)); // truncates
    try std.testing.expectEqual(@as(c_int, 1), try safeFloatToInt(c_int, 1.9)); // truncates
}

test "safeFloatToInt rejects NaN" {
    try std.testing.expectError(error.FloatIsNaN, safeFloatToInt(c_int, std.math.nan(f64)));
}

test "safeFloatToInt rejects Inf" {
    try std.testing.expectError(error.FloatIsInf, safeFloatToInt(c_int, std.math.inf(f64)));
    try std.testing.expectError(error.FloatIsInf, safeFloatToInt(c_int, -std.math.inf(f64)));
}

test "safeFloatToInt rejects overflow" {
    // c_int is typically 32-bit
    const huge: f64 = 9_999_999_999_999.0;
    try std.testing.expectError(error.IntegerOverflow, safeFloatToInt(c_int, huge));
    try std.testing.expectError(error.IntegerOverflow, safeFloatToInt(c_int, -huge));
}

test "safeFloatToInt works with u32" {
    try std.testing.expectEqual(@as(u32, 100), try safeFloatToInt(u32, 100.0));
    try std.testing.expectError(error.NegativeToUnsigned, safeFloatToInt(u32, -1.0));
}

test "safeFloatToInt rejects negative values for unsigned types" {
    try std.testing.expectError(error.NegativeToUnsigned, safeFloatToInt(u8, -1.0));
    try std.testing.expectError(error.NegativeToUnsigned, safeFloatToInt(u16, -0.5));
    try std.testing.expectError(error.NegativeToUnsigned, safeFloatToInt(usize, -100.0));
}

test "sanitizeFloat accepts normal values" {
    try std.testing.expectEqual(@as(f64, 3.14), try sanitizeFloat(3.14));
    try std.testing.expectEqual(@as(f64, 0.0), try sanitizeFloat(0.0));
    try std.testing.expectEqual(@as(f64, -100.5), try sanitizeFloat(-100.5));
}

test "sanitizeFloat rejects NaN" {
    try std.testing.expectError(error.FloatIsNaN, sanitizeFloat(std.math.nan(f64)));
}

test "sanitizeFloat rejects Inf" {
    try std.testing.expectError(error.FloatIsInf, sanitizeFloat(std.math.inf(f64)));
    try std.testing.expectError(error.FloatIsInf, sanitizeFloat(-std.math.inf(f64)));
}

test "isFinite returns correct values" {
    try std.testing.expect(isFinite(0.0));
    try std.testing.expect(isFinite(3.14));
    try std.testing.expect(isFinite(-100.0));
    try std.testing.expect(!isFinite(std.math.nan(f64)));
    try std.testing.expect(!isFinite(std.math.inf(f64)));
    try std.testing.expect(!isFinite(-std.math.inf(f64)));
}

test "requirePtr succeeds with valid pointer" {
    var x: i32 = 42;
    const ptr: ?*i32 = &x;
    const result = try requirePtr(i32, ptr);
    try std.testing.expectEqual(@as(i32, 42), result.*);
}

test "requirePtr fails with null" {
    const ptr: ?*i32 = null;
    try std.testing.expectError(error.NullPointer, requirePtr(i32, ptr));
}

test "requireOpaquePtr succeeds with valid pointer" {
    var x: i32 = 42;
    const ptr: ?*anyopaque = @ptrCast(&x);
    const result = try requireOpaquePtr(ptr);
    // If we got here, requireOpaquePtr succeeded (returned non-null pointer)
    try std.testing.expect(@intFromPtr(result) != 0);
}

test "requireOpaquePtr fails with null" {
    const ptr: ?*anyopaque = null;
    try std.testing.expectError(error.NullPointer, requireOpaquePtr(ptr));
}

test "clampFloatToInt clamps to range" {
    try std.testing.expectEqual(@as(u8, 0), try clampFloatToInt(u8, -10.0, 0, 255));
    try std.testing.expectEqual(@as(u8, 255), try clampFloatToInt(u8, 300.0, 0, 255));
    try std.testing.expectEqual(@as(u8, 128), try clampFloatToInt(u8, 128.0, 0, 255));
}

test "clampFloatToInt still rejects NaN" {
    try std.testing.expectError(error.FloatIsNaN, clampFloatToInt(u8, std.math.nan(f64), 0, 255));
}

test "roundFloatToInt rounds correctly" {
    try std.testing.expectEqual(@as(u32, 100), try roundFloatToInt(u32, 99.5));
    try std.testing.expectEqual(@as(u32, 99), try roundFloatToInt(u32, 99.4));
    try std.testing.expectEqual(@as(u32, 0), try roundFloatToInt(u32, 0.4));
    try std.testing.expectEqual(@as(u32, 1), try roundFloatToInt(u32, 0.5));
}

test "roundFloatToInt rejects NaN and Inf" {
    try std.testing.expectError(error.FloatIsNaN, roundFloatToInt(u32, std.math.nan(f64)));
    try std.testing.expectError(error.FloatIsInf, roundFloatToInt(u32, std.math.inf(f64)));
}

test "roundFloatToInt rejects overflow" {
    try std.testing.expectError(error.IntegerOverflow, roundFloatToInt(u8, 256.0));
    try std.testing.expectError(error.NegativeToUnsigned, roundFloatToInt(u8, -1.0));
}
