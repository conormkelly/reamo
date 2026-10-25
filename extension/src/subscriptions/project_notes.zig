const std = @import("std");
const reaper = @import("../reaper.zig");

const Allocator = std.mem.Allocator;

/// Maximum buffer size for project notes (64KB ceiling per research)
pub const MAX_NOTES_SIZE: usize = 65536;

/// Buffer size for initial fetch (will grow if needed)
const INITIAL_BUFFER_SIZE: usize = 4096;

/// Manages project notes subscriptions and change detection.
/// Tracks which clients want notes updates and detects changes via hashing.
pub const NotesSubscriptions = struct {
    allocator: Allocator,

    /// Set of subscribed client IDs
    subscribers: std.AutoHashMap(usize, void),

    /// Hash of the notes subscribers were last told about. Only poll()
    /// advances it, by broadcasting the change: a snapshot taken for one
    /// client (subscribe, set) must not, or the change never reaches the
    /// others.
    last_hash: u64,

    /// Notes are read into this (MAX_NOTES_SIZE, allocated on first use)
    /// rather than onto the timer callback's stack.
    read_buf: ?[]u8,

    pub fn init(allocator: Allocator) NotesSubscriptions {
        return .{
            .allocator = allocator,
            .subscribers = std.AutoHashMap(usize, void).init(allocator),
            .last_hash = 0,
            .read_buf = null,
        };
    }

    pub fn deinit(self: *NotesSubscriptions) void {
        self.subscribers.deinit();
        if (self.read_buf) |buf| self.allocator.free(buf);
    }

    /// Subscribe a client to notes updates. The first subscriber sets the
    /// baseline: nothing was being watched before it, so nothing is missed.
    pub fn subscribe(self: *NotesSubscriptions, api: anytype, client_id: usize) !void {
        const first = !self.hasSubscribers();
        try self.subscribers.put(client_id, {});
        if (first) {
            if (self.readNotes(api)) |notes| self.last_hash = computeHash(notes);
        }
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

    fn readNotes(self: *NotesSubscriptions, api: anytype) ?[]const u8 {
        if (self.read_buf == null) self.read_buf = self.allocator.alloc(u8, MAX_NOTES_SIZE) catch return null;
        return api.getProjectNotes(self.read_buf.?);
    }

    /// Poll for notes changes, from REAPER or from any client. Returns the
    /// change to broadcast to subscribers, or null. Only polls REAPER if
    /// there are subscribers.
    pub fn poll(self: *NotesSubscriptions, api: anytype) ?NotesChange {
        if (!self.hasSubscribers()) return null;
        const notes = self.readNotes(api) orelse return null;
        const new_hash = computeHash(notes);
        if (new_hash == self.last_hash) return null;
        const old_hash = self.last_hash;
        self.last_hash = new_hash;
        return .{ .hash = new_hash, .old_hash = old_hash };
    }

    /// Current notes and hash, for one client's response. Valid until the
    /// next read; does not affect change detection.
    pub fn getCurrentNotes(self: *NotesSubscriptions, api: anytype) ?NotesSnapshot {
        const notes = self.readNotes(api) orelse return null;
        return .{ .notes = notes, .hash = computeHash(notes) };
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

/// Prepare notes for REAPER: strip NUL bytes and normalize newlines to
/// \r\n. Everything else is kept as typed; REAPER stores and reloads lines
/// starting with |, < or > intact itself.
pub fn sanitizeNotes(input: []const u8, output: []u8) []const u8 {
    var out_idx: usize = 0;

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
            continue;
        }

        // Skip lone \r (will be added with \n)
        if (c == '\r') continue;

        output[out_idx] = c;
        out_idx += 1;
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

test "sanitizeNotes keeps lines starting with |, < and > as typed" {
    var output: [256]u8 = undefined;
    const result = sanitizeNotes("Normal text\n| bar 12 tacet\n<intro> x2\n> fade\nMore text", &output);
    try std.testing.expectEqualStrings("Normal text\r\n| bar 12 tacet\r\n<intro> x2\r\n> fade\r\nMore text", result);
}

test "NotesSubscriptions init and deinit" {
    var subs = NotesSubscriptions.init(std.testing.allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscribers());
}

test "NotesSubscriptions subscribe and unsubscribe" {
    var subs = NotesSubscriptions.init(std.testing.allocator);
    defer subs.deinit();

    var mock = reaper.MockBackend{};
    try subs.subscribe(&mock, 1);
    try std.testing.expect(subs.hasSubscribers());
    try std.testing.expectEqual(@as(usize, 1), subs.subscriberCount());

    try subs.subscribe(&mock, 2);
    try std.testing.expectEqual(@as(usize, 2), subs.subscriberCount());

    subs.unsubscribe(1);
    try std.testing.expectEqual(@as(usize, 1), subs.subscriberCount());

    subs.removeClient(2);
    try std.testing.expect(!subs.hasSubscribers());
}

test "a change saved by one client is reported to the others" {
    var subs = NotesSubscriptions.init(std.testing.allocator);
    defer subs.deinit();
    var mock = reaper.MockBackend{};
    try subs.subscribe(&mock, 1);
    try subs.subscribe(&mock, 2);
    try std.testing.expect(subs.poll(&mock) == null);

    // Client 1 saves; its own response reads the notes back.
    mock.setProjectNotes("Setlist\r\n1. Intro");
    _ = subs.getCurrentNotes(&mock);
    // A third client subscribing in the same second must not swallow it either.
    try subs.subscribe(&mock, 3);

    const change = subs.poll(&mock) orelse return error.ChangeNotReported;
    try std.testing.expectEqual(computeHash("Setlist\r\n1. Intro"), change.hash);
    try std.testing.expect(subs.poll(&mock) == null);
}
