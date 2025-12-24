const std = @import("std");
const websocket = @import("websocket");
const protocol = @import("protocol.zig");

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

// Shared state between WebSocket thread and main thread
pub const SharedState = struct {
    mutex: Thread.Mutex = .{},
    allocator: Allocator,

    // Command queue: WebSocket thread pushes, main thread pops
    commands: CommandRingBuffer = .{},

    // Connected clients for broadcasting - store Conn pointers directly
    // The websocket library manages Conn lifetime, and Conn.writeText is thread-safe
    clients: std.AutoArrayHashMap(usize, *websocket.Conn),
    next_client_id: usize = 1,

    // Clients that need initial state snapshot (set by WS thread after hello, consumed by main thread)
    clients_needing_snapshot: std.AutoArrayHashMap(usize, void),

    // Session token for authentication (hex string)
    session_token: [TOKEN_HEX_LENGTH]u8 = undefined,
    token_set: bool = false,

    pub fn init(allocator: Allocator) SharedState {
        return .{
            .allocator = allocator,
            .clients = std.AutoArrayHashMap(usize, *websocket.Conn).init(allocator),
            .clients_needing_snapshot = std.AutoArrayHashMap(usize, void).init(allocator),
        };
    }

    // Set the session token (called by main.zig on startup)
    pub fn setToken(self: *SharedState, token: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const len = @min(token.len, TOKEN_HEX_LENGTH);
        @memcpy(self.session_token[0..len], token[0..len]);
        self.token_set = true;
    }

    // Validate a token (called during hello handshake)
    pub fn validateToken(self: *SharedState, token: ?[]const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If no token is set, allow all connections (backwards compatibility)
        if (!self.token_set) return true;

        const t = token orelse return false;
        if (t.len != TOKEN_HEX_LENGTH) return false;

        return std.mem.eql(u8, t, &self.session_token);
    }

    pub fn deinit(self: *SharedState) void {
        // Clean up any pending commands
        var iter = self.commands.remaining();
        while (iter.next()) |cmd| {
            cmd.deinit();
        }
        self.clients.deinit();
        self.clients_needing_snapshot.deinit();
    }

    // Called by WebSocket thread after successful hello to request initial snapshot
    pub fn markNeedsSnapshot(self: *SharedState, client_id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clients_needing_snapshot.put(client_id, {}) catch {};
    }

    // Called by main thread to get and clear clients needing snapshots
    // Returns client IDs in a static buffer (caller should process immediately)
    pub fn popClientsNeedingSnapshot(self: *SharedState, out_buf: []usize) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

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
    pub fn addClient(self: *SharedState, conn: *websocket.Conn) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_client_id;
        self.next_client_id += 1;
        self.clients.put(id, conn) catch {};
        return id;
    }

    // Called by WebSocket thread when client disconnects
    pub fn removeClient(self: *SharedState, id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.clients.swapRemove(id);
    }

    // Called by WebSocket thread to queue a command for main thread
    pub fn pushCommand(self: *SharedState, client_id: usize, data: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Make a copy of the data for the main thread
        const data_copy = self.allocator.dupe(u8, data) catch return false;

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
    pub fn popCommand(self: *SharedState) ?Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.commands.pop();
    }

    // Called by main thread to broadcast to all clients
    // Copies client list while holding lock to avoid races
    pub fn broadcast(self: *SharedState, message: []const u8) void {
        // Copy conn pointers while holding lock
        var conns: [MAX_CLIENTS]*websocket.Conn = undefined;
        var count: usize = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.clients.values()) |conn| {
                if (count >= MAX_CLIENTS) break;
                conns[count] = conn;
                count += 1;
            }
        }

        // Send to all clients without holding lock
        // writeText is thread-safe within the websocket library
        for (conns[0..count]) |conn| {
            conn.writeText(message) catch {};
        }
    }

    // Called by main thread to send to a specific client only
    pub fn sendToClient(self: *SharedState, client_id: usize, message: []const u8) void {
        var conn: ?*websocket.Conn = null;

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            conn = self.clients.get(client_id);
        }

        if (conn) |c| {
            c.writeText(message) catch {};
        }
    }

    // Get client count (for logging)
    pub fn clientCount(self: *SharedState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.clients.count();
    }
};

// Client connection handler - implements websocket.Server handler interface
pub const Client = struct {
    id: usize = 0,
    conn: *websocket.Conn,
    state: *SharedState,
    authenticated: bool = false,

    pub fn init(_: *const websocket.Handshake, conn: *websocket.Conn, state: *SharedState) !Client {
        // Register connection (not Client pointer) with shared state
        const id = state.addClient(conn);

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
                        const err_json = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"error\":{{\"code\":\"PROTOCOL_MISMATCH\",\"message\":\"Expected protocol version {d}\"}}}}", .{protocol.PROTOCOL_VERSION}) catch return;
                        try self.conn.writeText(err_json);
                        self.conn.close(.{ .code = 4002, .reason = "Protocol mismatch" }) catch {};
                        return;
                    }
                }

                // Success - mark authenticated and send hello response
                self.authenticated = true;
                var buf: [128]u8 = undefined;
                const response = protocol.buildHelloResponse(&buf);
                try self.conn.writeText(response);

                // Request initial state snapshot from main thread
                self.state.markNeedsSnapshot(self.id);
                return;
            },
            .command => {
                // Require authentication for commands
                if (!self.authenticated and self.state.token_set) {
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
