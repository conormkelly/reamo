const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;
const host_validation = @import("host_validation.zig");
const ws_server = @import("ws_server.zig");
const socket_options = @import("socket_options.zig");
const protocol = @import("../core/protocol.zig");
const logging = @import("../core/logging.zig");
const dev_options = @import("dev_options");
const dev_mode = dev_options.enable_dev;

const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// Socket option constants — std.posix.SOL/SO resolve to empty structs on Windows
const SOL_SOCKET: i32 = if (builtin.os.tag == .windows)
    @intCast(std.os.windows.ws2_32.SOL.SOCKET)
else
    std.posix.SOL.SOCKET;

const SO_SNDBUF: u32 = if (builtin.os.tag == .windows)
    @intCast(std.os.windows.ws2_32.SO.SNDBUF)
else
    std.posix.SO.SNDBUF;

const ServerType = httpz.Server(Handler);

/// HTTP + WebSocket server built on httpz.
/// Serves the app HTML on GET / and upgrades /ws to WebSocket.
pub const HttpServer = struct {
    allocator: Allocator,
    state: *ws_server.SharedState,
    server: *ServerType,
    listen_thread: ?Thread = null,
    port: u16,
    index_html: ?[]const u8, // Cached HTML with token meta tag injected
    web_dir: ?[]const u8, // Directory containing web assets (index.html, assets/, etc.)
    html_path: ?[]const u8, // Path to index.html (used for per-request reads in dev mode)

    /// Initialize the HTTP server. Reads and caches HTML file with token injection.
    /// Does NOT start listening — call `start()` for that.
    pub fn init(allocator: Allocator, state: *ws_server.SharedState, port: u16, html_path: ?[]const u8, web_dir: ?[]const u8) !HttpServer {
        // In dev mode, skip caching — HTML is read fresh per request
        const cached_html = if (dev_mode)
            null
        else if (html_path) |path| blk: {
            const html = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |err| {
                logging.warn("http_server: could not read HTML file '{s}': {s}", .{ path, @errorName(err) });
                break :blk null;
            };

            // Inject token meta tag before </head>
            const injected = injectTokenMeta(allocator, html, state) catch |err| {
                logging.warn("http_server: token injection failed: {s}", .{@errorName(err)});
                break :blk html; // Serve without token if injection fails
            };

            if (injected.ptr != html.ptr) {
                allocator.free(html);
            }
            break :blk injected;
        } else null;

        const handler = Handler{ .state = state, .index_html = cached_html, .web_dir = web_dir, .html_path = html_path };

        // httpz.Server.init returns by value; we need a heap-stable pointer
        // because listenInNewThread takes *Self
        var server = try allocator.create(ServerType);
        errdefer allocator.destroy(server);
        server.* = try ServerType.init(allocator, .{
            .address = .{ .ip = .{ .host = "0.0.0.0", .port = port } },
            .timeout = .{
                .request = 5, // 5s header read timeout (Slowloris defense)
                // Short: page loads finish in well under a second on a LAN, and
                // a web page can park idle keep-alive sockets on our loopback
                // addresses to exhaust max_conn.
                .keepalive = 5,
            },
            .workers = .{
                // Home studio needs a handful (phone + tablet + laptop). The cap is
                // set above what one browser can hold idle against us (~6 sockets
                // per host and pool across 127.0.0.1, localhost, [::1] and the LAN
                // IP), so a hostile page can't lock real clients out.
                .max_conn = 64,
                // Connections preallocated up front (httpz defaults this to
                // max_conn); keeps the idle footprint at what 16 cost.
                .min_conn = 16,
            },
            .thread_pool = .{
                // Request handlers on macOS and Linux. On Windows (blocking
                // mode) each connection gets a thread of its own instead, up to
                // max_conn, so this isn't a limit there. Default is 32 which
                // wastes ~1MB in thread buffers.
                .count = 8,
                // Windows commits a thread's whole stack when it starts, and
                // there each connection is a thread. 1 MiB is Windows' own
                // default; the handlers keep no more than a few KB on the stack.
                .stack_size = 1024 * 1024,
            },
        }, handler);

        var router = try server.router(.{});
        router.get("/", serveIndex, .{});
        router.get("/api/ping", servePing, .{});
        router.get("/ws", serveWsUpgrade, .{});
        router.get("/*", serveStatic, .{});

        return .{
            .allocator = allocator,
            .state = state,
            .server = server,
            .port = port,
            .index_html = cached_html,
            .web_dir = web_dir,
            .html_path = html_path,
        };
    }

    /// Start the server in a background thread. Returns once listening.
    pub fn start(self: *HttpServer) !void {
        self.listen_thread = try self.server.listenInNewThread();
    }

    /// Stop the server and clean up.
    pub fn stop(self: *HttpServer) void {
        // A server that never listened (its port was taken) has nothing to
        // stop, and httpz logs an error if asked to.
        const t = self.listen_thread orelse return;
        self.server.stop();
        t.join();
        self.listen_thread = null;
    }

    pub fn deinit(self: *HttpServer) void {
        self.stop();
        self.server.deinit();
        self.allocator.destroy(self.server);
        if (self.index_html) |html| {
            self.allocator.free(html);
            self.index_html = null;
        }
    }

    /// Re-read and cache HTML file with token injection (for hot reload).
    /// NOTE: Intentionally does NOT free the old index_html. httpz worker threads
    /// may still be writing it to an in-flight HTTP response. Freeing it races with
    /// response.Response.write → memmove → segfault. The leak is ~2KB per rebuild,
    /// only during development, cleaned up when REAPER exits.
    pub fn reloadHtml(self: *HttpServer, html_path: []const u8) void {
        if (dev_mode) return; // Dev mode reads fresh per request, no cache to update
        const html = std.fs.cwd().readFileAlloc(self.allocator, html_path, 4 * 1024 * 1024) catch |err| {
            logging.warn("http_server: hot reload failed to read '{s}': {s}", .{ html_path, @errorName(err) });
            return;
        };

        const injected = injectTokenMeta(self.allocator, html, self.state) catch {
            // Use raw HTML if injection fails
            self.index_html = html;
            self.server.handler.index_html = html;
            return;
        };

        if (injected.ptr != html.ptr) {
            self.allocator.free(html);
        }
        // Old index_html intentionally leaked — see doc comment above
        self.index_html = injected;
        self.server.handler.index_html = injected;
    }
};

