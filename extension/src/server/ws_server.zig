const std = @import("std");
const websocket = @import("httpz").websocket;
const logging = @import("../core/logging.zig");


const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// Commands waiting for the main thread, which drains them all every tick.
// A phone that loses Wi-Fi for a few seconds can deliver a pad roll's worth
// at once; past these limits a command is refused, never dropped silently.
const MAX_COMMAND_QUEUE = 4096;
const MAX_QUEUED_COMMAND_BYTES = 8 * 1024 * 1024;

/// How long a WebSocket has to complete its hello before it is ended with
/// HELLO_TIMEOUT_CODE. Every connection, HTTP or WebSocket, holds one of the
/// server's connection slots (http_server.zig's max_conn), so sockets that
/// upgrade and then say nothing could otherwise hold them all and lock every
/// phone out.
///
/// The web app sends its hello the moment the socket opens, and abandons the
/// attempt itself if the socket isn't open within its CONNECT_TIMEOUT (5 s)
/// or the hello isn't answered within its HELLO_TIMEOUT (5 s, from the open;
/// both in frontend/src/core/websocketMachine.ts). The deadline counts from
/// the main thread's first tick to see the socket, which is no earlier than
/// the server sending the 101. The 101 reached the phone within 5 s of that
/// or the phone gave up; the hello then reached the server within 5 s or the
/// phone gave up waiting for the answer. So in 10 s the deadline never ends
/// a socket the web app would still have kept, however slow its network. A
/// page frozen in the background before it can send its hello reconnects
/// when it wakes, as after any other close.
///
/// While REAPER's main thread is held up (a modal dialog run by a command),
/// no tick sees new sockets, so the deadline starts only once it runs again.
pub const HELLO_DEADLINE_NS: u64 = 10 * std.time.ns_per_s;
pub const HELLO_TIMEOUT_CODE: u16 = 4003;

// Session token length (hex string = 32 chars for 16 bytes)
const TOKEN_HEX_LENGTH = 32;

// Command received from a client
pub const Command = struct {
    client_id: usize,
    data: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Command) void {
        self.allocator.free(self.data);
    }
};

// Ring buffer for commands - O(1) push and pop
const CommandRingBuffer = struct {
    /// Allocated on the first push, so SharedState (built by value) stays small.
    items: []Command = &.{},
    head: usize = 0, // Next position to read from
    tail: usize = 0, // Next position to write to
    len: usize = 0,
    bytes: usize = 0, // Total data bytes queued

    fn push(self: *CommandRingBuffer, allocator: Allocator, cmd: Command) !void {
        if (self.len >= MAX_COMMAND_QUEUE) return error.QueueFull;
        if (cmd.data.len > MAX_QUEUED_COMMAND_BYTES - self.bytes) return error.QueueFull;
        if (self.items.len == 0) self.items = try allocator.alloc(Command, MAX_COMMAND_QUEUE);
        self.items[self.tail] = cmd;
        self.tail = (self.tail + 1) % MAX_COMMAND_QUEUE;
        self.len += 1;
        self.bytes += cmd.data.len;
    }

    fn pop(self: *CommandRingBuffer) ?Command {
        if (self.len == 0) return null;
        const cmd = self.items[self.head];
        self.head = (self.head + 1) % MAX_COMMAND_QUEUE;
        self.len -= 1;
        self.bytes -= cmd.data.len;
        return cmd;
    }

    fn deinit(self: *CommandRingBuffer, allocator: Allocator) void {
        if (self.items.len > 0) allocator.free(self.items);
        self.* = .{};
    }

    // For cleanup - iterate remaining items
    fn remaining(self: *CommandRingBuffer) RemainingIterator {
        return .{ .ring = self, .count = 0 };
    }

    const RemainingIterator = struct {
        ring: *CommandRingBuffer,
        count: usize,

        fn next(self: *RemainingIterator) ?*Command {
            if (self.count >= self.ring.len) return null;
            const idx = (self.ring.head + self.count) % MAX_COMMAND_QUEUE;
            self.count += 1;
            return &self.ring.items[idx];
        }
    };
};

