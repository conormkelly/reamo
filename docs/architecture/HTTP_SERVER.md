# HTTP server migration: REAPER built-in → karlseguin/httpz

## Why migrate

REAmo currently uses two servers on two ports:

| Component | Port | Provided by | Purpose |
|-----------|------|-------------|---------|
| HTTP | 8080 (configurable) | REAPER's built-in web server | Serves `reamo.html`, icons, PWA manifest |
| WebSocket | 9224–9233 (auto-retry) | Zig extension via `websocket.zig` | Real-time DAW control |

This creates three problems:

1. **Setup friction.** Users must manually enable REAPER's web server in Preferences > Control/OSC/Web before REAmo works. This is the single biggest barrier to the "install → open URL → done" first-run experience.

2. **Two-port architecture forces workarounds.** The frontend is served from `:8080` but connects to WebSocket on `:9224`. Since they're different origins, the frontend can't simply use `window.location` — it must discover the WS port by fetching EXTSTATE via REAPER's HTTP API (`/_/GET/EXTSTATE/Reamo/WebSocketPort`). This adds 2+ seconds of startup latency on iOS PWA cold start (the EXTSTATE fetch can hang on Safari's lazy network initialization).

3. **Single-file constraint limits security and performance.** REAPER's web server serves files from `reaper_www_root/` with no control over HTTP headers. The `viteSingleFile` build bundles everything into one 891KB HTML file — this forces `script-src 'unsafe-inline'` in CSP (weaker XSS protection), prevents content-hashed caching of assets, and bloats every page load. We cannot add security headers (X-Frame-Options, COOP, CORP, CSP) because REAPER's server doesn't support custom headers.

### What the migration enables

- **Zero-config setup:** Extension manages its own HTTP+WS server on a single port. Install extension → it works.
- **Clean URL:** `http://<ip>:9224/` instead of `http://<ip>:8080/reamo.html`. Shorter to type, simpler QR code, serves `index.html` at root. No dependency on `reaper_www_root/` directory.
- **Same-origin simplicity:** HTML served from `:9224`, WS connects to `ws://${window.location.host}/ws`. No port discovery, no EXTSTATE fetch, no cross-origin complications.
- **Security headers:** Full control over response headers — CSP, X-Frame-Options, COOP, CORP, Referrer-Policy, Permissions-Policy (see [SECURITY.md](SECURITY.md) §4).
- **Code splitting:** Separate JS/CSS with content-hashed filenames. `script-src 'self'` instead of `'unsafe-inline'`. Long-lived cache for assets, no-store for HTML.
- **CSRF token in HTML:** Server embeds the session token as a `<meta>` tag in the served HTML — no EXTSTATE round-trip needed (see [SECURITY.md](SECURITY.md) §3).
- **Foundation for licensing:** Server can handle the license validation response flow (see [LICENSING.md](LICENSING.md)).
- **User-configurable server settings:** Port, bind address, and security presets exposed via Extensions menu (menu system already in place).

---

## Current architecture (what we have)

```
┌─────────────────────────────────────────────────┐
│  REAPER built-in HTTP server (:8080)            │
│  ├── GET /reamo.html → single-file React PWA    │
│  ├── GET /manifest.json → PWA manifest          │
│  ├── GET /icon-*.png → app icons                │
│  └── GET /_/GET/EXTSTATE/... → REAPER API       │
└───────────────────┬─────────────────────────────┘
                    │  User opens http://<ip>:8080/reamo.html
                    │  HTML loads, JS discovers WS port via EXTSTATE
                    ▼
┌─────────────────────────────────────────────────┐
│  Zig extension WebSocket server (:9224)         │
│  └── ws://<ip>:9224/ → real-time control        │
│      ├── hello handshake (token, version)       │
│      ├── command queue → REAPER main thread     │
│      ├── state broadcast (30Hz tiered polling)  │
│      └── clockSync, ping/pong                   │
└─────────────────────────────────────────────────┘
```

### Key implementation details

**WebSocket server** ([ws_server.zig](../../extension/src/server/ws_server.zig)):

- Uses `karlseguin/websocket.zig` directly (dependency in [build.zig.zon](../../extension/build.zig.zon))
- `websocket.Server(Client)` generic — `Client` struct handles per-connection state
- `startWithPortRetry()` tries ports 9224–9233, stores chosen port in EXTSTATE
- Server runs on a detached thread via `server.listenInNewThread()`
- SharedState provides thread-safe communication: command ring buffer (mutex), client map (rwlock), atomics for token/mtime

**Frontend connection** ([WebSocketConnection.ts](../../frontend/src/core/WebSocketConnection.ts)):

