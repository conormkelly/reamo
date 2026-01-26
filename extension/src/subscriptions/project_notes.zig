const std = @import("std");
const reaper = @import("../reaper.zig");

const Allocator = std.mem.Allocator;

/// Maximum buffer size for project notes (64KB ceiling per research)
pub const MAX_NOTES_SIZE: usize = 65536;

/// Buffer size for initial fetch (will grow if needed)
const INITIAL_BUFFER_SIZE: usize = 4096;

/// Manages project notes subscriptions and change detection.
/// Tracks which clients want notes updates and detects external changes via hashing.
pub const NotesSubscriptions = struct {
    allocator: Allocator,

    /// Set of subscribed client IDs
    subscribers: std.AutoHashMap(usize, void),

    /// Hash of last known notes content (for change detection)
    last_hash: u64,

    /// Cached notes content (owned memory)
    cached_notes: ?[]u8,

    pub fn init(allocator: Allocator) NotesSubscriptions {
        return .{
            .allocator = allocator,
            .subscribers = std.AutoHashMap(usize, void).init(allocator),
            .last_hash = 0,
            .cached_notes = null,
        };
    }

    pub fn deinit(self: *NotesSubscriptions) void {
        self.subscribers.deinit();
        if (self.cached_notes) |notes| {
            self.allocator.free(notes);
        }
    }

    /// Subscribe a client to notes updates
    pub fn subscribe(self: *NotesSubscriptions, client_id: usize) !void {
        try self.subscribers.put(client_id, {});
    }

    /// Unsubscribe a client from notes updates
    pub fn unsubscribe(self: *NotesSubscriptions, client_id: usize) void {
        _ = self.subscribers.remove(client_id);
    }

    /// Remove client (called on disconnect)
    pub fn removeClient(self: *NotesSubscriptions, client_id: usize) void {
        self.unsubscribe(client_id);
    }

    /// Check if any clients are subscribed
    pub fn hasSubscribers(self: *const NotesSubscriptions) bool {
        return self.subscribers.count() > 0;
    }

    /// Get subscriber count
    pub fn subscriberCount(self: *const NotesSubscriptions) usize {
        return self.subscribers.count();
    }

    /// Poll for notes changes. Returns new hash if changed, null otherwise.
    /// Only polls REAPER if there are subscribers.
    pub fn poll(self: *NotesSubscriptions, api: anytype) ?NotesChange {
        if (!self.hasSubscribers()) return null;

        // Get current notes
        var buf: [MAX_NOTES_SIZE]u8 = undefined;
        const notes = api.getProjectNotes(&buf) orelse return null;

        // Compute hash
        const new_hash = computeHash(notes);

        // Check if changed
        if (new_hash == self.last_hash) return null;

        // Notes changed - update cache
        const old_hash = self.last_hash;
        self.last_hash = new_hash;

        // Update cached notes
        if (self.cached_notes) |old| {
            self.allocator.free(old);
        }
        self.cached_notes = self.allocator.dupe(u8, notes) catch null;

        return .{
            .hash = new_hash,
            .old_hash = old_hash,
        };
    }

    /// Get current notes and hash (for subscribe response)
    pub fn getCurrentNotes(self: *NotesSubscriptions, api: anytype) ?NotesSnapshot {
        var buf: [MAX_NOTES_SIZE]u8 = undefined;
        const notes = api.getProjectNotes(&buf) orelse return null;

        const hash = computeHash(notes);

        // Update our tracking
        self.last_hash = hash;
        if (self.cached_notes) |old| {
            self.allocator.free(old);
        }
        self.cached_notes = self.allocator.dupe(u8, notes) catch null;

        // Return the heap-allocated copy, not the stack buffer
        return .{
            .notes = self.cached_notes orelse return null,
            .hash = hash,
        };
    }

    /// Get cached notes (may be null if never fetched)
    pub fn getCachedNotes(self: *const NotesSubscriptions) ?[]const u8 {
        return self.cached_notes;
    }

    /// Get last known hash
    pub fn getLastHash(self: *const NotesSubscriptions) u64 {
        return self.last_hash;
    }
};

/// Represents a change in notes content
pub const NotesChange = struct {
    hash: u64,
    old_hash: u64,
};