// Function pointer type for high-precision timing (thread-safe read-only)
pub const TimePreciseFn = *const fn () callconv(.c) f64;

// Shared state between WebSocket thread and main thread
//
// Fine-grained locking strategy:
// - command_mutex: Dedicated lock for command queue (SPSC pattern)
// - client_rwlock: RwLock for client map (read-heavy during broadcasts)
// - Atomics for simple values (token_set, html_mtime, time_precise_fn)
//
// This reduces contention vs a single mutex at 30Hz polling frequency.
pub const SharedState = struct {
    allocator: Allocator,

    // Command queue: WebSocket thread pushes, main thread pops
    // Dedicated mutex for SPSC pattern - no contention with client operations
    command_mutex: Thread.Mutex = .{},
    commands: CommandRingBuffer = .{},

    // Rate-limited error tracking for WebSocket write failures
    // Logs first failure, then every LOG_INTERVAL failures to avoid spam
    // Uses atomics since we hold only shared lock during broadcast
    write_error_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    last_error_log_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Connected clients for broadcasting - store Conn pointers directly
    // The websocket library manages Conn lifetime, and Conn.writeText is thread-safe
    // RwLock allows concurrent reads during broadcast while serializing writes
    client_rwlock: Thread.RwLock = .{},
    clients: std.AutoArrayHashMap(usize, *websocket.Conn),
    next_client_id: usize = 1,

    // Clients that completed the hello handshake (token checked). Only these
    // receive broadcasts: a socket that never presented the session token
    // must not see project names, paths, track or marker names.
    // Protected by client_rwlock.
    handshaken_clients: std.AutoArrayHashMap(usize, void),

    // Clients that haven't said hello yet, each with when the main thread
    // first saw it (null until then). endClientsPastHelloDeadline ends those
    // past the deadline. Every instant comes from the main thread, so they
    // never run backwards against its `now`. Protected by client_rwlock.
    awaiting_hello: std.AutoArrayHashMap(usize, ?std.time.Instant),
    // Main thread only: hello-deadline closes not yet logged, and when the
    // last were. A host reconnecting in a loop would otherwise fill the log.
    hello_timeouts_unlogged: usize = 0,
    hello_timeouts_logged_at: ?std.time.Instant = null,

    // Clients that need initial state snapshot (set by WS thread after hello, consumed by main thread)
    // Protected by client_rwlock since closely related to client lifecycle
    clients_needing_snapshot: std.AutoArrayHashMap(usize, void),

    // Clients that have disconnected (set by WS thread, consumed by main thread for gesture cleanup)
    // Protected by client_rwlock since closely related to client lifecycle
    disconnected_clients: std.AutoArrayHashMap(usize, void),

    // Session token for authentication (hex string)
    // Set once at startup before any connections, then read-only
    // Atomic flag with release/acquire semantics ensures token value visibility
    session_token: [TOKEN_HEX_LENGTH]u8 = undefined,
    token_set: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // HTML file mtime for hot reload (set by main thread, read by WS thread for hello response)
    // Uses i64 (not i128) because 128-bit atomics aren't available on x86_64 Windows.
    // i64 nanoseconds covers dates through year 2262, and the protocol truncates to seconds anyway.
    html_mtime: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // High-precision timing function for clock sync
    // Uses typed atomic for function pointer safety (main thread writes, WS thread reads)
    time_precise_fn: std.atomic.Value(?TimePreciseFn) = std.atomic.Value(?TimePreciseFn).init(null),

    pub fn init(allocator: Allocator) SharedState {
        return .{
            .allocator = allocator,
            .clients = std.AutoArrayHashMap(usize, *websocket.Conn).init(allocator),
            .clients_needing_snapshot = std.AutoArrayHashMap(usize, void).init(allocator),
            .handshaken_clients = std.AutoArrayHashMap(usize, void).init(allocator),
            .awaiting_hello = std.AutoArrayHashMap(usize, ?std.time.Instant).init(allocator),
            .disconnected_clients = std.AutoArrayHashMap(usize, void).init(allocator),
        };
    }

    // Set the session token (called by main.zig on startup, before any connections)
    // Uses release semantics to ensure token value is visible when flag is read
    pub fn setToken(self: *SharedState, token: []const u8) void {
        const len = @min(token.len, TOKEN_HEX_LENGTH);
        @memcpy(self.session_token[0..len], token[0..len]);
        // Release ensures the memcpy above is visible to any thread that sees token_set=true
        self.token_set.store(true, .release);
    }

    // Get the session token if set (for injection into HTML).
    // Uses acquire semantics to synchronize with setToken's release.
    pub fn getToken(self: *SharedState) ?[]const u8 {
        if (!self.token_set.load(.acquire)) return null;
        return &self.session_token;
    }

    // Validate a token (called during hello handshake from WS thread)
    // Uses acquire semantics to synchronize with setToken's release
    pub fn validateToken(self: *SharedState, token: ?[]const u8) bool {
        // Acquire ensures we see the token value written before the flag was set
        if (!self.token_set.load(.acquire)) return true;

        const t = token orelse return false;
        if (t.len != TOKEN_HEX_LENGTH) return false;

        return std.mem.eql(u8, t, &self.session_token);
    }

    // Update the HTML mtime (called by main thread when file changes)
    // Uses atomic store - no mutex needed for simple value
    pub fn setHtmlMtime(self: *SharedState, mtime: i128) void {
        self.html_mtime.store(@intCast(mtime), .release);
    }

    // Set the time_precise function pointer (called by main thread on startup)
    // Uses atomic release to ensure visibility to WebSocket thread
    pub fn setTimePreciseFn(self: *SharedState, func: TimePreciseFn) void {
        self.time_precise_fn.store(func, .release);
    }

    // Get high-precision time in milliseconds (thread-safe, for clock sync)
    // Uses atomic acquire to synchronize with main thread's release
    pub fn timePreciseMs(self: *SharedState) f64 {
        if (self.time_precise_fn.load(.acquire)) |func| {
            return func() * 1000.0;
        }
        return 0;
    }

    // Get the HTML mtime (called by WS thread for hello response)
    // Uses atomic load - no mutex needed for simple value
    pub fn getHtmlMtime(self: *SharedState) i64 {
        return self.html_mtime.load(.acquire);
    }

    // Log WebSocket write errors with rate limiting (max once per 5 seconds)
    // Called from broadcast/sendToClient when writeText fails
    pub fn logWriteError(self: *SharedState, err: anyerror) void {
        const count = self.write_error_count.fetchAdd(1, .monotonic) + 1;
        const now = std.time.milliTimestamp();
        const last = self.last_error_log_time.load(.monotonic);

        // Log on first error, or if 5+ seconds have passed since last log
        const should_log = (count == 1) or (now - last >= 5000);
        if (should_log) {
            // Try to update last log time (may race with another thread, that's OK)
            _ = self.last_error_log_time.cmpxchgStrong(last, now, .monotonic, .monotonic);
            logging.warn("WebSocket write error (count={d}): {}", .{ count, err });
        }
    }

    pub fn deinit(self: *SharedState) void {
        // Clean up any pending commands
        var iter = self.commands.remaining();
        while (iter.next()) |cmd| {
            cmd.deinit();
        }
        self.commands.deinit(self.allocator);
        self.clients.deinit();
        self.clients_needing_snapshot.deinit();
        self.handshaken_clients.deinit();
        self.awaiting_hello.deinit();
        self.disconnected_clients.deinit();
    }

    /// Called by the WebSocket thread on a valid hello, before answering it.
    /// True if it beat the deadline: the client no longer has one. False if
    /// the deadline has already ended the connection, so the hello is too late.
    pub fn takeHelloInTime(self: *SharedState, client_id: usize) bool {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();
        return self.awaiting_hello.swapRemove(client_id);
    }

    // Called by WebSocket thread after successful hello: the client may now
    // receive broadcasts, and needs an initial snapshot
    pub fn markNeedsSnapshot(self: *SharedState, client_id: usize) void {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();
        self.handshaken_clients.put(client_id, {}) catch |e| {
            logging.warn("markNeedsSnapshot: client {d} not registered for broadcasts: {}", .{ client_id, e });
        };
        self.clients_needing_snapshot.put(client_id, {}) catch |e| {
            logging.warn("markNeedsSnapshot failed for client {d}: {} - client won't receive initial state", .{ client_id, e });
        };
    }

    // Called by main thread to get and clear clients needing snapshots
    // Returns client IDs in a static buffer (caller should process immediately)
    pub fn popClientsNeedingSnapshot(self: *SharedState, out_buf: []usize) usize {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();

        var count: usize = 0;
        for (self.clients_needing_snapshot.keys()) |client_id| {
            if (count >= out_buf.len) break;
            out_buf[count] = client_id;
            count += 1;
        }
        self.clients_needing_snapshot.clearRetainingCapacity();
        return count;
    }

    // Called by WebSocket thread to register a new client, which then has
    // until the hello deadline to say hello.
    // Returns null if allocation fails (OOM) - caller should close connection
    pub fn addClient(self: *SharedState, conn: *websocket.Conn) ?usize {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();

        const id = self.next_client_id;
        self.next_client_id += 1;
        // Room in both maps first: a client the deadline can't track is refused.
        self.clients.ensureUnusedCapacity(1) catch |e| {
            logging.err("CLIENT ADD FAILED id={d}: {}", .{ id, e });
            return null;
        };
        self.awaiting_hello.ensureUnusedCapacity(1) catch |e| {
            logging.err("CLIENT ADD FAILED id={d}: {}", .{ id, e });
            return null;
        };
        self.clients.putAssumeCapacity(id, conn);
        self.awaiting_hello.putAssumeCapacity(id, null);
        logging.debug("Socket {d} opened ({d} open)", .{ id, self.clients.count() });
        return id;
    }

    // Called by WebSocket thread when client disconnects
    pub fn removeClient(self: *SharedState, id: usize) void {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();
        _ = self.clients.swapRemove(id);
        _ = self.handshaken_clients.swapRemove(id);
        _ = self.awaiting_hello.swapRemove(id);
        // Track disconnected client for gesture cleanup by main thread
        self.disconnected_clients.put(id, {}) catch |e| {
            logging.warn("Failed to track disconnected client {d}: {} - gesture cleanup may be incomplete", .{ id, e });
        };
        logging.debug("Socket {d} closed ({d} open)", .{ id, self.clients.count() });
    }

    // Called by main thread to get and clear disconnected clients
    // Used for cleaning up active gestures when clients disconnect
    pub fn popDisconnectedClients(self: *SharedState, out_buf: []usize) usize {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();

        var count: usize = 0;
        for (self.disconnected_clients.keys()) |client_id| {
            if (count >= out_buf.len) break;
            out_buf[count] = client_id;
            count += 1;
        }
        self.disconnected_clients.clearRetainingCapacity();
        return count;
    }

    // Called by WebSocket thread to queue a command for main thread
    // Uses dedicated command_mutex for SPSC queue access
    pub fn pushCommand(self: *SharedState, client_id: usize, data: []const u8) bool {
        // Allocate outside lock to minimize critical section
        const data_copy = self.allocator.dupe(u8, data) catch return false;

        self.command_mutex.lock();
        defer self.command_mutex.unlock();

        self.commands.push(self.allocator, .{
            .client_id = client_id,
            .data = data_copy,
            .allocator = self.allocator,
        }) catch {
            self.allocator.free(data_copy);
            return false;
        };

        return true;
    }

    // Called by main thread to get pending commands
    // Uses dedicated command_mutex for SPSC queue access
    pub fn popCommand(self: *SharedState) ?Command {
        self.command_mutex.lock();
        defer self.command_mutex.unlock();
        return self.commands.pop();
    }

    // Called by main thread to broadcast to all clients
    // Uses RwLock read lock since we're only iterating, not modifying
    // Must hold lock while writing to prevent use-after-free if client disconnects
    pub fn broadcast(self: *SharedState, message: []const u8) void {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();

        // writeText is thread-safe within the websocket library
        for (self.clients.keys(), self.clients.values()) |id, conn| {
            if (!self.handshaken_clients.contains(id)) continue;
            conn.writeText(message) catch |err| self.logWriteError(err);
        }
    }

    // Called by main thread to send to a specific client only
    // Uses RwLock read lock since we're only reading the map, not modifying
    // Must hold lock while writing to prevent use-after-free if client disconnects
    pub fn sendToClient(self: *SharedState, client_id: usize, message: []const u8) void {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();

        if (self.clients.get(client_id)) |conn| {
            conn.writeText(message) catch |err| self.logWriteError(err);
        }
    }

    // Called by main thread to send state a client subscribed to: as with
    // broadcast, only a client that completed the hello handshake receives it.
    // Returns whether the client is connected and handshaken.
    pub fn sendToHandshakenClient(self: *SharedState, client_id: usize, message: []const u8) bool {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();

        if (!self.handshaken_clients.contains(client_id)) return false;
        const conn = self.clients.get(client_id) orelse return false;
        conn.writeText(message) catch |err| self.logWriteError(err);
        return true;
    }

    /// Send a binary frame to a specific client (for audio streaming).
    /// Same locking pattern as sendToClient but uses writeBin for binary frames.
    pub fn sendBinToClient(self: *SharedState, client_id: usize, data: []const u8) void {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();

        if (self.clients.get(client_id)) |conn| {
            conn.writeBin(data) catch |err| self.logWriteError(err);
        }
    }

    /// Send output queued behind clients' full sockets (a phone on slow
    /// Wi-Fi or backgrounded mid-stream). Never blocks; called every tick.
    pub fn flushPendingOutput(self: *SharedState) void {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();
        for (self.clients.values()) |conn| {
            conn.flushPending() catch |err| self.logWriteError(err);
        }
    }

    /// Called by the main thread every tick: ends, with HELLO_TIMEOUT_CODE,
    /// each client that hasn't said hello within `deadline_ns` of the first
    /// call to see it. `now` must come from the main thread's monotonic
    /// clock: a later call's never earlier than an earlier call's.
    pub fn endClientsPastHelloDeadline(self: *SharedState, now: std.time.Instant, deadline_ns: u64) void {
        var ended: usize = 0;
        {
            self.client_rwlock.lock();
            defer self.client_rwlock.unlock();
            var i: usize = 0;
            while (i < self.awaiting_hello.count()) {
                const seen = &self.awaiting_hello.values()[i];
                const first_seen = seen.* orelse {
                    seen.* = now;
                    i += 1;
                    continue;
                };
                if (now.since(first_seen) < deadline_ns) {
                    i += 1;
                    continue;
                }
                const id = self.awaiting_hello.keys()[i];
                self.awaiting_hello.swapRemoveAt(i);
                // end(), not close(): this isn't the connection's own thread.
                // Its worker sees the end and closes the connection, which
                // calls removeClient and frees the slot.
                const conn = self.clients.get(id) orelse continue;
                conn.end(.{ .code = HELLO_TIMEOUT_CODE, .reason = "No hello in time" }) catch |err| {
                    logging.debug("Socket {d}: hello deadline's close frame not sent: {s}", .{ id, @errorName(err) });
                };
                ended += 1;
            }
        }
        self.logHelloTimeouts(now, ended);
    }

    /// At most one line every 5 s, counting every close since the last.
    fn logHelloTimeouts(self: *SharedState, now: std.time.Instant, ended: usize) void {
        self.hello_timeouts_unlogged += ended;
        if (self.hello_timeouts_unlogged == 0) return;
        if (self.hello_timeouts_logged_at) |at| {
            if (now.since(at) < 5 * std.time.ns_per_s) return;
        }
        logging.info("Closed {d} connection(s) that didn't say hello within {d} s: a page that couldn't finish connecting, or something holding connections open", .{ self.hello_timeouts_unlogged, HELLO_DEADLINE_NS / std.time.ns_per_s });
        self.hello_timeouts_unlogged = 0;
        self.hello_timeouts_logged_at = now;
    }

    // Get client count (for logging)
    // Uses RwLock read lock since we're only reading
    pub fn clientCount(self: *SharedState) usize {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();
        return self.clients.count();
    }
};