// ── Handler ────────────────────────────────────────────────────────

/// httpz Handler — provides shared context and declares WebsocketHandler.
const Handler = struct {
    state: *ws_server.SharedState,
    index_html: ?[]const u8 = null,
    web_dir: ?[]const u8 = null,
    html_path: ?[]const u8 = null,

    pub const WebsocketHandler = WsHandler;

    /// A route handler failed. httpz's own report quotes the raw URL, which
    /// a client controls; this one keeps it contained.
    pub fn uncaughtError(_: Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        logging.warn("HTTP request for '{f}' failed: {s}", .{ logging.untrusted(req.url.path), @errorName(err) });
        res.status = 500;
        res.body = "Internal Server Error";
    }
};

// ── HTTP Route Handlers ────────────────────────────────────────────

/// A browser reached REAmo by a name it doesn't serve: the usual cause of
/// "the page won't load" with a VPN or custom hostname.
/// The name itself is often the user's machine or domain, so it is debug.
fn logRefusedHost(host: []const u8) void {
    logging.info("Refused a request for a host name REAmo doesn't serve; if it's this computer, add it under Extensions > REAmo > Allowed Hosts", .{});
    logging.debug("Refused host: '{f}'", .{logging.untrusted(host)});
}

fn serveIndex(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Host header validation (DNS rebinding protection)
    const host = req.header("host") orelse {
        res.status = 403;
        res.body = "Forbidden: missing Host header";
        return;
    };
    if (!host_validation.isValidLocalHost(host)) {
        logRefusedHost(host);
        res.status = 403;
        res.body = "Forbidden: invalid Host header";
        return;
    }

    setSecurityHeaders(res);

    if (dev_mode) {
        // Dev mode: read HTML fresh from disk per request
        const path = handler.html_path orelse {
            res.status = 503;
            res.body = "Application not ready";
            return;
        };
        const html = std.fs.cwd().readFileAlloc(res.arena, path, 4 * 1024 * 1024) catch {
            res.status = 503;
            res.body = "Application not ready";
            return;
        };
        const injected = injectTokenMeta(res.arena, html, handler.state) catch html;
        res.content_type = .HTML;
        res.body = injected;
    } else {
        // Production: serve cached HTML
        if (handler.index_html) |html| {
            res.content_type = .HTML;
            res.body = html;
        } else {
            res.status = 503;
            res.body = "Application not ready";
        }
    }
}

