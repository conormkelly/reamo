const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// Maximum pending commands in queue
const MAX_COMMAND_QUEUE = 256;
// Maximum concurrent clients for broadcast buffer
const MAX_CLIENTS = 64;

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

    pub fn init(allocator: Allocator) SharedState {
        return .{
            .allocator = allocator,
            .clients = std.AutoArrayHashMap(usize, *websocket.Conn).init(allocator),
        };
    }

    pub fn deinit(self: *SharedState) void {
        // Clean up any pending commands
        var iter = self.commands.remaining();
        while (iter.next()) |cmd| {
            cmd.deinit();
        }
        self.clients.deinit();
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

    pub fn init(_: *const websocket.Handshake, conn: *websocket.Conn, state: *SharedState) !Client {
        // Register connection (not Client pointer) with shared state
        const id = state.addClient(conn);

        return .{
            .id = id,
            .conn = conn,
            .state = state,
        };
    }

    pub fn clientMessage(self: *Client, allocator: Allocator, data: []const u8) !void {
        _ = allocator;

        // Queue command for main thread to process
        if (!self.state.pushCommand(self.id, data)) {
            // Queue full, send error
            try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"QUEUE_FULL\",\"message\":\"Command queue full\"}}");
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
