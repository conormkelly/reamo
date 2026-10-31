# HTTP server

The extension serves the web app and the WebSocket on one port, from `extension/src/server/http_server.zig`. Threats, measures and known gaps: [SECURITY.md](SECURITY.md). Library and fork workflow: [DEVELOPMENT.md, Server libraries (forked)](../../DEVELOPMENT.md#server-libraries-forked).

## What it does

- **Library:** httpz (http.zig, which embeds websocket.zig), pinned to the `conormkelly/http.zig` fork in `extension/build.zig.zon`. The fork carries fixes upstream lacks: Windows socket handling, write backpressure, TCP_NODELAY on accepted sockets, and safe shutdown while clients are connecting.
- **Port:** 9224 by default, or the one set with **Extensions > REAmo > Change Server Port...** (ExtState `Reamo/ServerPort`). If it's taken, the next nine are tried. Changing it asks first (phones need the new address and lose what they saved under the old one), then restarts the server and shows the address phones open.
- **Routes:**
  - `GET /`: `reamo/index.html` with the session token injected as `<meta name="reamo-token">` before `</head>`, plus the security headers. Served from memory; in dev mode (`make dev-extension`) read from disk on every request.
  - `GET /api/ping`: constant `{"ok":true}`, fetched before opening the WebSocket to wake Safari's lazy network stack.
  - `GET /ws`: WebSocket upgrade.
  - `GET /*`: static files from `reaper_www_root/reamo/`. `assets/*` (content-hashed) get `Cache-Control: public, max-age=31536000, immutable`; everything else `no-store`. `nosniff` and CORP only.
- **Validation order on `/ws`:** Host header (missing or not local: 403), then Origin (absent allowed, `null` refused, otherwise must be local and equal the Host), then upgrade. The token is checked in the client's first `hello` message.
- **CSP on `GET /`:** `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; manifest-src 'self'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'; object-src 'none'`. Also `X-Frame-Options: DENY`, `nosniff`, `no-store`, COOP and CORP `same-origin`, `Referrer-Policy: no-referrer`, and a `Permissions-Policy` denying camera, microphone, geolocation, payment, USB and Bluetooth.
- **Send buffer:** each WebSocket gets `SO_SNDBUF` 4 MiB so large messages (the action list, ~1.1 MB) go out in one write. Output the socket can't take yet is queued and drained, never dropped.
- **Reload on change:** every ~2 s the main loop checks `index.html`'s mtime; on change it reloads the cached HTML and broadcasts a `reload` event.

## Why it's built this way

- **One port, one origin:** no port discovery (fetching it from REAPER's web server hung on iOS cold start), and CSP `'self'` and the security headers become possible. REAPER's own web server isn't needed.
- **Token in a `<meta>` tag, not an inline script:** keeps `script-src 'self'` free of `'unsafe-inline'`. A cross-site page can't read the HTML, so it can't learn the token.
- **No `'unsafe-inline'` for styles:** React's `style={{}}` sets properties through CSSOM, which CSP doesn't block.
- **Host validation in the upgrade route:** httpz doesn't pass the handshake headers to the WebSocket handler, so it has to happen before `upgradeWebsocket`.
- **Reject `Origin: null` and the `0.0.0.0` Host:** sandboxed iframes and `file://` pages send `null`; `0.0.0.0` reaches localhost on macOS and Linux from a public page.
- **Handler state is write-once or locked:** httpz runs HTTP handlers and WebSocket `clientMessage` concurrently on a thread pool with no synchronisation of its own. HTTP handlers read only startup data and the HTML cache; `SharedState` has its own locks.
- **Own folder, `reaper_www_root/reamo/`:** other web control surfaces share `reaper_www_root/`, so the installer and uninstaller only ever touch REAmo's folder.
- **Chrome's Local Network Access** doesn't affect same-origin use on the LAN.

## Deliberately not done

- **Security presets (loopback-only "Lockdown", unchecked "Open"):** dropped; Allowed Hosts covers VPN names, and refusing public source addresses is planned (see SECURITY.md).
- **Percent-decoding static paths:** httpz doesn't, so `%2e%2e` stays literal; any path containing `..` is refused.

## Known gaps

- Clients on the old port aren't told to reload when the port changes; they have to reconnect by hand.
- Only `index.html`'s mtime is watched. A changed file elsewhere in `reamo/` (icons, manifest) doesn't reload clients.
- The iOS Safari iframe warm-up and focus-cycle workarounds (`frontend/src/core/websocketMachine.ts`) may be unnecessary with a same-origin WebSocket; untested.
