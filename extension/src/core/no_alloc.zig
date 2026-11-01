//! A tripwire for code that must not allocate (the audio thread's, and the
//! tuner analysis that runs at 30 Hz): static checks for tests to assert,
//! which catch the accidental ways an allocation creeps in. They are not a
//! proof. They read source text and types, not the compiled program, so
//! code written to slip past them (an allocation behind a function pointer,
//! in another file nobody listed, or named in a way the word list doesn't
//! know) can.
//!
//! No runtime check can see every allocation: std.heap.page_allocator and
//! c_allocator are globals a function can call without being handed
//! anything. So the checks are:
//! - `reachesAllocation`: no std.mem.Allocator, and no std container that
//!   allocates as it grows (an ArrayList or HashMap, managed or not), is
//!   reachable from a type the code works on or a parameter it takes;
//! - `allocationIn`: the function's body, and the body of every function
//!   in the same file it calls, names no allocator, heap, allocating call
//!   or container (`allocating`), comments and string literals aside. A
//!   function in another file is checked only if a test names it too.
//! - `forbiddenIn`: the same scan for any other words, such as logging on
//!   the audio thread.
const std = @import("std");

/// Whether a value of type T can lead to a std.mem.Allocator, or to a std
/// container that allocates as it grows (managed or unmanaged), through its
/// fields, elements, optionals or pointers (followed 8 levels deep).
pub fn reachesAllocation(comptime T: type) bool {
    @setEvalBranchQuota(200_000);
    return reaches(T, 8);
}

/// std's allocating containers, by the file each is declared in, which
/// their type names start with (`array_list.Aligned(u8,null)`).
const container_files = [_][]const u8{ "array_list.", "hash_map.", "array_hash_map.", "multi_array_list.", "segmented_list.", "priority_queue.", "priority_dequeue.", "linked_list." };