- Fetches `/_/GET/EXTSTATE/Reamo/WebSocketPort` and `SessionToken` from REAPER's HTTP API
- 2-second timeout on EXTSTATE fetch (iOS PWA cold start can hang)
- Safari-specific workarounds: iframe pre-warmup, focus cycle, CONNECTING timeout
- Connects to `ws://${window.location.hostname}:${discoveredPort}/`

**Build pipeline** ([vite.config.ts](../../frontend/vite.config.ts), [package.json](../../frontend/package.json)):

- `viteSingleFile` plugin inlines all JS/CSS/assets into single HTML
- Build script: `vite build && cp dist/index.html ../reamo.html && cp assets ../`
- Output placed in REAPER's `reaper_www_root/` for its HTTP server to find

**Existing security** ([ws_server.zig](../../extension/src/server/ws_server.zig)):

- `isValidLocalHost()` validates Host header on WebSocket connections (DNS rebinding defense)
- Session token (16 random bytes, hex-encoded) validated in hello handshake
- Token stored in EXTSTATE, frontend fetches it via REAPER's HTTP API

---

## Target architecture (what we're building)

```
┌─────────────────────────────────────────────────┐
│  Zig extension HTTP + WebSocket server (:9224)  │
│  ├── Middleware: Host header validation (all)    │
│  ├── Middleware: security response headers (all) │
│  ├── GET /           → index.html (token in meta)│
│  ├── GET /assets/*   → JS/CSS (content-hashed)  │
│  ├── GET /manifest.* → PWA manifest + icons     │
│  └── GET /ws         → WebSocket upgrade         │
│      ├── Origin header validation                │
│      ├── hello handshake (token from HTML)       │
│      ├── command queue → REAPER main thread      │
│      └── state broadcast (unchanged)             │
└─────────────────────────────────────────────────┘
```

Single port. Single origin. Extension manages everything.

REAPER's built-in web server is no longer needed. Users don't touch Preferences > Control/OSC/Web.

---

## The httpz library

[karlseguin/http.zig](https://github.com/karlseguin/http.zig) (httpz) is by the same author as the websocket.zig library we already use. It wraps websocket.zig and adds HTTP routing, middleware, and request/response handling on top. Uses kqueue (macOS) / epoll (Linux) for non-blocking I/O.

### Key API patterns

**Server init + listen:**

```zig
const Handler = struct {
    pub const WebsocketHandler = WsClient;  // Required for WS support
    // ...
};

var handler = Handler{ .state = shared_state };
var server = try httpz.Server(*Handler).init(allocator, .{
    .port = 9224,
    .address = "0.0.0.0",
}, &handler);
defer server.deinit();

var router = try server.router(.{});
router.get("/", serveIndex, .{});
router.get("/assets/*", serveAssets, .{});
router.get("/ws", wsUpgrade, .{});

// Spawn in background thread (non-blocking, returns immediately)
const thread = try server.listenInNewThread();
// ... later: server.stop() to shut down
```

**WebSocket upgrade:**

```zig
fn wsUpgrade(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Validate Origin header here (before upgrade)
    if (!handler.validateOrigin(req)) {
        res.status = 403;
        res.body = "Invalid Origin";
        return;
    }
    const ctx = WsClient.Context{ .state = handler.state };
    if (try httpz.upgradeWebsocket(WsClient, req, res, &ctx) == false) {
        res.status = 400;
        res.body = "WebSocket upgrade failed";
    }
    // After upgrade, req/res are no longer safe to use
}
```

**Headers and response control:**

```zig
fn serveIndex(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // httpz auto-lowercases header names
    const host = req.header("host") orelse {
        res.status = 400;
        return;
    };
    // Full control over response headers
    res.header("X-Frame-Options", "DENY");
    res.header("Content-Security-Policy", "...");
    res.content_type = .HTML;
    res.body = handler.index_html;
}
```

**Middleware:**

```zig
const HostValidation = struct {
    pub fn execute(self: *const @This(), req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        const host = req.header("host") orelse { res.status = 400; return; };
        if (!isValidLocalHost(host)) { res.status = 403; return; }
        try executor.next();  // Continue to route handler
    }
};
```

**Threading:** Uses `listenInNewThread()` — spawns a background thread, exactly like our current `websocket.Server.listenInNewThread()`. Returns a thread handle; call `server.stop()` to signal shutdown. Compatible with REAPER's main loop model (extension keeps running timer callbacks on REAPER's thread, httpz runs on its own).

### Compatibility notes

