const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// Maximum pending commands in queue
const MAX_COMMAND_QUEUE = 256;

// Command received from a client
pub const Command = struct {
    client_id: usize,
    data: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Command) void {
        self.allocator.free(self.data);
    }
};

// Simple fixed-capacity command queue
const CommandQueue = struct {
    items: [MAX_COMMAND_QUEUE]Command = undefined,
    len: usize = 0,

    fn append(self: *CommandQueue, cmd: Command) !void {
        if (self.len >= MAX_COMMAND_QUEUE) return error.QueueFull;
        self.items[self.len] = cmd;
        self.len += 1;
    }

    fn pop(self: *CommandQueue) ?Command {
        if (self.len == 0) return null;
        const cmd = self.items[0];
        // Shift remaining items
        for (0..self.len - 1) |i| {
            self.items[i] = self.items[i + 1];
        }
        self.len -= 1;
        return cmd;
    }

    fn slice(self: *CommandQueue) []Command {
        return self.items[0..self.len];
    }
};

// Shared state between WebSocket thread and main thread
pub const SharedState = struct {
    mutex: Thread.Mutex = .{},

    // Command queue: WebSocket thread pushes, main thread pops
    commands: CommandQueue = .{},

    // Connected clients for broadcasting
    clients: std.AutoArrayHashMap(usize, *Client),
    next_client_id: usize = 1,

    // Pending broadcasts from main thread
    broadcast_queue: std.ArrayList([]const u8) = .empty,

    allocator: Allocator,

    pub fn init(allocator: Allocator) SharedState {
        return .{
            .allocator = allocator,
            .clients = std.AutoArrayHashMap(usize, *Client).init(allocator),
            .broadcast_queue = .empty,
        };
    }

    pub fn deinit(self: *SharedState) void {
        // Clean up any pending commands
        for (self.commands.slice()) |*cmd| {
            cmd.deinit();
        }

        // Clean up broadcast queue
        for (self.broadcast_queue.items) |msg| {
            self.allocator.free(msg);
        }
        self.broadcast_queue.deinit(self.allocator);

        self.clients.deinit();
    }

    // Called by WebSocket thread to register a new client
    pub fn addClient(self: *SharedState, client: *Client) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_client_id;
        self.next_client_id += 1;
        self.clients.put(id, client) catch {};
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

        self.commands.append(.{
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

    // Called by main thread to queue a broadcast
    pub fn queueBroadcast(self: *SharedState, message: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const msg_copy = self.allocator.dupe(u8, message) catch return false;
        self.broadcast_queue.append(self.allocator, msg_copy) catch {
            self.allocator.free(msg_copy);
            return false;
        };
        return true;
    }

    // Called by WebSocket thread to send pending broadcasts
    pub fn flushBroadcasts(self: *SharedState) void {
        self.mutex.lock();

        // Take ownership of the queue
        const messages = self.broadcast_queue.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        const clients = self.clients.values();

        self.mutex.unlock();

        // Send outside the lock
        defer self.allocator.free(messages);
        for (messages) |msg| {
            defer self.allocator.free(msg);
            for (clients) |client| {
                client.conn.writeText(msg) catch {};
            }
        }
    }

    // Get client count (for logging)
    pub fn clientCount(self: *SharedState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.clients.count();
    }
};

// Client connection handler
pub const Client = struct {
    id: usize = 0,
    conn: *websocket.Conn,
    state: *SharedState,

    pub fn init(_: *const websocket.Handshake, conn: *websocket.Conn, state: *SharedState) !Client {
        var client = Client{
            .conn = conn,
            .state = state,
        };

        // Register with shared state
        client.id = state.addClient(&client);

        return client;
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
    thread: ?Thread = null,
    port: u16,

    pub fn init(allocator: Allocator, state: *SharedState, port: u16) !Server {
        const server = try websocket.Server(Client).init(allocator, .{
            .port = port,
            .address = "0.0.0.0", // Accept connections from any interface
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
        self.thread = try self.server.listenInNewThread(self.state);
    }

    pub fn stop(self: *Server) void {
        self.server.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
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