/// Lightweight ping endpoint for Safari network stack warmup.
/// The frontend fetches this before opening a WebSocket to ensure Safari's
/// lazy networking layer is initialized.
fn servePing(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn serveWsUpgrade(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Host validation
    const host = req.header("host") orelse {
        res.status = 403;
        res.body = "Forbidden: missing Host header";
        return;
    };
    if (!host_validation.isValidLocalHost(host)) {
        logRefusedHost(host);
        res.status = 403;
        res.body = "Forbidden: invalid Host header";
        return;
    }

    // Origin validation (CSRF protection for WebSocket upgrade)
    const origin = req.header("origin");
    if (!host_validation.isValidOrigin(origin, host)) {
        logging.info("Refused a WebSocket whose page came from another site (Origin doesn't match Host)", .{});
        logging.debug("Refused origin '{f}' for host '{f}'", .{ logging.untrusted(origin orelse "(none)"), logging.untrusted(host) });
        res.status = 403;
        res.body = "Forbidden: invalid Origin header";
        return;
    }

    const ctx = WsHandler.Context{ .state = handler.state };
    if (try httpz.upgradeWebsocket(WsHandler, req, res, &ctx) == false) {
        res.status = 400;
        res.body = "WebSocket upgrade failed";
    }
}

fn serveStatic(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const host = req.header("host") orelse {
        res.status = 403;
        res.body = "Forbidden: missing Host header";
        return;
    };
    if (!host_validation.isValidLocalHost(host)) {
        logRefusedHost(host);
        res.status = 403;
        res.body = "Forbidden: invalid Host header";
        return;
    }

    const web_dir = handler.web_dir orelse {
        res.status = 404;
        res.body = "Not found";
        return;
    };
    const path = req.url.path;

    // Security: reject directory traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        res.status = 403;
        res.body = "Forbidden";
        return;
    }

    // Strip leading / to get relative path
    const relative = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (relative.len == 0) {
        res.status = 404;
        res.body = "Not found";
        return;
    }

    // Build file path: web_dir/relative
    var buf: [1024]u8 = undefined;
    const file_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ web_dir, relative }) catch {
        res.status = 500;
        res.body = "Internal error";
        return;
    };

    // Read file using per-request arena (auto-freed after response)
    const content = std.fs.cwd().readFileAlloc(res.arena, file_path, 4 * 1024 * 1024) catch {
        res.status = 404;
        res.body = "Not found";
        return;
    };

    // Content-Type from file extension
    const ct = httpz.ContentType.forFile(relative);
    if (ct != .UNKNOWN) res.content_type = ct;

    // Cache headers: content-hashed assets get immutable caching, everything else no-store
    if (std.mem.startsWith(u8, relative, "assets/")) {
        res.header("Cache-Control", "public, max-age=31536000, immutable");
    } else {
        res.header("Cache-Control", "no-store");
    }

    res.header("X-Content-Type-Options", "nosniff");
    res.header("Cross-Origin-Resource-Policy", "same-origin");
    res.body = content;
}

// ── WebSocket Handler ──────────────────────────────────────────────

/// WebSocket handler for httpz. Mirrors the old ws_server.Client logic.
var sndbuf_warned = std.atomic.Value(bool).init(false);

