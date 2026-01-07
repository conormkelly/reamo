const std = @import("std");
const websocket = @import("websocket");
const protocol = @import("protocol.zig");
const logging = @import("logging.zig");

const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// Maximum pending commands in queue
const MAX_COMMAND_QUEUE = 256;
// Maximum concurrent clients for broadcast buffer
const MAX_CLIENTS = 64;
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
    items: [MAX_COMMAND_QUEUE]Command = undefined,
    head: usize = 0, // Next position to read from
    tail: usize = 0, // Next position to write to
    len: usize = 0,

    fn push(self: *CommandRingBuffer, cmd: Command) !void {
        if (self.len >= MAX_COMMAND_QUEUE) return error.QueueFull;
        self.items[self.tail] = cmd;
        self.tail = (self.tail + 1) % MAX_COMMAND_QUEUE;
        self.len += 1;
    }

    fn pop(self: *CommandRingBuffer) ?Command {
        if (self.len == 0) return null;
        const cmd = self.items[self.head];
        self.head = (self.head + 1) % MAX_COMMAND_QUEUE;
        self.len -= 1;
        return cmd;
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
// Fine-grained locking strategy (Phase 9 BACKEND_IMPROVEMENTS_PLAN.md):
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

    // Connected clients for broadcasting - store Conn pointers directly
    // The websocket library manages Conn lifetime, and Conn.writeText is thread-safe
    // RwLock allows concurrent reads during broadcast while serializing writes
    client_rwlock: Thread.RwLock = .{},
    clients: std.AutoArrayHashMap(usize, *websocket.Conn),
    next_client_id: usize = 1,

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
    // Atomic since it's a simple value updated infrequently
    html_mtime: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),

    // High-precision timing function for clock sync
    // Uses typed atomic for function pointer safety (main thread writes, WS thread reads)
    time_precise_fn: std.atomic.Value(?TimePreciseFn) = std.atomic.Value(?TimePreciseFn).init(null),

    pub fn init(allocator: Allocator) SharedState {
        return .{
            .allocator = allocator,
            .clients = std.AutoArrayHashMap(usize, *websocket.Conn).init(allocator),
            .clients_needing_snapshot = std.AutoArrayHashMap(usize, void).init(allocator),
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
        self.html_mtime.store(mtime, .release);
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
    pub fn getHtmlMtime(self: *SharedState) i128 {
        return self.html_mtime.load(.acquire);
    }

    pub fn deinit(self: *SharedState) void {
        // Clean up any pending commands
        var iter = self.commands.remaining();
        while (iter.next()) |cmd| {
            cmd.deinit();
        }
        self.clients.deinit();
        self.clients_needing_snapshot.deinit();
        self.disconnected_clients.deinit();
    }

    // Called by WebSocket thread after successful hello to request initial snapshot
    pub fn markNeedsSnapshot(self: *SharedState, client_id: usize) void {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();
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

    // Called by WebSocket thread to register a new client
    // Returns null if allocation fails (OOM) - caller should close connection
    pub fn addClient(self: *SharedState, conn: *websocket.Conn) ?usize {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();

        const id = self.next_client_id;
        self.next_client_id += 1;
        self.clients.put(id, conn) catch |e| {
            logging.err("CLIENT ADD FAILED id={d}: {}", .{ id, e });
            return null;
        };
        logging.info("CLIENT ADD id={d} total={d}", .{ id, self.clients.count() });
        return id;
    }

    // Called by WebSocket thread when client disconnects
    pub fn removeClient(self: *SharedState, id: usize) void {
        self.client_rwlock.lock();
        defer self.client_rwlock.unlock();
        _ = self.clients.swapRemove(id);
        // Track disconnected client for gesture cleanup by main thread
        self.disconnected_clients.put(id, {}) catch |e| {
            logging.warn("Failed to track disconnected client {d}: {} - gesture cleanup may be incomplete", .{ id, e });
        };
        logging.info("CLIENT REMOVE id={d} total={d}", .{ id, self.clients.count() });
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

        self.commands.push(.{
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
        for (self.clients.values()) |conn| {
            conn.writeText(message) catch {};
        }
    }

    // Called by main thread to send to a specific client only
    // Uses RwLock read lock since we're only reading the map, not modifying
    // Must hold lock while writing to prevent use-after-free if client disconnects
    pub fn sendToClient(self: *SharedState, client_id: usize, message: []const u8) void {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();

        if (self.clients.get(client_id)) |conn| {
            conn.writeText(message) catch {};
        }
    }

    // Get client count (for logging)
    // Uses RwLock read lock since we're only reading
    pub fn clientCount(self: *SharedState) usize {
        self.client_rwlock.lockShared();
        defer self.client_rwlock.unlockShared();
        return self.clients.count();
    }
};

// Client connection handler - implements websocket.Server handler interface
pub const Client = struct {
    id: usize = 0,
    conn: *websocket.Conn,
    state: *SharedState,
    authenticated: bool = false,

    /// Validate Host header to prevent DNS rebinding attacks.
    /// A malicious website can resolve to a local IP and attempt to connect,
    /// but the Host header will contain the attacker's domain (e.g., "evil.com"),
    /// not the actual IP. We accept connections where Host is a local/private IP.
    fn isValidLocalHost(host: []const u8) bool {
        // Check for valid localhost/private network patterns
        // Accept: localhost, loopback (127.x.x.x), private networks (10.x, 172.16-31.x, 192.168.x)

        // Localhost patterns
        if (std.mem.startsWith(u8, host, "127.") or
            std.mem.startsWith(u8, host, "localhost:") or
            std.mem.startsWith(u8, host, "[::1]:"))
        {
            return true;
        }

        // Private network: 10.x.x.x
        if (std.mem.startsWith(u8, host, "10.")) {
            return true;
        }

        // Private network: 192.168.x.x
        if (std.mem.startsWith(u8, host, "192.168.")) {
            return true;
        }

        // Private network: 172.16.x.x - 172.31.x.x
        if (std.mem.startsWith(u8, host, "172.")) {
            // Extract second octet to check 16-31 range
            const rest = host[4..];
            const dot_pos = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
            const second_octet = std.fmt.parseInt(u8, rest[0..dot_pos], 10) catch return false;
            if (second_octet >= 16 and second_octet <= 31) {
                return true;
            }
        }

        return false;
    }

    pub fn init(h: *const websocket.Handshake, conn: *websocket.Conn, state: *SharedState) !Client {
        // DNS REBINDING PROTECTION: Validate Host header
        // The websocket library stores headers with lowercase keys
        const host = h.headers.get("host") orelse {
            logging.warn("ws_server: connection rejected - missing Host header", .{});
            conn.close(.{ .code = 4003, .reason = "Missing Host header" }) catch {};
            return error.MissingHost;
        };

        if (!isValidLocalHost(host)) {
            logging.warn("ws_server: connection rejected - invalid Host header: {s}", .{host});
            conn.close(.{ .code = 4003, .reason = "Invalid Host header" }) catch {};
            return error.InvalidHost;
        }

        // Register connection (not Client pointer) with shared state
        // If allocation fails, return error to reject the connection
        const id = state.addClient(conn) orelse {
            conn.close(.{ .code = 4500, .reason = "Server at capacity" }) catch {};
            return error.OutOfMemory;
        };

        return .{
            .id = id,
            .conn = conn,
            .state = state,
            .authenticated = false,
        };
    }

    pub fn clientMessage(self: *Client, allocator: Allocator, data: []const u8) !void {
        _ = allocator;

        // Check message type
        const msg_type = protocol.MessageType.parse(data);

        switch (msg_type) {
            .hello => {
                // Handle hello handshake
                const hello = protocol.HelloMessage.parse(data);

                // Validate token
                if (!self.state.validateToken(hello.token)) {
                    // Invalid token - send error and close
                    try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"INVALID_TOKEN\",\"message\":\"Invalid or missing authentication token\"}}");
                    self.conn.close(.{ .code = 4001, .reason = "Invalid token" }) catch {};
                    return;
                }

                // Check protocol version
                if (hello.protocol_version) |client_version| {
                    if (client_version != protocol.PROTOCOL_VERSION) {
                        // Protocol mismatch - send error with our version
                        var buf: [128]u8 = undefined;
                        const err_json = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"error\":{{\"code\":\"PROTOCOL_MISMATCH\",\"message\":\"Expected protocol version {d}\"}}}}", .{protocol.PROTOCOL_VERSION}) catch {
                            logging.warn("ws_server: protocol mismatch response buffer overflow", .{});
                            return;
                        };
                        try self.conn.writeText(err_json);
                        self.conn.close(.{ .code = 4002, .reason = "Protocol mismatch" }) catch {};
                        return;
                    }
                }

                // Success - mark authenticated and send hello response
                self.authenticated = true;
                var buf: [256]u8 = undefined;
                const response = protocol.buildHelloResponse(&buf, self.state.getHtmlMtime());
                try self.conn.writeText(response);

                // Request initial state snapshot from main thread
                self.state.markNeedsSnapshot(self.id);
                return;
            },
            .clockSync => {
                // CLOCK SYNC BYPASS: Handle immediately for timing accuracy
                // Record t1 (receive time) as early as possible
                const t1 = self.state.timePreciseMs();

                // Require authentication
                if (!self.authenticated and self.state.token_set.load(.acquire)) {
                    try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"NOT_AUTHENTICATED\",\"message\":\"Send hello message first\"}}");
                    return;
                }

                // Extract t0 (client send time) from message
                const t0 = protocol.jsonGetFloat(data, "t0") orelse {
                    try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"MISSING_T0\",\"message\":\"t0 is required for clock sync\"}}");
                    return;
                };

                // Record t2 (send time) just before sending response
                const t2 = self.state.timePreciseMs();

                // Send response directly (no queue)
                var buf: [256]u8 = undefined;
                const response = std.fmt.bufPrint(&buf, "{{\"type\":\"clockSyncResponse\",\"t0\":{d:.3},\"t1\":{d:.3},\"t2\":{d:.3}}}", .{ t0, t1, t2 }) catch {
                    logging.warn("ws_server: clockSync response buffer overflow", .{});
                    return;
                };
                try self.conn.writeText(response);
            },
            .command => {
                // Require authentication for commands
                if (!self.authenticated and self.state.token_set.load(.acquire)) {
                    try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"NOT_AUTHENTICATED\",\"message\":\"Send hello message first\"}}");
                    return;
                }

                // Queue command for main thread to process
                if (!self.state.pushCommand(self.id, data)) {
                    // Queue full, send error
                    try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"QUEUE_FULL\",\"message\":\"Command queue full\"}}");
                }
            },
            .unknown => {
                // Unknown message type - ignore or send error
                try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"UNKNOWN_MESSAGE\",\"message\":\"Unknown message type\"}}");
            },
        }
    }

    pub fn close(self: *Client) void {
        self.state.removeClient(self.id);
    }
};