fn isContainer(comptime T: type) bool {
    const name = @typeName(T);
    inline for (container_files) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

fn reaches(comptime T: type, comptime depth: u32) bool {
    if (T == std.mem.Allocator) return true;
    if (depth == 0) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| isContainer(T) or inline for (s.fields) |f| {
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

/// Whether any parameter of the function type F reaches an allocation.
pub fn paramsReachAllocation(comptime F: type) bool {
    @setEvalBranchQuota(200_000);
    inline for (@typeInfo(F).@"fn".params) |p| {
        if (p.type) |T| if (reachesAllocation(T)) return true;
    }
    return false;
}

/// Words that mean an allocation in a function body. Those starting with a
/// letter must stand as a whole identifier, or start one (`alloc` matches
/// `allocator` and `allocPrint`, but not `realloc`, listed on its own).
pub const allocating = [_][]const u8{
    // allocators and the heap
    "alloc",  "Alloc",       "realloc",       "malloc",  "calloc",   "gpa", "arena",
    "std.heap",
    // allocating calls on an allocator or a container
    ".create(", ".destroy(", ".free(",       ".dupe(",  ".dupeZ(", ".resize(", ".remap(",
    ".append(", ".appendSlice(", ".insert(", ".put(",   ".getOrPut", ".ensure", ".toOwnedSlice(",
    ".clone(",  ".addOne(",
    // containers that allocate as they grow
    "ArrayList", "ArrayListUnmanaged", "HashMap", "AutoHashMap", "StringHashMap", "ArrayHashMap",
    "MultiArrayList", "SegmentedList", "PriorityQueue", "DoublyLinkedList",
};

/// Words the audio thread must not use, beyond allocation: it must not
/// log or print.
pub const logging = [_][]const u8{ "logging.", "std.log", "std.debug.print", "print(" };

/// The first allocating word in the body of `fn name(` in `source`, or in
/// a same-file function it calls, or null. The body must exist: a renamed
/// function fails loudly rather than passing unchecked.
pub fn allocationIn(source: []const u8, name: []const u8) error{FunctionNotFound}!?[]const u8 {
    return forbiddenIn(source, name, &allocating);
}

/// The first of `words` in the body of `fn name(` in `source`, or in a
/// same-file function it calls, or null. Only the source before its first
/// test is read: test helpers aren't on the path being checked, and would
/// otherwise be taken for the callees they share a name with.
pub fn forbiddenIn(source: []const u8, name: []const u8, words: []const []const u8) error{FunctionNotFound}!?[]const u8 {
    const code = if (std.mem.indexOf(u8, source, "\ntest \"")) |at| source[0..at] else source;
    var seen = Seen{};
    return scan(code, name, words, &seen);
}

const max_functions = 64;
const Seen = struct {
    names: [max_functions][]const u8 = undefined,
    len: usize = 0,

    fn has(self: *const Seen, name: []const u8) bool {
        for (self.names[0..self.len]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

/// The body of `fn name(` in source: from its `{` to the matching `}`,
/// braces in comments and literals left out, or null.
fn body(source: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    const head = while (std.mem.indexOfPos(u8, source, from, "fn ")) |at| {
        const rest = source[at + 3 ..];
        if (std.mem.startsWith(u8, rest, name) and rest.len > name.len and rest[name.len] == '(') break at;
        from = at + 3;
    } else return null;
    const open = std.mem.indexOfScalarPos(u8, source, head, '{') orelse return null;
    var lex = Lexer{ .source = source, .i = open };
    var depth: usize = 0;
    while (lex.next()) |c| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return source[open .. lex.i + 1];
        }
    }
    return null;
}

/// Walks source code a character at a time, stepping over comments, string
/// literals (plain and multiline) and character literals.
const Lexer = struct {
    source: []const u8,
    i: usize,
    started: bool = false,

    /// The next character outside a comment or literal, left at `i`.
    fn next(self: *Lexer) ?u8 {
        if (self.started) self.i += 1;
        self.started = true;
        const s = self.source;
        while (self.i < s.len) {
            const c = s[self.i];
            const two = self.i + 1 < s.len;
            if (c == '/' and two and s[self.i + 1] == '/') {
                self.skipLine();
            } else if (c == '\\' and two and s[self.i + 1] == '\\') {
                self.skipLine(); // a multiline string's line
            } else if (c == '"' or c == '\'') {
                self.skipQuoted(c);
            } else return c;
        }
        return null;
    }

    fn skipLine(self: *Lexer) void {
        while (self.i < self.source.len and self.source[self.i] != '\n') self.i += 1;
    }

    fn skipQuoted(self: *Lexer, quote: u8) void {
        self.i += 1;
        while (self.i < self.source.len) : (self.i += 1) {
            const c = self.source[self.i];
            if (c == '\\') {
                self.i += 1;
            } else if (c == quote or c == '\n') {
                self.i += 1;
                return;
            }
        }
    }
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn resolvesHere(b: []const u8, at: usize) bool {
    if (at == 0) return true;
    if (b[at - 1] == '@') return false;
    if (b[at - 1] != '.') return true;
    for ([_][]const u8{ "self.", "Self." }) |receiver| {
        if (at >= receiver.len and std.mem.eql(u8, b[at - receiver.len .. at], receiver) and
            (at == receiver.len or !isIdent(b[at - receiver.len - 1]))) return true;
    }
    return false;
}

fn scan(source: []const u8, name: []const u8, words: []const []const u8, seen: *Seen) error{FunctionNotFound}!?[]const u8 {
    const b = body(source, name) orelse return error.FunctionNotFound;
    if (seen.len < max_functions) {
        seen.names[seen.len] = name;
        seen.len += 1;
    }
    var lex = Lexer{ .source = b, .i = 0 };
    var callees: [max_functions][]const u8 = undefined;
    var n_callees: usize = 0;
    while (lex.next()) |c| {
        const at = lex.i;
        const rest = b[at..];
        const word_start = at == 0 or !isIdent(b[at - 1]);
        for (words) |word| {
            if (!std.mem.startsWith(u8, rest, word)) continue;
            // A word naming an identifier must start one.
            if (isIdent(word[0]) and !word_start) continue;
            return word;
        }
        // A call this file resolves, `name(` or `self.name(` (or
        // `Self.`), to a function it defines: scan that too. A call on any
        // other value is to its own type's function, which may live
        // elsewhere and is checked only if a test names it.
        if (isIdent(c) and word_start and !std.ascii.isDigit(c) and resolvesHere(b, at)) {
            var end = at;
            while (end < b.len and isIdent(b[end])) end += 1;
            if (end < b.len and b[end] == '(' and n_callees < max_functions) {
                callees[n_callees] = b[at..end];
                n_callees += 1;
            }
        }
    }
    for (callees[0..n_callees]) |callee| {
        if (std.mem.eql(u8, callee, "fn") or seen.has(callee)) continue;
        if (body(source, callee) == null) continue; // not this file's
        if (try scan(source, callee, words, seen)) |word| return word;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "an allocator or a growing container is found in a field, behind a pointer, optional or array" {
    const Plain = struct { a: u32, b: [4]f32 };
    const Field = struct { x: u8, gpa: std.mem.Allocator };
    const Nested = struct { inner: struct { p: ?*Field } };
    const InArray = struct { many: [2]Field };
    const Unmanaged = struct { log: std.ArrayList(u8) };
    const Map = struct { m: std.AutoHashMapUnmanaged(u32, u32) };
    try testing.expect(!reachesAllocation(Plain));
    try testing.expect(reachesAllocation(Field));
    try testing.expect(reachesAllocation(Nested));
    try testing.expect(reachesAllocation(InArray));
    try testing.expect(reachesAllocation(Unmanaged));
    try testing.expect(reachesAllocation(Map));
    try testing.expect(!paramsReachAllocation(fn (*Plain, []const f32) void));
    try testing.expect(paramsReachAllocation(fn (*Plain, std.mem.Allocator) void));
    try testing.expect(paramsReachAllocation(fn (*Nested) void));
    try testing.expect(paramsReachAllocation(fn (*Unmanaged) void));
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
    try testing.expectEqualStrings("std.heap", (try allocationIn(src, "dirty")).?);
    try testing.expectEqualStrings("ArrayList", (try allocationIn(src, "grows")).?);
    try testing.expectError(error.FunctionNotFound, allocationIn(src, "missing"));
}

test "an allocator held in a module-level const and passed to an unmanaged container is found" {
    const src =
        \\const gpa = std.heap.page_allocator;
        \\fn tick(self: *Self) void {
        \\    self.log.append(gpa, 0) catch {};
        \\}
        \\fn renamed(self: *Self) void {
        \\    self.log.append(heap_of_mine, 0) catch {};
        \\}
    ;
    try testing.expect((try allocationIn(src, "tick")) != null);
    try testing.expectEqualStrings(".append(", (try allocationIn(src, "renamed")).?);
}

test "an allocation in a function the body calls, in the same file, is found" {
    const src =
        \\fn tick(self: *Self) void {
        \\    self.helper();
        \\    const n = count(3);
        \\    _ = n;
        \\}
        \\fn count(x: u32) u32 {
        \\    return x;
        \\}
        \\fn helper(self: *Self) void {
        \\    deeper(self);
        \\}
        \\fn deeper(self: *Self) void {
        \\    const p = std.heap.c_allocator.create(u8) catch return;
        \\    _ = p;
        \\}
    ;
    try testing.expectEqualStrings("std.heap", (try allocationIn(src, "tick")).?);
    try testing.expectEqual(@as(?[]const u8, null), try allocationIn(src, "count"));
}

test "a brace or a comment marker in a literal doesn't end the scan early" {
    const src =
        \\fn tick() void {
        \\    const close = "}";
        \\    const brace = '}';
        \\    const url = "http://example";
        \\    _ = .{ close, brace, url };
        \\    _ = std.heap.page_allocator.alloc(u8, 1) catch {};
        \\}
        \\fn wordy() void {
        \\    log("an alloc in a string is no allocation");
        \\}
    ;
    try testing.expectEqualStrings("std.heap", (try allocationIn(src, "tick")).?);
    try testing.expectEqual(@as(?[]const u8, null), try allocationIn(src, "wordy"));
}

test "identifier words match only where an identifier starts" {
    const src =
        \\fn ok() void {
        \\    const recall_count = 1;
        \\    recall(recall_count);
        \\}
        \\fn bad() void {
        \\    _ = std.c.realloc(null, 4);
        \\}
    ;
    try testing.expectEqual(@as(?[]const u8, null), try allocationIn(src, "ok"));
    try testing.expectEqualStrings("realloc", (try allocationIn(src, "bad")).?);
}

test "logging is found by its own word list" {
    const src =
        \\fn process() void {
        \\    logging.debug("x", .{});
        \\}
    ;
    try testing.expectEqualStrings("logging.", (try forbiddenIn(src, "process", &logging)).?);
}

test "functions after the file's first test are not followed" {
    const src =
        \\fn tick(self: *Self) void {
        \\    self.analyser.init(1);
        \\}
        \\test "a helper" {}
        \\fn init() void {
        \\    _ = std.testing.allocator.create(u8);
        \\}
    ;
    try testing.expectEqual(@as(?[]const u8, null), try allocationIn(src, "tick"));
}

test "a call on another value isn't followed into a same-named function here" {
    const src =
        \\fn tick(self: *Self) void {
        \\    self.analyser.init(1);
        \\    self.ring.reset();
        \\}
        \\const Rig = struct {
        \\    fn init() void {
        \\        _ = std.testing.allocator.create(u8);
        \\    }
        \\};
    ;
    try testing.expectEqual(@as(?[]const u8, null), try allocationIn(src, "tick"));
}