// Tests
test "CommandRingBuffer push and pop" {
    var ring = CommandRingBuffer{};
    defer ring.deinit(std.testing.allocator);

    // Test commands borrow static data; nothing to free per command.
    try ring.push(std.testing.allocator, .{ .client_id = 1, .data = "test1", .allocator = std.testing.allocator });
    try ring.push(std.testing.allocator, .{ .client_id = 2, .data = "test2", .allocator = std.testing.allocator });
    try std.testing.expectEqual(@as(usize, 10), ring.bytes);

    try std.testing.expectEqual(@as(usize, 1), ring.pop().?.client_id);
    try std.testing.expectEqual(@as(usize, 2), ring.pop().?.client_id);
    try std.testing.expect(ring.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), ring.bytes);
}

test "CommandRingBuffer wraps around" {
    var ring = CommandRingBuffer{};
    defer ring.deinit(std.testing.allocator);

    for (0..MAX_COMMAND_QUEUE - 5) |i| {
        try ring.push(std.testing.allocator, .{ .client_id = i, .data = "", .allocator = std.testing.allocator });
    }
    for (0..MAX_COMMAND_QUEUE - 10) |_| {
        _ = ring.pop();
    }
    // Push past the end of the storage (wraps)
    for (MAX_COMMAND_QUEUE - 5..MAX_COMMAND_QUEUE + 10) |i| {
        try ring.push(std.testing.allocator, .{ .client_id = i, .data = "", .allocator = std.testing.allocator });
    }
    for (MAX_COMMAND_QUEUE - 10..MAX_COMMAND_QUEUE + 10) |i| {
        try std.testing.expectEqual(i, ring.pop().?.client_id);
    }
}