// WebSocket server wrapper
pub const Server = struct {
    allocator: Allocator,
    state: *SharedState,
    server: websocket.Server(Client),
    port: u16,

    pub fn init(allocator: Allocator, state: *SharedState, port: u16) !Server {
        const server = try websocket.Server(Client).init(allocator, .{
            .port = port,
            .address = "0.0.0.0",
        });

        return .{
            .allocator = allocator,
            .state = state,
            .server = server,
            .port = port,
        };
    }

    pub fn deinit(self: *Server) void {
        self.server.deinit();
    }

    pub fn start(self: *Server) !void {
        const thread = try self.server.listenInNewThread(self.state);
        // Detach immediately - we won't be joining this thread on shutdown
        thread.detach();
    }

    pub fn stop(self: *Server) void {
        // The websocket library's stop() blocks on a condition variable waiting
        // for worker threads to exit. Those threads are blocked in kevent() waiting
        // for I/O events, so stop() will hang indefinitely.
        //
        // For REAPER extension shutdown, we can't block - just let the OS clean up
        // when the process exits. The thread was already detached in start().
        _ = self;
    }
};

// Try to start server on a port, auto-increment on conflict
pub fn startWithPortRetry(allocator: Allocator, state: *SharedState, base_port: u16, max_attempts: u8) !struct { server: Server, port: u16 } {
    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const port = base_port + attempt;
        var server = Server.init(allocator, state, port) catch continue;
        server.start() catch {
            server.deinit();
            continue;
        };
        return .{ .server = server, .port = port };
    }
    return error.AllPortsFailed;
}