const WsHandler = struct {
    id: usize,
    conn: *websocket.Conn,
    state: *ws_server.SharedState,
    authenticated: bool = false,
    closed: bool = false,
    connected_ms: i64 = 0,

    const Context = struct {
        state: *ws_server.SharedState,
    };

    pub fn init(conn: *websocket.Conn, ctx: *const Context) !WsHandler {
        // A larger send buffer lets big messages (action/getActions ~1.1 MB)
        // go out in one write. Output the socket can't take yet is queued by
        // websocket.zig and drained by SharedState.flushPendingOutput.
        const sndbuf: c_int = 4 * 1024 * 1024;
        socket_options.setConnectionOption(conn.stream.handle, SOL_SOCKET, SO_SNDBUF, std.mem.asBytes(&sndbuf)) catch |err| switch (err) {
            // The phone has already gone; its next read ends the connection.
            error.ConnectionResetByPeer => {},
            else => {
                // Same cause for every connection: say it once.
                if (!sndbuf_warned.swap(true, .monotonic)) {
                    logging.warn("Can't enlarge WebSocket send buffers ({s}); large lists go out in pieces", .{@errorName(err)});
                }
            },
        };

        const id = ctx.state.addClient(conn) orelse {
            conn.close(.{ .code = 4500, .reason = "Server at capacity" }) catch {};
            return error.OutOfMemory;
        };

        return .{
            .id = id,
            .conn = conn,
            .state = ctx.state,
            .connected_ms = std.time.milliTimestamp(),
        };
    }

    pub fn clientMessage(self: *WsHandler, allocator: Allocator, data: []const u8) !void {
        _ = allocator;

        const msg_type = protocol.MessageType.parse(data);

        switch (msg_type) {
            .hello => {
                const hello = protocol.HelloMessage.parse(data);

                if (!self.state.validateToken(hello.token)) {
                    logging.info("Client {d} refused: stale or missing session token (a page from before REAPER restarted?)", .{self.id});
                    self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"INVALID_TOKEN\",\"message\":\"Invalid or missing authentication token\"}}") catch {};
                    self.conn.close(.{ .code = 4001, .reason = "Invalid token" }) catch {};
                    return;
                }

                if (hello.protocol_version) |client_version| {
                    if (client_version != protocol.PROTOCOL_VERSION) {
                        logging.warn("Client {d} refused: it speaks protocol {d}, REAmo {d} (a cached page from another version?)", .{ self.id, client_version, protocol.PROTOCOL_VERSION });
                        var buf: [128]u8 = undefined;
                        const err_json = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"error\":{{\"code\":\"PROTOCOL_MISMATCH\",\"message\":\"Expected protocol version {d}\"}}}}", .{protocol.PROTOCOL_VERSION}) catch {
                            logging.warn("http_server: protocol mismatch response buffer overflow", .{});
                            return;
                        };
                        self.conn.writeText(err_json) catch {};
                        self.conn.close(.{ .code = 4002, .reason = "Protocol mismatch" }) catch {};
                        return;
                    }
                }

                self.authenticated = true;
                logging.info("Client {d} connected", .{self.id});
                var buf: [256]u8 = undefined;
                const response = protocol.buildHelloResponse(&buf, self.state.getHtmlMtime());
                self.conn.writeText(response) catch |err| {
                    self.state.logWriteError(err);
                    return;
                };

                self.state.markNeedsSnapshot(self.id);
            },
            .clockSync => {
                const t1 = self.state.timePreciseMs();

                if (!self.authenticated and self.state.token_set.load(.acquire)) {
                    self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"NOT_AUTHENTICATED\",\"message\":\"Send hello message first\"}}") catch |err| {
                        self.state.logWriteError(err);
                    };
                    return;
                }

                const t0 = protocol.jsonGetFloat(data, "t0") orelse {
                    self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"MISSING_T0\",\"message\":\"t0 is required for clock sync\"}}") catch |err| {
                        self.state.logWriteError(err);
                    };
                    return;
                };

                const t2 = self.state.timePreciseMs();

                var buf: [256]u8 = undefined;
                const response = std.fmt.bufPrint(&buf, "{{\"type\":\"clockSyncResponse\",\"t0\":{d:.3},\"t1\":{d:.3},\"t2\":{d:.3}}}", .{ t0, t1, t2 }) catch {
                    logging.warn("http_server: clockSync response buffer overflow", .{});
                    return;
                };
                self.conn.writeText(response) catch |err| {
                    self.state.logWriteError(err);
                };
            },
            .ping => {
                if (!self.authenticated and self.state.token_set.load(.acquire)) {
                    self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"NOT_AUTHENTICATED\",\"message\":\"Send hello message first\"}}") catch |err| {
                        self.state.logWriteError(err);
                    };
                    return;
                }

                const timestamp = protocol.jsonGetFloat(data, "timestamp");

                var buf: [128]u8 = undefined;
                const response = if (timestamp) |ts|
                    std.fmt.bufPrint(&buf, "{{\"type\":\"pong\",\"timestamp\":{d:.0}}}", .{ts}) catch {
                        logging.warn("http_server: ping response buffer overflow", .{});
                        return;
                    }
                else
                    "{\"type\":\"pong\"}";
                self.conn.writeText(response) catch |err| {
                    self.state.logWriteError(err);
                };
            },
            .command => {
                if (!self.authenticated and self.state.token_set.load(.acquire)) {
                    self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"NOT_AUTHENTICATED\",\"message\":\"Send hello message first\"}}") catch |err| {
                        self.state.logWriteError(err);
                    };
                    return;
                }

                if (!self.state.pushCommand(self.id, data)) self.refuseQueueFull(data);
            },
            .unknown => {
                self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"UNKNOWN_MESSAGE\",\"message\":\"Unknown message type\"}}") catch |err| {
                    self.state.logWriteError(err);
                };
            },
        }
    }

    /// Tell the client its command was refused. A command with an id gets a
    /// response carrying that id, so a UI awaiting it fails at once rather
    /// than at its timeout.
    fn refuseQueueFull(self: *WsHandler, data: []const u8) void {
        logging.warn("Client {d}: command queue full, refused a command", .{self.id});
        const err_body = "\"error\":{\"code\":\"QUEUE_FULL\",\"message\":\"Too many commands at once; try again\"}";
        const id = protocol.jsonGetString(data, "id") orelse {
            self.conn.writeText("{\"type\":\"error\"," ++ err_body ++ "}") catch |err| self.state.logWriteError(err);
            return;
        };
        // Exact-size, so the reply carries the id however long it is.
        const msg = std.fmt.allocPrint(std.heap.c_allocator, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":false,{s}}}", .{ id, err_body }) catch {
            logging.err("Client {d}: no memory to refuse a command", .{self.id});
            return;
        };
        defer std.heap.c_allocator.free(msg);
        self.conn.writeText(msg) catch |err| {
            self.state.logWriteError(err);
        };
    }

    pub fn close(self: *WsHandler) void {
        if (self.closed) return;
        self.closed = true;
        self.state.removeClient(self.id);
        if (self.authenticated) {
            const secs = @divFloor(std.time.milliTimestamp() - self.connected_ms, std.time.ms_per_s);
            logging.info("Client {d} disconnected after {d}m{d:0>2}s", .{ self.id, @divFloor(secs, 60), @as(u64, @intCast(@mod(secs, 60))) });
        }
    }
};