/// Snapshot of notes for subscribe response
pub const NotesSnapshot = struct {
    notes: []const u8,
    hash: u64,
};

/// Compute hash of notes content using Wyhash
pub fn computeHash(notes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, notes);
}

/// Format hash as hex string for JSON
pub fn hashToHex(hash: u64, buf: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{hash}) catch "0000000000000000";
}

/// Sanitize notes for safe storage in REAPER
/// - Strips null bytes
/// - Normalizes newlines to \r\n
/// - Escapes problematic characters at line starts
pub fn sanitizeNotes(input: []const u8, output: []u8) []const u8 {
    var out_idx: usize = 0;
    var at_line_start = true;

    for (input) |c| {
        if (out_idx >= output.len - 1) break;

        // Skip null bytes
        if (c == 0) continue;

        // Handle newlines - normalize to \r\n
        if (c == '\n') {
            if (out_idx > 0 and output[out_idx - 1] != '\r') {
                if (out_idx < output.len - 2) {
                    output[out_idx] = '\r';
                    out_idx += 1;
                }
            }
            output[out_idx] = '\n';
            out_idx += 1;
            at_line_start = true;
            continue;
        }

        // Skip lone \r (will be added with \n)
        if (c == '\r') continue;

        // Escape problematic chars at line start (|, <, >)
        if (at_line_start and (c == '|' or c == '<' or c == '>')) {
            if (out_idx < output.len - 2) {
                output[out_idx] = ' '; // Prepend space
                out_idx += 1;
            }
        }

        output[out_idx] = c;
        out_idx += 1;
        at_line_start = false;
    }

    return output[0..out_idx];
}

// Tests
test "computeHash produces consistent results" {
    const hash1 = computeHash("Hello, World!");
    const hash2 = computeHash("Hello, World!");
    const hash3 = computeHash("Different content");

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
}

test "hashToHex formats correctly" {
    var buf: [16]u8 = undefined;
    const hex = hashToHex(0x123456789ABCDEF0, &buf);
    try std.testing.expectEqualStrings("123456789abcdef0", hex);
}

test "sanitizeNotes strips null bytes" {
    var output: [256]u8 = undefined;
    const result = sanitizeNotes("Hello\x00World", &output);
    try std.testing.expectEqualStrings("HelloWorld", result);
}

test "sanitizeNotes normalizes newlines" {
    var output: [256]u8 = undefined;
    const result = sanitizeNotes("Line1\nLine2", &output);
    try std.testing.expectEqualStrings("Line1\r\nLine2", result);
}

test "sanitizeNotes escapes pipe at line start" {
    var output: [256]u8 = undefined;
    const result = sanitizeNotes("|pipe at start", &output);
    try std.testing.expectEqualStrings(" |pipe at start", result);
}

test "sanitizeNotes escapes angle brackets at line start" {
    var output: [256]u8 = undefined;
    const result1 = sanitizeNotes("<tag>", &output);
    try std.testing.expectEqualStrings(" <tag>", result1);

    const result2 = sanitizeNotes(">arrow", &output);
    try std.testing.expectEqualStrings(" >arrow", result2);
}

test "sanitizeNotes handles complex input" {
    var output: [256]u8 = undefined;
    const result = sanitizeNotes("Normal text\n|piped\n<angled>\nMore text", &output);
    try std.testing.expectEqualStrings("Normal text\r\n |piped\r\n <angled>\r\nMore text", result);
}

test "NotesSubscriptions init and deinit" {
    var subs = NotesSubscriptions.init(std.testing.allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscribers());
}

test "NotesSubscriptions subscribe and unsubscribe" {
    var subs = NotesSubscriptions.init(std.testing.allocator);
    defer subs.deinit();

    try subs.subscribe(1);
    try std.testing.expect(subs.hasSubscribers());
    try std.testing.expectEqual(@as(usize, 1), subs.subscriberCount());

    try subs.subscribe(2);
    try std.testing.expectEqual(@as(usize, 2), subs.subscriberCount());

    subs.unsubscribe(1);
    try std.testing.expectEqual(@as(usize, 1), subs.subscriberCount());

    subs.removeClient(2);
    try std.testing.expect(!subs.hasSubscribers());
}