// Tests
test "CommandRingBuffer push and pop" {
    var ring = CommandRingBuffer{};

    // Create test commands (we won't actually free them in this test)
    const cmd1 = Command{ .client_id = 1, .data = "test1", .allocator = std.testing.allocator };
    const cmd2 = Command{ .client_id = 2, .data = "test2", .allocator = std.testing.allocator };

    try ring.push(cmd1);
    try ring.push(cmd2);

    const popped1 = ring.pop().?;
    try std.testing.expectEqual(@as(usize, 1), popped1.client_id);

    const popped2 = ring.pop().?;
    try std.testing.expectEqual(@as(usize, 2), popped2.client_id);

    try std.testing.expect(ring.pop() == null);
}

test "CommandRingBuffer wraps around" {
    var ring = CommandRingBuffer{};

    // Fill partially
    for (0..10) |i| {
        try ring.push(.{ .client_id = i, .data = "", .allocator = std.testing.allocator });
    }

    // Pop some
    for (0..5) |_| {
        _ = ring.pop();
    }

    // Push more (should wrap)
    for (10..20) |i| {
        try ring.push(.{ .client_id = i, .data = "", .allocator = std.testing.allocator });
    }

    // Verify order
    for (5..20) |i| {
        const cmd = ring.pop().?;
        try std.testing.expectEqual(i, cmd.client_id);
    }
}

test "CommandRingBuffer full error" {
    var ring = CommandRingBuffer{};

    // Fill completely
    for (0..MAX_COMMAND_QUEUE) |i| {
        try ring.push(.{ .client_id = i, .data = "", .allocator = std.testing.allocator });
    }

    // Should fail
    const result = ring.push(.{ .client_id = 999, .data = "", .allocator = std.testing.allocator });
    try std.testing.expectError(error.QueueFull, result);
}