- httpz includes websocket.zig as a dependency — we'd replace our direct websocket.zig dependency with httpz
- WebSocket handler pattern (`init`, `afterInit`, `clientMessage`) is the same as websocket.zig standalone
- Header names are auto-lowercased by httpz
- No built-in static file serving — we implement route handlers that read files or serve embedded content
- **Zig 0.15 compatibility: confirmed.** httpz master builds cleanly on Zig 0.15.2. README states it targets "latest stable of Zig (0.15.1)". No semver tags — pin a commit hash in `build.zig.zon`.
- **API note:** `Response.writer()` changed in 0.15 — requires a buffer argument (pass `&.{}` since httpz does its own buffering)

---

## Migration plan

### Guiding principles

- **Incremental chunks** — each step is buildable and testable in isolation
- **Backend first** — get HTTP serving working before changing the frontend
- **Maintain backwards compatibility during transition** — both servers can coexist temporarily
- **Pre-release** — no migration strategy needed for existing users, just careful refactoring

### Phase 1: Add httpz dependency, serve index.html

**Goal:** Extension serves the existing `reamo.html` via httpz on port 9224. REAPER's HTTP server still works on 8080. Both paths functional.

**Backend changes:**

1. Replace `websocket` dependency with `httpz` in `build.zig.zon` (httpz includes websocket.zig)
2. Update `build.zig` imports accordingly
3. Create `extension/src/server/http_server.zig`:
   - Define `Handler` struct (holds SharedState reference, index HTML content, CSRF token)
   - Implement `serveIndex` — reads `reamo.html` from disk (or embeds), injects CSRF token as `<meta name="reamo-token">` tag, serves with security headers
   - Implement `wsUpgrade` — validates Origin, calls `httpz.upgradeWebsocket()`
   - Implement `notFound` handler
