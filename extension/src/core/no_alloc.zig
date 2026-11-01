//! Checks that code which must not allocate (the audio thread's, and the
//! tuner analysis that runs at 30 Hz) can't, for tests to assert.
//!
//! No runtime check can see every allocation: std.heap.page_allocator and
//! c_allocator are globals a function can call without being handed
//! anything. So the guard is two static checks:
//! - `reachesAllocator`: no std.mem.Allocator is reachable from a type the
//!   code works on or a parameter it takes, so it has no allocator of its
//!   own to call;
//! - `allocationIn`: the function's own body (comments aside) names no
//!   allocator and calls no allocating function, so it doesn't reach for a
//!   global one either.
//! Functions it calls are checked only if they are checked too.
const std = @import("std");

/// Whether a value of type T can lead to a std.mem.Allocator, through its
/// fields, elements, optionals or pointers (followed `depth` levels deep).
pub fn reachesAllocator(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    return reaches(T, 8);
}

fn reaches(comptime T: type, comptime depth: u32) bool {
    if (T == std.mem.Allocator) return true;
    if (depth == 0) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            if (reaches(f.type, depth - 1)) break true;
        } else false,
        .@"union" => |u| inline for (u.fields) |f| {
            if (reaches(f.type, depth - 1)) break true;
        } else false,
        .array => |a| reaches(a.child, depth - 1),
        .optional => |o| reaches(o.child, depth - 1),
        .pointer => |p| if (@typeInfo(p.child) == .@"fn" or @typeInfo(p.child) == .@"opaque") false else reaches(p.child, depth - 1),
        else => false,
    };
}

/// Whether any parameter of the function type F reaches an allocator.
pub fn paramsReachAllocator(comptime F: type) bool {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(F).@"fn".params) |p| {
        if (p.type) |T| if (reachesAllocator(T)) return true;
    }
    return false;
}

/// Words that mean an allocation in a function body: any allocator
/// (`allocator`, `page_allocator`, `Allocator`, `.alloc(`, `realloc`), and
/// the std containers that allocate as they grow.
const allocating = [_][]const u8{ "alloc", "Alloc", ".create(", ".dupe(", "ArrayList", "HashMap", "MultiArrayList", "SegmentedList" };

/// The first allocating word in the body of `fn name(` in `source`,
/// comments left out, or null. The body must exist: a renamed function
/// fails loudly rather than passing unchecked.
pub fn allocationIn(source: []const u8, comptime name: []const u8) error{FunctionNotFound}!?[]const u8 {
    const head = std.mem.indexOf(u8, source, "fn " ++ name ++ "(") orelse return error.FunctionNotFound;
    const open = std.mem.indexOfScalarPos(u8, source, head, '{') orelse return error.FunctionNotFound;
    var depth: usize = 0;
    var i = open;
    var in_comment = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == '\n') {
            in_comment = false;
            continue;
        }
        if (in_comment) continue;
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            in_comment = true;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return null;
        }
        for (allocating) |word| {
            if (std.mem.startsWith(u8, source[i..], word)) return word;
        }
    }
    return error.FunctionNotFound;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "an allocator is found in a field, behind a pointer or an optional, or in an array" {
    const Plain = struct { a: u32, b: [4]f32 };
    const Field = struct { x: u8, gpa: std.mem.Allocator };
    const Nested = struct { inner: struct { p: ?*Field } };
    const InArray = struct { many: [2]Field };
    try testing.expect(!reachesAllocator(Plain));
    try testing.expect(reachesAllocator(Field));
    try testing.expect(reachesAllocator(Nested));
    try testing.expect(reachesAllocator(InArray));
    try testing.expect(!paramsReachAllocator(fn (*Plain, []const f32) void));
    try testing.expect(paramsReachAllocator(fn (*Plain, std.mem.Allocator) void));
    try testing.expect(paramsReachAllocator(fn (*Nested) void));
}

test "an allocation in a body is found, one in a comment or another function isn't" {
    const src =
        \\fn clean(x: u32) u32 {
        \\    // allocate nothing here: this comment says alloc
        \\    if (x > 1) { return x; }
        \\    return 0;
        \\}
        \\fn dirty(x: u32) void {
        \\    if (x > 1) {
        \\        _ = std.heap.page_allocator.alloc(u8, 16) catch {};
        \\    }
        \\}
        \\fn grows() void {
        \\    var list: std.ArrayList(u8) = .empty;
        \\}
    ;
    try testing.expectEqual(@as(?[]const u8, null), try allocationIn(src, "clean"));
    try testing.expectEqualStrings("alloc", (try allocationIn(src, "dirty")).?);
    try testing.expectEqualStrings("ArrayList", (try allocationIn(src, "grows")).?);
    try testing.expectError(error.FunctionNotFound, allocationIn(src, "missing"));
}
