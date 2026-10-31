# REAmo security model

What the server inside the REAPER extension defends against, how, and what it
leaves open. To report a vulnerability, see [SECURITY.md](../../SECURITY.md).

## Threat model

- **Anyone who can load REAmo's page from the network controls REAPER.** There is no password; a client can run any registered action, including the user's ReaScripts. Being on the network is the only intended way in.
- **The threats defended against use the musician's own browser:** cross-site WebSocket hijacking (any web page can open `ws://<LAN IP>:9224/ws`), DNS rebinding, and pages reaching `0.0.0.0`.
- **Traffic is plain HTTP and WebSocket.** Anyone who can watch the network can read the session token.
- **The server enforces everything itself.** Browser protections such as Private Network Access are not relied on.

## Measures in place

Server code is in `extension/src/server/` unless a path says otherwise.

- **Host header validation** on `GET /`, `GET /ws` and static files; a missing Host is a 403 (`host_validation.zig` `isValidLocalHost`, `http_server.zig`). Blocks DNS rebinding. Accepted: `localhost`, `[::1]`, parsed IPv4 in `127/8`, `10/8`, `172.16/12`, `192.168/16`, `169.254/16`; any `*.local`; the machine's hostname and `<hostname>.local`; names from **Extensions > REAmo > Allowed Hosts** (16 names in all, the machine's two included, so 14 for the user). `0.0.0.0` and other IPv6 literals are refused.
- **Origin validation on the WebSocket upgrade** (`isValidOrigin`). Blocks cross-site hijacking. Absent Origin is allowed (non-browser clients), `null` is refused, otherwise it must pass the Host rules and equal the Host header.
- **Per-run session token**: 16 bytes from `std.crypto.random` at startup (`extension/src/main.zig`), never stored, injected as `<meta name="reamo-token">` into `GET /` (served `no-store`), and required in the client's first `hello` message (`ws_server.zig`). A cross-site page can't read the HTML, so it can't learn the token. Without a valid hello, commands get `NOT_AUTHENTICATED` and the socket gets no broadcasts. An `index.html` without `</head>` fails closed.
- **No cookies, no CORS headers.** Cookies would ride along on cross-site upgrades; no `Access-Control-Allow-Origin` keeps cross-origin reads blocked.
- **Security headers on `GET /`** (`http_server.zig` `setSecurityHeaders`): CSP with no `'unsafe-inline'` and `frame-ancestors 'none'` (`connect-src` allows `ws:`/`wss:` to any host), `X-Frame-Options: DENY`, `nosniff`, COOP and CORP `same-origin`, `Referrer-Policy: no-referrer`, a `Permissions-Policy` denying camera, microphone, geolocation, payment, USB and Bluetooth. Static files send `nosniff` and CORP only.
- **Static file paths**: any path containing `..` is refused; files are read only from the `reamo/` web directory, at most 4 MiB (`serveStatic`). httpz does not percent-decode, so `%2e%2e` stays literal.
- **ExtState access**: the generic `extstate/*` commands read and write one project key, `Reamo/CustomBanks` (at most 16384 bytes); everything else gets `FORBIDDEN` (`extension/src/commands/extstate.zig`). Playlist commands also write their own `Reamo/*` project keys (`extension/src/state/playlist.zig`). No command writes global ExtState directly, so Allowed Hosts and the port can't be changed that way; a client that runs a ReaScript action can still do anything a script can (see Threat model).
- **Timeouts and caps**: 5 s header-read and keep-alive timeouts, 64 HTTP connections, 64 WebSocket clients (close 4500 when full), 64 KiB WebSocket messages (websocket.zig default), 4096 queued commands or 8 MiB then `QUEUE_FULL` (`http_server.zig`, `ws_server.zig`). Short keep-alive stops a web page parking idle sockets to lock real clients out.
- **QR code carries only the URL**, never the token (**Extensions > REAmo > Show Connection QR Code**).
- **Pinned dependencies**: httpz is pinned by commit and hash in `extension/build.zig.zon`, websocket.zig in httpz's own `build.zig.zon`.
- **Installer** (`installer/Install_REAmo.lua`) copies files from the extracted zip only; it downloads nothing.
- **Release pipeline** (`.github/workflows/release.yml`): read-only token by default; only the attest job can mint an OIDC token. Each zip gets a `.sha256` file and a signed build provenance attestation.

## Considered and not done

- **TLS**: public CAs won't issue certificates for LAN IPs or `.local`, and self-signed certificates mean a warning (or iOS profile install) on every device.
- **Password or login**: the page is for the whole band in a rehearsal room; network presence is the authorization.
- **"Lockdown" and "Open" network presets**: dropped. Refusing public source addresses (below) closes the gap they were meant to.
- **Per-IP connection caps, message rate limits, WebSocket idle timeout**: not built; global caps cover the browser-driven case.
- **Rejecting clients with a public source IP**: planned, on by default; until then see the first gap below.
- **Code signing and notarization** of the binaries: not done; attestations cover provenance.

## Known gaps

- **Medium:** the server binds `0.0.0.0` (the `.address` setting in `extension/src/server/http_server.zig`) and only checks the Host header, which a non-browser client sets freely. If a router forwards the port, anyone on the internet can send `Host: 192.168.1.50`, fetch the token and take control. Use a VPN such as Tailscale and add its name under Allowed Hosts instead.
- **Medium:** no TLS, so the token and all control traffic are readable on the LAN (accepted, see above).
- **Low:** any web page can learn REAmo is running on a LAN address it guesses: a no-cors request gets a response even when it's refused. `GET /api/ping` also skips Host validation, so a rebinding page can read it, but the body is a constant `{"ok":true}`.
- **Low:** static files have no CSP or frame headers. `/index.html` can be framed, but that copy has no token and can't connect.
- **Low:** any `*.local` Host is accepted. On networks whose unicast DNS answers `.local` (some Active Directory setups) a name there could rebind.
- **Low:** the token is compared with `std.mem.eql` (not constant time); a browser can't measure it and the Origin check stops it first.
- **Low:** `validateToken` allows every client while no token is set. Unreachable today because the token is set before the server listens; keep that ordering.