4. Add Host header validation (extract existing `isValidLocalHost` from ws_server.zig into shared module)
5. Add all security response headers from [SECURITY.md](SECURITY.md) §4
6. Adapt `WsClient` (currently `Client` in ws_server.zig) to httpz's WebSocket handler interface:
   - `init(conn, ctx)` → replaces current `init(h, conn, state)` (see [WS handler adaptation](#websocket-handler-adaptation) for details — this is NOT a mechanical rename)
   - `clientMessage(allocator, data)` → same as current (note: takes allocator parameter)
   - `afterInit()` → moved from current init path
   - **Host validation moves out** — currently inside `Client.init()` via `Handshake` headers, must move to `wsUpgrade` HTTP route handler since httpz doesn't pass Handshake to WS handler
7. Wire into `main.zig` startup: replace `ws_server.startWithPortRetry()` with httpz server init + `listenInNewThread()`
8. Keep port retry logic (try 9224–9233)

**Testing (Phase 1):**

1. `host_validation.zig` unit tests — pure logic, easy to test. Cover: RFC1918 ranges, loopback, link-local, `0.0.0.0` rejection, port stripping, hostname/mDNS matching
2. Playwright E2E test — one test that fetches `http://localhost:9224/` and asserts security response headers are present (CSP, X-Frame-Options, CORP, COOP, etc.)
3. Manual smoke test with websocat — `websocat ws://localhost:9224/ws` → send hello JSON → verify handshake response

**What stays the same:**

- SharedState, command ring buffer, client management — unchanged
- All message protocol — unchanged
- Main thread timer loop, tiered polling, broadcast — unchanged
- Frontend — unchanged (still served from REAPER's port 8080, still discovers WS port via EXTSTATE)

**Verification:** Open `http://<ip>:9224/` in browser. See the React app. WebSocket connects. DAW control works. Security headers present in response. Meanwhile `http://<ip>:8080/reamo.html` still works too.

### Phase 2: Frontend same-origin connection

**Goal:** Frontend connects to WebSocket on the same origin it was served from. No more EXTSTATE port discovery.

**Frontend changes:**

Both WebSocket implementations must be updated — `WebSocketConnection.ts` (direct class) and `websocketMachine.ts` (XState v5 state machine for Safari zombie connection handling). Both independently fetch EXTSTATE today.

1. In both `WebSocketConnection.ts` and `websocketMachine.ts`: if served from the extension's HTTP server (detect by absence of REAPER's `/_/` API), connect to `ws://${window.location.host}/ws` directly
2. Read CSRF token from `<meta name="reamo-token">` tag (injected by server into HTML) instead of fetching from EXTSTATE:

   ```typescript
   const token = document.querySelector('meta[name="reamo-token"]')?.getAttribute('content');
   ```

3. Send token in hello message (already does this when token is available)
4. Remove or gate the EXTSTATE fetch behind a "legacy mode" check in both implementations
5. The iOS Safari iframe pre-warmup and focus cycle workarounds may no longer be needed (same-origin WS is more reliable) — test and remove if confirmed

**Backend changes:**

1. `serveIndex` injects `<meta name="reamo-token" content="${token}">` into the HTML `<head>` before serving. This avoids inline scripts entirely, keeping CSP `script-src 'self'` clean (industry standard pattern — Rails/Django both use `<meta>` for CSRF tokens).
2. Token no longer needs to be stored in EXTSTATE (but keep it there for backwards compat during transition)

**Verification:** Open `http://<ip>:9224/`. App connects to WS on same port. No EXTSTATE fetch in network tab. Token extracted from `<meta>` tag. Full DAW control. Test on iOS Safari PWA — confirm no hanging.

### Phase 3: Code splitting (remove viteSingleFile)

**Goal:** Frontend builds to separate HTML + JS + CSS files. Proper CSP. Content-hashed caching.

**Frontend changes:**

1. Remove `vite-plugin-singlefile` from vite.config.ts and package.json
2. Remove `assetsInlineLimit: 100000000` and `cssCodeSplit: false`
3. Configure Vite to output `dist/index.html` + `dist/assets/*.js` + `dist/assets/*.css`
4. Extract the inline `<style>` loading skeleton in `index.html` to an external CSS file (e.g., `loading.css`). This eliminates the last inline resource, allowing a clean `style-src 'self'` CSP with no `'unsafe-inline'` exceptions.
5. Update build script: copy `dist/` contents to a known location the extension can find

**Backend changes:**

1. Add `serveAssets` route handler: `GET /assets/*` → serve files from the frontend build output directory
   - Set `Content-Type` based on file extension (httpz has `ContentType.forFile()`)
   - Content-hashed filenames get `Cache-Control: public, max-age=31536000, immutable`
   - Add `X-Content-Type-Options: nosniff` and `Cross-Origin-Resource-Policy: same-origin`
2. `serveIndex` serves the HTML file with `Cache-Control: no-store`
3. Update CSP header: `script-src 'self'; style-src 'self'` — no inline exceptions needed. Token comes from `<meta>` tag (not inline script), loading skeleton CSS is now external.
4. Serve PWA manifest and icons: `GET /manifest.json`, `GET /icon-*.png`, `GET /icon.svg`

**Resolved: where do built files live?**

Research confirmed ReaPack's `@provides` tag supports distributing directories of files via glob patterns and the `[data]` qualifier, which installs to `<REAPER resource path>/Data/`. Helgobox (ReaLearn/Playtime) uses `Data/helgoboss/realearn/` for auxiliary data. No existing REAPER extension serves a web UI from disk files — REAmo is novel here.

**Decision: `<GetResourcePath()>/Data/REAmo/web/`** as the canonical location.

- Extension discovers it at startup via `GetResourcePath()` (already used for other REAPER API calls)
- ReaPack distributes files there via `@provides [data] web/*`
- Installer/manual install copies to the same location
- During development, frontend build copies `dist/*` there directly
- `@embedFile` is available as a fallback for single-binary distribution if needed, but not required since ReaPack handles subdirectories natively

**Verification:** `view-source:` shows `<script src="/assets/index-abc123.js">`. Network tab shows separate JS/CSS requests. Response headers include full security headers. `Cache-Control: immutable` on hashed assets. CSP uses `'self'` not `'unsafe-inline'`.

### Phase 4: Remove REAPER HTTP server dependency

**Goal:** Clean up all code that references REAPER's built-in web server.

**Changes:**

1. Remove `getWebInterfacePort()` from `network_action.zig` (no longer reads `reaper.ini` for HTTP port)
2. Update QR code / network address display to show `http://<ip>:9224/` (just the extension's port)
3. Remove EXTSTATE writes for `WebSocketPort` and `SessionToken` (no longer needed for frontend discovery)
4. Remove `reamo.html` copy step from frontend build script
5. Update README / installation instructions — no "enable REAPER web server" step
6. Remove hot-reload mtime polling for `reamo.html` (if using Option A, could keep for dev convenience, or replace with watching the `www/` directory)
7. Update `manifest.json` paths: `start_url` changes from `/reamo.html` to `/`

**Verification:** Fresh install. No REAPER web server configured. Extension loads. Open URL on phone. Everything works.

---

## Detailed change inventory

### Files that change

| File | Change | Phase |
|------|--------|-------|
| `extension/build.zig.zon` | Replace `websocket` dep with `httpz` | 1 |
| `extension/build.zig` | Update import path for httpz module | 1 |
| `extension/src/server/ws_server.zig` | Extract Host validation to shared module; adapt Client to httpz WS handler interface | 1 |
| `extension/src/server/http_server.zig` | **New file.** HTTP routes, static serving, security headers, middleware | 1 |
| `extension/src/server/host_validation.zig` | **New file.** Shared `isValidLocalHost` + Origin validation + unit tests | 1 |
| `extension/src/main.zig` | Replace ws_server startup with httpz server startup | 1 |
| `frontend/src/core/WebSocketConnection.ts` | Same-origin WS connection, read token from `<meta>` tag | 2 |
| `frontend/src/core/websocketMachine.ts` | Same changes as WebSocketConnection.ts (XState v5 state machine — handles Safari zombie connections) | 2 |
| `frontend/vite.config.ts` | Remove viteSingleFile, standard multi-file output | 3 |
| `frontend/package.json` | Remove `vite-plugin-singlefile` dep, update build script | 3 |
| `frontend/index.html` | Extract inline `<style>` loading skeleton to external CSS file | 3 |
| `extension/src/server/http_server.zig` | Add static file serving for `/assets/*`, manifests, icons | 3 |
| `extension/src/platform/network_action.zig` | Remove `getWebInterfacePort()`, update URL generation | 4 |
| `extension/src/main.zig` | Remove EXTSTATE writes for port/token, remove mtime polling | 4 |
| `README.md` | Remove "enable REAPER web server" instructions | 4 |
| `frontend/public/manifest.json` | Update `start_url` to `/` | 4 |

### Files that can be deleted after migration

| File | Reason |
|------|--------|
| `reamo.html` (in www_root) | No longer served by REAPER |
| `icon-*.png`, `icon.svg`, `manifest.json` (in www_root) | Served from extension's `www/` directory |
| `vite-plugin-singlefile` dep | No longer needed |

### Code that moves or is extracted

| Current location | New location | What |
|-----------------|--------------|------|
| `ws_server.zig:isValidLocalHost()` | `host_validation.zig` | Host header validation (shared between HTTP and WS) |
| `ws_server.zig:Client` | Adapted in-place or new `ws_handler.zig` | WebSocket client handler (adapted to httpz interface) |
| `ws_server.zig:SharedState` | Stays in `ws_server.zig` or moves to `shared_state.zig` | Thread-safe state (unchanged internally) |

---

## WebSocket handler adaptation

The biggest code change is adapting the current `Client` struct to httpz's `WebsocketHandler` interface. The current websocket.zig standalone API and the httpz-wrapped API use the same underlying pattern, but the init signature changes.

**Current (websocket.zig standalone):**

```zig
pub const Client = struct {
    id: usize,
    conn: *websocket.Conn,
    state: *SharedState,
    authenticated: bool,

    // Called by websocket.zig when connection opens
    // NOTE: actual signature is init(h: *const Handshake, conn, state)
    // Handshake is used to extract Host header for DNS rebinding defense
    pub fn init(h: *const websocket.Handshake, conn: *websocket.Conn, state: *SharedState) !Client {
        // Validates Host header via h.headers.get("host") → isValidLocalHost()
        // Rejects connections with missing or invalid Host
        const id = @intFromPtr(conn);
        state.addClient(id, conn);
        return Client{ .id = id, .conn = conn, .state = state, .authenticated = false };
    }

    pub fn clientMessage(self: *Client, allocator: Allocator, data: []const u8) !void { ... }
    pub fn close(self: *Client) void { ... }
};
```

**Target (httpz WebSocket handler):**

```zig
pub const WsClient = struct {
    id: usize,
    conn: *websocket.Conn,
    state: *SharedState,
    authenticated: bool,

    pub const Context = struct {
        state: *SharedState,
    };

    // Called by httpz during WebSocket upgrade
    // Host validation is NO LONGER HERE — it happens in the wsUpgrade HTTP
    // route handler (and Host middleware) BEFORE upgrade is initiated.
    // httpz does not pass Handshake headers to the WS handler.
    pub fn init(conn: *websocket.Conn, ctx: *const Context) !WsClient {
        const id = @intFromPtr(conn);
        ctx.state.addClient(id, conn);
        return WsClient{ .id = id, .conn = conn, .state = ctx.state, .authenticated = false };
    }

    pub fn clientMessage(self: *WsClient, allocator: Allocator, data: []const u8) !void {
        // Same implementation as current Client.clientMessage
    }

    pub fn close(self: *WsClient) void {
        // Same implementation as current Client.close
    }
};
```

This is **not** a mechanical rename. Two important changes beyond the signature:

1. **Host validation moves out.** Currently `Client.init()` reads the Host header from `Handshake` and calls `isValidLocalHost()`. In httpz, the WS handler's `init` is called *after* the HTTP upgrade — request headers are no longer accessible. Host validation must move to the `wsUpgrade` HTTP route handler (and/or the Host middleware that runs on all routes).

2. **`clientMessage` takes an `allocator` parameter.** Both the current and httpz versions pass an allocator — the plan's code examples should reflect this.

---

## Static file serving strategy

httpz has no built-in static file serving. We need to implement route handlers.

### Approach: read from disk, cache in memory

On server startup:

1. Scan the `www/` directory for all files
2. Read each file into a hash map: `path → { content, content_type, etag }`
3. For `index.html`: inject `<meta name="reamo-token" content="...">` into `<head>` before caching
4. Serve from memory — zero disk I/O per request

On file change (dev mode only):

- Optional: watch `www/` directory, reload changed files
- Or: restart extension to pick up changes (acceptable for dev)

```zig
const StaticFile = struct {
    content: []const u8,
    content_type: httpz.ContentType,
    cache_control: []const u8,
    etag: []const u8,
};

const FileCache = std.StringHashMap(StaticFile);
```

### Content types

```zig
fn contentTypeForExt(ext: []const u8) httpz.ContentType {
    if (mem.eql(u8, ext, ".html")) return .HTML;
    if (mem.eql(u8, ext, ".js"))   return .JS;
    if (mem.eql(u8, ext, ".css"))  return .CSS;
    if (mem.eql(u8, ext, ".json")) return .JSON;
    if (mem.eql(u8, ext, ".png"))  return .PNG;
    if (mem.eql(u8, ext, ".svg"))  return .SVG;
    return .BINARY;
}
```

### Cache headers

| File type | Cache-Control | Rationale |
|-----------|--------------|-----------|
| `index.html` | `no-store` | Contains CSRF token, must be fresh |
| `assets/*.js`, `assets/*.css` | `public, max-age=31536000, immutable` | Content-hashed filenames |
| `manifest.json` | `no-cache` | May change between versions |
| `icon-*.png`, `icon.svg` | `public, max-age=86400` | Stable but not hashed |

---

## Security implementation

All security measures from [SECURITY.md](SECURITY.md) become implementable once we control the HTTP server.

### Host header validation (all requests)

Extracted from current `ws_server.zig:isValidLocalHost()` into a shared module. Applied as middleware to every route.

```
Whitelist:
- 127.0.0.0/8 (loopback)
- 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 (private)
- 169.254.0.0/16 (link-local, for USB tethering)
- localhost, <hostname>, <hostname>.local
- Strip port suffix before matching

Explicitly REJECT:
- 0.0.0.0 (resolves to localhost on Linux/macOS — attack vector for public websites)
- Any public/routable IP
```

### Origin header validation (WebSocket upgrade)

Applied in the `wsUpgrade` route handler, before calling `httpz.upgradeWebsocket()`.

```
Rule: if Origin absent  → allow (non-browser client)
      if Origin = "null" → REJECT (sandboxed iframes, file:// contexts — never legitimate)
      if Origin present  → must match Host whitelist (prefixed with http://)
```

### Response headers (all HTTP responses)

```http
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; manifest-src 'self'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'; object-src 'none'
Referrer-Policy: no-referrer
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), bluetooth=()
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
```

CSP note: This CSP has **no `'unsafe-inline'` for scripts or styles**. This is achievable because:

- **Scripts:** CSRF token is delivered via `<meta>` tag, not inline `<script>`. All JS is external (code-split by Vite).
- **Styles:** Tailwind CSS v4 is zero-runtime — all utility CSS emits as external `.css` files. The loading skeleton `<style>` tag in `index.html` is extracted to an external CSS file in Phase 3.
- **`style-src-attr 'unsafe-inline'`:** Allows React's `style={{ color: trackColor }}` inline style *attributes* (used for dynamic REAPER track colors) while still blocking injected `<style>` *tags*. `style-src-attr` is supported in Chrome 75+, Firefox 105+, Safari 16.1+ — all within Tailwind v4's browser target. If we later confirm no component library injects inline style attributes, `style-src-attr` can be dropped entirely.

Note: During Phase 1–2 (while viteSingleFile is still in use), the CSP must use `script-src 'unsafe-inline'; style-src 'unsafe-inline'` since everything is inlined. The strict CSP above applies from Phase 3 onward.

### CSRF token

- Generated at startup: `std.crypto.random.bytes()` → 16 bytes → 32-char hex
- Injected into `index.html` as `<meta name="reamo-token" content="...">` in the `<head>`. Uses a `<meta>` tag instead of an inline `<script>` to avoid requiring `script-src 'unsafe-inline'` in CSP. This is the industry standard pattern (Rails, Django both use `<meta>` tags for CSRF tokens).
- Frontend reads via `document.querySelector('meta[name="reamo-token"]')?.getAttribute('content')` and sends in WebSocket hello
- Server validates in `clientMessage` on first message (existing logic, just reads from different source)

---

## Server configuration via Extensions menu

The declarative menu system ([menu_items.zig](../../extension/src/platform/menu_items.zig)) is already in place with `connection` and `settings` groups. Server configuration items slot naturally into the `settings` group.

### Port configuration

Currently the port is hardcoded as `DEFAULT_PORT = 9224` with auto-retry up to 9233. This should become user-configurable:

- **Menu item:** "Server Port..." → opens dialog (SWELL `GetUserInputs` or similar) to enter port number
- **Storage:** EXTSTATE `Reamo:ServerPort` with `persist = true` → survives REAPER restart
- **Startup behavior:** Read from EXTSTATE; if set, use that port (still auto-retry on conflict); if not set, use 9224 default
- **Restart required:** Changing port requires server restart. Either restart automatically or show "Restart REAPER to apply" message. Auto-restart is better UX — stop httpz server, re-init on new port, broadcast `reload` to any connected clients on old port first.

### IP allowlist / security presets

Currently `isValidLocalHost()` is hardcoded to accept RFC1918 + loopback + link-local. This maps to the "Solo" preset from [SECURITY.md](SECURITY.md) §7. Make it configurable:

- **Menu item:** "Security Mode" → submenu with three presets:
  - **Solo (default)** — Accept private IPs + loopback + link-local. Standard home/studio use.
  - **Lockdown** — Bind to `127.0.0.1` only. Same-machine browser access. Dual-monitor setups.
  - **Open** — No Host/Origin restrictions. For VPNs, Tailscale, non-RFC1918 subnets. Shows warning on selection.
- **Storage:** EXTSTATE `Reamo:SecurityPreset` (`solo` | `lockdown` | `open`)
- **Runtime behavior:** Read at startup, controls bind address and Host validation behavior. Menu shows checkmark on active preset.

### Planned menu structure after migration

```
Extensions > REAmo
├── Show Connection QR Code...        (connection group)
├── Show Network Addresses...         (connection group)
├── ──────────────────                (separator)
├── Server Port...                    (settings group)
├── Security Mode  ►                  (settings group, submenu)
│   ├── ✓ Solo (Home/Studio)
│   ├──   Lockdown (Local Only)
│   └──   Open (Advanced)
├── ──────────────────                (separator)
└── About REAmo                       (top-level)
```

This requires adding submenu support to the menu system — currently it only supports flat items. The submenu is a Phase 2+ concern; for Phase 1, flat toggle items work fine:

```
├── Security: Solo (Home/Studio)      ✓
├── Security: Lockdown (Local Only)
├── Security: Open (Advanced)
```

---

## Open questions requiring research

The following questions can't be answered by exploring the local codebase. They should be delegated to an external research query.

### ~~1. httpz + Zig 0.15 compatibility~~ — RESOLVED

Verified locally: httpz master builds cleanly on Zig 0.15.2. Pin the current master commit hash in `build.zig.zon`.

### ~~2. httpz thread safety with REAPER integration~~ — RESOLVED

Verified by reading httpz source. Key findings:

- **`listenInNewThread()`** blocks until server is ready (mutex + condvar), then returns `std.Thread`. Safe to use immediately after return.
- **`stop()`** is mutex-protected and safe to call from any thread. Closes the listening socket to unblock accept. Intended lifecycle: `init → listenInNewThread → stop → deinit`.
- **HTTP handlers and WS `clientMessage` both run on the same thread pool** — they CAN execute concurrently on different worker threads.
- **httpz provides NO synchronization for handler state** — the Handler is accessed from multiple threads and we must protect shared data ourselves.

**Impact on REAmo:** No new locking needed. HTTP handlers only read write-once data (file cache populated at startup, CSRF token generated at startup). SharedState already has proper synchronization (rwlock for clients, mutex for commands, atomics for token). No deadlock risk — HTTP handlers never acquire SharedState locks.

### ~~3. Frontend build output location for distribution~~ — RESOLVED

ReaPack's `@provides` tag supports distributing directories via glob patterns and a `[data]` qualifier that installs to `<REAPER resource path>/Data/`. Helgobox uses `Data/helgoboss/realearn/` for auxiliary files. No existing REAPER extension serves a web UI from disk — REAmo is novel here.

**Decision:** `<GetResourcePath()>/Data/REAmo/web/` is the canonical location. ReaPack distributes via `@provides [data] web/*`. `@embedFile` available as fallback but not needed.

### ~~4. PWA behavior on port change~~ — RESOLVED (pre-release non-issue)

Old PWA bookmarks (pointing at `:8080/reamo.html`) will break — the origin changes entirely. No manifest field or service worker trick can redirect across origins. For pre-release this is a non-issue. Post-launch, communicate port changes in release notes.

### ~~5. Tailwind CSS v4 + CSP~~ — RESOLVED

Tailwind CSS v4 is zero-runtime: all utility CSS emits as external `.css` files in production builds. `style-src 'self'` is sufficient. React CSR `style={{}}` uses individual property assignment (`element.style.color = value`) which is NOT blocked by CSP `style-src` restrictions — only `setAttribute('style')` and HTML `style=""` attributes are governed. If needed, CSP Level 3 `style-src-attr 'unsafe-inline'` allows inline style attributes while blocking `<style>` tags (supported Chrome 75+, Firefox 105+, Safari 16.1+).

### ~~6. Localhost HTTP server security~~ — RESOLVED

**No known browser attack bypasses Host + Origin validation simultaneously.** Research confirmed:

- DNS rebinding fails Host validation (Host header carries attacker's domain, not the local IP)
- Cross-origin requests fail Origin validation (Origin is a forbidden header, JS cannot forge it)
- Reject `Origin: null` explicitly (sandboxed iframes, `file://` contexts)
- Exclude `0.0.0.0` from Host allowlist (resolves to localhost on Linux/macOS, used in 0.0.0.0-day attacks)
- CSRF token in HTML is protected by CORB (blocks `text/html` via `<script>` tags), CORP (`same-origin` prevents cross-origin resource loads), and Site Isolation (Spectre mitigation)
- CSS `@import` exfiltration blocked: browsers reject cross-origin CSS with wrong Content-Type

**Chrome PNA → LNA update (Feb 2026):** Private Network Access has been replaced by Local Network Access (LNA). Chrome 142 shipped LNA with user-facing permission prompts (no server opt-in needed). WebSocket LNA restrictions planned for Chrome 147 (~March 2026). **Same-origin local scenarios (REAmo's model) are unaffected** — LNA only restricts public→private network requests. No need to implement PNA preflight headers (deprecated).

---

## Development workflow impact

### During migration (phases 1–2)

Both servers run simultaneously:

- REAPER HTTP on 8080 → serves old single-file HTML
- Extension httpz on 9224 → serves same HTML + WS

Developers can test both paths. Frontend has a "legacy mode" fallback.

### After migration (phases 3–4)

- `make frontend` builds to `<resource>/Data/REAmo/web/`
- Extension serves from `Data/REAmo/web/` at startup (discovered via `GetResourcePath()`)
- `make dev` runs Vite dev server on 5173 with proxy to extension's WS on 9224 (standard Vite proxy config)
- Hot reload during frontend dev: Vite serves directly, proxies WS to extension
- Production: extension serves built files

### Build pipeline changes

**Before:**

```bash
# Frontend
vite build → dist/index.html → cp to reamo.html in www_root

# Extension
zig build → install .dylib to UserPlugins
```

**After:**

```bash
# Frontend
vite build → dist/index.html + dist/assets/* → cp to <resource>/Data/REAmo/web/

# Extension
zig build → install .dylib to UserPlugins
# (Extension reads Data/REAmo/web/ via GetResourcePath() at startup)
```

---

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| ~~httpz doesn't build on Zig 0.15~~ | ~~Medium~~ | ~~Blocks migration~~ | **RESOLVED** — builds cleanly on 0.15.2 |
| WebSocket handler adaptation breaks protocol | Low | DAW control fails | Existing test suite covers message parsing; protocol is unchanged |
| Static file serving has performance issues | Low | Slow page loads | Files cached in memory; LAN latency is ~1ms; 891KB (or smaller split) is instant |
| Safari PWA port change breaks bookmarks | Low | Users must re-add PWA | Pre-release: non-issue. Post-launch: serve redirect |
| ~~Thread safety issues with shared HTTP+WS state~~ | ~~Low~~ | ~~Crashes or deadlocks~~ | **RESOLVED** — HTTP handlers read write-once data only; SharedState already has rwlock/mutex/atomics |
| ~~ReaPack can't distribute multi-file web content~~ | ~~Medium~~ | ~~Complicates distribution~~ | **RESOLVED** — ReaPack `@provides [data]` supports subdirectories natively |

---

## Immediate next steps

1. ~~**Verify httpz builds on Zig 0.15**~~ — **DONE.** Builds cleanly on 0.15.2.
2. ~~**Send research query**~~ — **DONE.** All questions resolved. See resolved sections above.
3. **Read httpz's WebSocket example** ([examples/08_websocket.zig](~/Dev/external/http.zig/examples/08_websocket.zig)) to confirm the handler adaptation approach.
4. **Prototype Phase 1**: add httpz dep, create http_server.zig, serve index.html on 9224, adapt WS handler. Verify both HTTP and WS work on single port.