// ── Security Headers ───────────────────────────────────────────────

fn setSecurityHeaders(res: *httpz.Response) void {
    // CSP: strict allow-list, no unsafe-inline anywhere.
    // React inline style={{}} uses CSSOM (element.style.prop = value), not setAttribute,
    // so style-src 'self' is sufficient without 'unsafe-inline'.
    res.header("Content-Security-Policy",
        "default-src 'none'" ++
        "; script-src 'self'" ++
        "; style-src 'self'" ++
        "; img-src 'self' data:" ++
        "; font-src 'self' data:" ++
        "; connect-src 'self' ws: wss:" ++
        "; manifest-src 'self'" ++
        "; base-uri 'self'" ++
        "; form-action 'none'" ++
        "; frame-ancestors 'none'" ++
        "; object-src 'none'",
    );
    // Prevent framing (clickjacking) — belt-and-suspenders with frame-ancestors
    res.header("X-Frame-Options", "DENY");
    // Prevent MIME sniffing
    res.header("X-Content-Type-Options", "nosniff");
    // No caching for dynamic content (overridden per-route for assets)
    res.header("Cache-Control", "no-store");
    // Cross-Origin isolation
    res.header("Cross-Origin-Resource-Policy", "same-origin");
    res.header("Cross-Origin-Opener-Policy", "same-origin");
    // Don't leak URLs to other origins
    res.header("Referrer-Policy", "no-referrer");
    // Disable unused browser features
    res.header("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), bluetooth=()");
}

// ── Token Injection ────────────────────────────────────────────────

/// Inject `<meta name="reamo-token" content="TOKEN">` before `</head>`.
/// Returns new allocation if injected, or the original slice if `</head>` not found.
fn injectTokenMeta(allocator: Allocator, html: []const u8, state: *ws_server.SharedState) ![]const u8 {
    const token = state.getToken() orelse return html;
    const needle = "</head>";
    const pos = std.mem.indexOf(u8, html, needle) orelse {
        // Served without the token, every phone's hello is refused.
        logging.warn("reamo/index.html has no </head>; phones can't authenticate (reinstall REAmo's web files)", .{});
        return html;
    };

    const meta_tag = try std.fmt.allocPrint(allocator, "<meta name=\"reamo-token\" content=\"{s}\">\n", .{token});
    defer allocator.free(meta_tag);

    const result = try allocator.alloc(u8, html.len + meta_tag.len);
    @memcpy(result[0..pos], html[0..pos]);
    @memcpy(result[pos .. pos + meta_tag.len], meta_tag);
    @memcpy(result[pos + meta_tag.len ..], html[pos..]);
    return result;
}