test "a burst of pad hits from a phone back on Wi-Fi fits in the queue" {
    var ring = CommandRingBuffer{};
    defer ring.deinit(std.testing.allocator);
    // Three seconds of a pad roll at 100 hits/s, note-on and note-off each.
    const hit = "{\"type\":\"command\",\"command\":\"midi/noteOn\",\"note\":36,\"velocity\":100,\"channel\":9}";
    for (0..600) |i| {
        try ring.push(std.testing.allocator, .{ .client_id = i, .data = hit, .allocator = std.testing.allocator });
    }
}

test "CommandRingBuffer full error" {
    var ring = CommandRingBuffer{};
    defer ring.deinit(std.testing.allocator);

    for (0..MAX_COMMAND_QUEUE) |i| {
        try ring.push(std.testing.allocator, .{ .client_id = i, .data = "", .allocator = std.testing.allocator });
    }
    const result = ring.push(std.testing.allocator, .{ .client_id = 999, .data = "", .allocator = std.testing.allocator });
    try std.testing.expectError(error.QueueFull, result);
}

test "CommandRingBuffer refuses a command that would pass the byte limit" {
    var ring = CommandRingBuffer{};
    defer ring.deinit(std.testing.allocator);
    const big = try std.testing.allocator.alloc(u8, MAX_QUEUED_COMMAND_BYTES / 2 + 1);
    defer std.testing.allocator.free(big);

    try ring.push(std.testing.allocator, .{ .client_id = 1, .data = big, .allocator = std.testing.allocator });
    try std.testing.expectError(error.QueueFull, ring.push(std.testing.allocator, .{ .client_id = 2, .data = big, .allocator = std.testing.allocator }));
    _ = ring.pop();
    try ring.push(std.testing.allocator, .{ .client_id = 3, .data = big, .allocator = std.testing.allocator });
}
