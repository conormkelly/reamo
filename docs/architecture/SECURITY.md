# REAmo security model: threat analysis and defense architecture (v2)

**REAmo's greatest risks come not from the local network but from the browser.** A musician simply browsing the web while REAPER runs can expose their entire session to remote attackers through cross-site WebSocket hijacking (CSWSH) and DNS rebinding — two well-documented attack classes that exploit the fact that WebSocket connections bypass the same-origin policy entirely. The good news: a layered defense of **Host header validation on all requests**, **Origin checking on WebSocket upgrades**, and a **CSRF-style token embedded in the served HTML** blocks every known browser-based attack vector, adds zero user friction, and aligns with how the most successful local-network tools (Home Assistant, OctoPrint, TouchOSC) approach the problem.

## 1. Threat model: browser-based attacks dominate the risk landscape

The intuitive threat — someone on your WiFi connecting directly — is actually the *least* interesting attack. The realistic threats exploit the musician's browser as a proxy, reaching REAmo indirectly through malicious websites or compromised ads.

**Cross-site WebSocket hijacking is the top threat.** WebSocket connections are not restricted by the same-origin policy. Any website a musician visits can execute `new WebSocket('ws://192.168.1.50:9224')` and, if the server accepts it, gain full bidirectional DAW control. The browser sends an `Origin` header (e.g., `Origin: https://evil.com`), but **the server must actively validate it** — there is no automatic browser enforcement. Real-world precedents include MeshCentral (full account takeover via CSWSH, GHSA-cp68-qrhr-g9h8) and Gitpod's 2023 critical vulnerability. The attack requires zero sophistication: a single line of JavaScript in a malicious ad.

**DNS rebinding is the second critical threat.** An attacker controlling `evil-rebind.com` sets a short TTL, serves malicious JavaScript, then rebinds the domain to the musician's LAN IP. After rebinding, the browser considers subsequent requests same-origin, granting the attacker full read access to HTTP responses and same-origin WebSocket connections. Tools like NCC Group's Singularity automate this in ~3 seconds. Real-world CVEs include Ollama (CVE-2024-28224), Sonos speakers (CVE-2018-11316), Radio Thermostat (CVE-2018-11315), SpaceX Starlink router (CVE-2023-52235), and Adobe Brackets (DNS rebinding → WebSocket hijacking → native code execution). **Without TLS, DNS rebinding is particularly dangerous** because there's no certificate mismatch to prevent the rebound — see section 9 for why TLS is impractical and why Host header validation is the correct alternative.

**The 0.0.0.0 Day vulnerability** (Oligo Security, August 2024) allowed public websites to reach services bound to `0.0.0.0` by requesting `http://0.0.0.0:PORT`. Chrome blocked this starting in version 128, Safari patched in iOS 18/macOS Sequoia, but **Firefox has no fix yet**. Even with `0.0.0.0` blocked, DNS rebinding to `192.168.x.x` remains viable.

Additional threats, ordered by risk, include browser-based LAN scanning via WebRTC IP leaks and timing-based port probes; direct access on public WiFi or shared studio networks; ARP spoofing/MitM (all traffic is plaintext HTTP/WS); mDNS service discovery enabling targeted attacks; and UPnP accidentally forwarding port 9224 to the internet (over 20,000 OctoPrint instances have been found exposed on the internet via Shodan, many through accidental UPnP mappings).

| Threat | Likelihood | Impact | Complexity | Overall |
|--------|-----------|--------|------------|---------|
| Cross-site WebSocket hijacking | High | Critical | Low | **Critical** |
| DNS rebinding | Med-High | Critical | Medium | **Critical** |
| 0.0.0.0 Day / browser drive-by | Med-High | Critical | Low | **Critical** |
| Browser LAN scanning + CSRF | Medium | High | Low-Med | **High** |
| Public WiFi direct access | Medium | Critical | Low | **High** |
| ARP spoofing / MitM | Low-Med | Critical | Medium | Medium-High |
| UPnP accidental exposure | Low-Med | Critical | Low | Medium |
| mDNS service discovery | Medium | Medium | Low | Medium |

**Chrome's Private Network Access (PNA) cannot be relied upon.** PNA is not implemented in Firefox, only partially enforced in Chrome with repeatedly delayed rollout, and has incomplete WebSocket coverage. REAmo must implement its own server-side defenses.

## 2. DNS rebinding defense: Host + Origin validation is the complete solution

The defense architecture rests on one critical insight: **after DNS rebinding, the browser sends `Host: evil.com:9224`, not the victim's IP address.** This means a server that validates the Host header against a whitelist of known-local values will reject every DNS-rebinding request. This is confirmed by NCC Group, Palo Alto Unit 42, Brannon Dorsey's seminal 2018 research, and the GitHub Security Blog.

**Host header validation must apply to ALL requests — both HTTP and WebSocket.** If the server checks Host only on WebSocket upgrades but not on HTTP, an attacker can use DNS rebinding to fetch the HTML page (extracting tokens, reading API responses, learning internal structure) even though the WebSocket upgrade would be blocked. This exact gap was the root cause of CVE-2025-56648 in Parcel's dev server. A DNS-rebinding attacker with HTTP-only access can read all HTTP responses (same-origin after rebinding), extract CSRF tokens, and invoke any HTTP-based API endpoints.

Origin checking provides the complementary layer. For a direct cross-origin attack (evil.com opening `ws://192.168.1.50:9224`), the Host header *passes* the whitelist (`Host: 192.168.1.50:9224` is a valid local address) but the Origin header (`Origin: https://evil.com`) does not. Combined, the two checks cover all browser-based attack scenarios:

| Attack | Host header | Origin header | Result |
|--------|------------|---------------|--------|
| DNS rebinding | `evil.com:9224` ❌ | `http://evil.com:9224` ❌ | **Blocked** |
| Direct cross-origin CSWSH | `192.168.1.50:9224` ✅ | `https://evil.com` ❌ | **Blocked** |
| Legitimate same-origin | `192.168.1.50:9224` ✅ | `http://192.168.1.50:9224` ✅ | **Allowed** |
| Non-browser client (curl, etc.) | Forged ✅ | Forged ✅ | **Allowed** (LAN access = authorized) |

**No known browser-based attack bypasses both Host and Origin checking simultaneously.** Non-browser clients (curl, scripts, malware) can forge both headers, but they require existing local network access — a fundamentally different threat model where network presence is already treated as authorization.

The Host header whitelist should cover all legitimate access patterns:

- **IPv4**: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `0.0.0.0`
- **IPv6**: `::1`, `fe80::/10` (link-local), `fc00::/7` (ULA), `::ffff:0:0/96` (mapped IPv4 — normalize and check inner address)
- **Hostnames**: `localhost`, the machine's actual hostname, `<hostname>.local` (mDNS)

Auto-detect the machine's hostname at startup and add it dynamically. Strip the port suffix before matching (Host headers include `:<port>`). The `Origin` header similarly includes scheme and port (`http://192.168.1.50:9224`), so build the expected-origin list from the same whitelist prefixed with `http://`.

**Origin validation for WebSocket must also allow absent Origin headers.** Non-browser clients (native apps, CLI tools, `websocat`) don't send Origin headers. The rule is: if Origin is present, it must match the whitelist; if absent, allow the connection. This matches RFC 6455 §10.2's intent.

## 3. Authentication model: CSRF token in HTML, validated on WebSocket hello

The token bootstrap problem — if the server serves the HTML that contains the token, anyone who HTTP GETs the page gets the token — is real but **only matters for direct LAN attackers**. For browser-based attackers (the primary threat), the token provides genuine security because:

1. **Same-origin policy blocks cross-origin reads.** A malicious page at `https://evil.com` cannot read the response from `http://192.168.1.50:9224/` — the browser enforces SOP on the HTTP response. The attacker can *send* a request (via `<img>`, `fetch`, etc.) but cannot *read* the response body to extract the token. This is why no `Access-Control-Allow-Origin` header should be set (see section 4) — the browser's default behavior (block cross-origin reads) is exactly the defense you want.
2. **DNS rebinding is blocked by Host header validation** before the HTML (and token) can be served.
3. **WebSocket Origin checking** blocks cross-origin upgrade attempts independently of the token.

**The recommended v1 pattern:**

1. Server generates a cryptographically random token at startup via `std.crypto.random.bytes()` — 16 bytes, hex-encoded to 32 characters
2. Token is regenerated each time REAPER starts (not persisted across sessions)
3. Token is embedded in the served HTML page (e.g., in a `<meta>` tag or a script variable: `window.__REAMO_TOKEN = "a3f8..."`)
4. The React SPA reads the token and sends it as the first WebSocket message (`{"type":"hello","token":"a3f8..."}`)
5. Server validates the token before accepting any WebSocket commands
6. **No cookies, no session management, no expiry tracking.** Token in HTML → WS hello. That's it.

This three-layer defense (Host validation blocks DNS rebinding, Origin validation blocks CSWSH, token blocks any residual browser attack that somehow gets a WebSocket connection open without having fetched the page) provides defense-in-depth where each layer independently blocks a different attack class.

**Do not use cookies for v1.** Browsers send cookies on cross-origin WebSocket upgrade requests, which means a cookie set by REAmo would be sent along with an attacker's CSWSH attempt. This is why PortSwigger's Web Security Academy explicitly documents CSWSH as arising "when the WebSocket handshake request relies solely on HTTP cookies for session handling." Introducing cookies adds session management complexity while creating a false sense of security. The CSRF token in HTML is simpler and more robust.

**Industry precedent strongly supports the no-password approach.** TouchOSC, the dominant OSC control surface, uses zero authentication. The OSC protocol itself has no authentication layer. Home Assistant offers "trusted networks" mode that auto-logs in LAN users. Node-RED ships with no authentication by default. Chromecast and AirPlay treat same-network presence as authorization. **Adding a password would be a competitive disadvantage with no proportionate security benefit for home/studio use.**

## 4. HTTP security headers

Every HTTP response serving the React PWA should include these headers:

```http
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; manifest-src 'self'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'; object-src 'none'
Referrer-Policy: no-referrer
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), bluetooth=()
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
Cache-Control: no-store
```

**Do NOT set `Access-Control-Allow-Origin`.** Not `*`, not a dynamic value — omit the header entirely. The browser's default same-origin policy (block cross-origin reads when no CORS header is present) is exactly the behavior REAmo needs. Setting `ACAO: *` would allow any cross-origin page to read REAmo's HTTP responses, which directly undermines the CSRF token defense: an attacker's page could `fetch('http://192.168.1.50:9224/')`, read the HTML, extract the embedded token, and use it. Without ACAO, the browser blocks the read and the token stays secret from cross-origin attackers. There is no legitimate reason for a cross-origin page to fetch REAmo's resources.

**`frame-ancestors 'none'` and `X-Frame-Options: DENY` are critical**, not merely best-practice. Home Assistant had a critical-severity vulnerability (2023) specifically from missing X-Frame-Options, enabling clickjacking and iframe-based DNS rebinding. REAmo has no legitimate reason to be embedded in any iframe. Both headers should be set for defense-in-depth: `frame-ancestors` in CSP supersedes `X-Frame-Options` in modern browsers, but the latter provides fallback for older ones.

**CSP `script-src` must be `'unsafe-inline'` for the current build.** The React app is built via Vite's `viteSingleFile` plugin, which inlines all JavaScript into the HTML. `script-src 'self'` would block execution entirely. Two paths forward:

- **v1 (now):** Use `script-src 'unsafe-inline'`. This weakens XSS protection but is acceptable because the HTML is generated at build time, not from user input, and there are no user-supplied content injection points.
- **v2 (recommended migration):** Now that the extension serves HTTP directly (rather than through REAPER's single-file web server), restructure the Vite build to emit separate JS/CSS files. Then use `script-src 'self'; style-src 'self'` for proper CSP. The single-file constraint only existed because REAPER's built-in web server couldn't serve multiple files — that constraint is gone in the new architecture.

**CSP `connect-src` must explicitly allow WebSocket.** While CSP Level 3 theoretically allows `'self'` to match `ws://` when served over HTTP, explicit `ws: wss:` is more reliable across browsers. The `style-src 'unsafe-inline'` is required if the React app uses CSS-in-JS (styled-components, emotion); same migration path as `script-src`.

**`Cross-Origin-Opener-Policy: same-origin`** isolates REAmo's browsing context, preventing other windows or tabs (including attacker pages) from obtaining a reference to it. **`Cross-Origin-Resource-Policy: same-origin`** prevents any other origin from loading REAmo's resources via `<script>`, `<img>`, etc., mitigating Spectre-style side-channel attacks.

If the build is migrated to emit separate asset files with content-hashed filenames, those can use different caching:
```http
X-Content-Type-Options: nosniff
Cross-Origin-Resource-Policy: same-origin
Cache-Control: public, max-age=31536000, immutable
```

## 5. Rate limiting and DoS: lightweight protection against accidental exposure

Rate limiting on a home LAN is primarily insurance against **accidental internet exposure** (UPnP, manual port forwarding) and **malfunctioning clients**, not sophisticated attackers. The implementation should be lightweight.

**Connection limits** form the first tier. Allow **10 concurrent HTTP connections per IP** (a musician might use phone + tablet + laptop, each needing 1–2 connections; 10 is generous), **4 concurrent WebSocket connections per IP** (one per device/tab), and **50 total connections** across all clients. A home studio will never have 50 devices; this cap exists purely for resource exhaustion protection.

**Timeouts are the most important DoS defense.** A **5-second HTTP header read timeout** is the single most effective Slowloris mitigation — LAN latency is under 1ms, so 5 seconds is extremely generous for legitimate clients. Set HTTP keep-alive timeout to **30 seconds**, WebSocket ping interval to **30 seconds** with a **10-second pong timeout**, and WebSocket inactivity timeout to **5 minutes**. Maximum HTTP header size should be **8 KB** and maximum WebSocket message size **64 KB** (DAW control messages are typically under 1 KB of JSON).

**WebSocket message rate limiting** requires care. Rapid fader movements during mixing can generate **30–60 messages per second** from a single client. A limit of **100 messages/second per connection** accommodates aggressive multi-fader manipulation while capping abuse. Use a token bucket algorithm with a burst allowance of 200.

**Public IP detection** adds a valuable safety net. If the server receives a connection from a non-RFC1918 source IP, log a warning and optionally display a notification in REAPER: "⚠️ REAmo received a connection from a public IP address. Your port may be exposed to the internet." This catches accidental UPnP or port-forwarding exposure early.

| Protection | Value | Priority |
|-----------|-------|----------|
| HTTP header read timeout | 5 seconds | **Must-have** |
| Per-IP HTTP connections | 10 | Must-have |
| Per-IP WebSocket connections | 4 | Must-have |
| Total connections | 50 | Must-have |
| Max HTTP header size | 8 KB | Must-have |
| Max WebSocket message size | 64 KB | Must-have |
| WebSocket ping/pong | 30s / 10s timeout | Must-have |
| WebSocket inactivity timeout | 5 minutes | Recommended |
| WS message rate limit | 100/sec per connection | Recommended |
| Public IP source detection | Log + optional warning | Recommended |

## 6. Same-port implementation with karlseguin/http.zig

RFC 6455 was explicitly designed for port sharing: the opening handshake is an HTTP upgrade, so HTTP and WebSocket naturally coexist on one port. Same-port is clearly the right choice for REAmo — musicians get one URL, the SPA connects to `ws://${window.location.host}/ws` with zero configuration, and there's a single firewall rule to manage.

**The recommended stack is karlseguin/http.zig (httpz), which natively integrates websocket.zig.** Both libraries are by the same author. The current codebase already uses websocket.zig directly, so this is a migration to the parent library that wraps it with HTTP routing. httpz uses epoll (Linux) and kqueue (macOS) rather than Zig's `std.http.Server`.

**Before committing to this migration:** verify that httpz's master branch tracks Zig 0.15.x (it has historically tracked recent Zig versions, but pin a commit hash in `build.zig.zon` rather than following master). Test the WebSocket upgrade path with your existing message protocol. The migration should be incremental: get HTTP serving working first, then port the WebSocket handler.

The integration pattern:

```zig
var server = try httpz.Server(Handler).init(allocator, .{ .port = 9224 }, .{});
var router = try server.router(.{});
router.get("/", serveIndex, .{});          // React PWA (inline HTML)
router.get("/assets/*", serveStatic, .{}); // Static assets (if build is split)
router.get("/ws", wsUpgrade, .{});         // WebSocket endpoint
try server.listen();
```

The WebSocket upgrade handler calls `httpz.upgradeWebsocket()`. The `init` callback on the WebSocket handler is called *before* the handshake response is sent — this is where Host/Origin validation and token checking belong. Returning an error from `init` rejects the connection.

**Host/Origin validation should happen in a shared middleware or at the top of every route handler**, not only in the WebSocket upgrade path. Every HTTP response must validate the Host header before serving content (including the HTML page with the embedded token).

This pattern mirrors how every major framework handles it: Node.js `ws` attaches to an HTTP server and handles the `upgrade` event; Go's gorilla/websocket provides an `Upgrader` within standard HTTP handlers; Rust's tokio-tungstenite integrates with hyper's HTTP layer. httpz follows the same proven architecture.

## 7. Configuration defaults and security presets

Three presets cover all realistic scenarios without overwhelming musicians:

**"Solo" mode (default)** binds to `0.0.0.0:9224` with Host header validation, Origin checking, private-IP source filtering, and the CSRF token mechanism. This lets a musician pick up their phone on the same WiFi and control REAPER immediately, while blocking all browser-based attacks and internet access. This should be the out-of-box experience with zero configuration.

**"Lockdown" mode** binds to `127.0.0.1` — same-machine browser access only. Useful for dual-monitor setups where the musician wants a browser-based UI without any network exposure.

**"Open" mode** binds to `0.0.0.0` with no Host/Origin restrictions. For advanced users with unusual network topologies (VPNs, non-RFC1918 subnets, Tailscale). Display a warning when selected.

Store configuration in **REAPER EXTSTATE** under a `[REAmo]` section with `persist = true`. This integrates with REAPER's ecosystem, survives restarts (stored in `reaper-extstate.ini`), and allows other scripts to query REAmo's state. Key settings: `bind_address`, `port`, `security_preset`, `auto_start`. For the port, default to **9224** (avoids conflict with REAPER's built-in web interface on 8080) and make it configurable but not prominently exposed.

The **first-run experience** should require zero steps: extension loads with REAPER → server starts on `0.0.0.0:9224` → REAPER displays a brief notification with the URL and/or QR code → musician opens URL on phone → done. Auto-detect the machine's LAN IP for display. The React PWA connects to `ws://${window.location.host}/ws` automatically, making the connection IP-agnostic.

## 8. QR code pairing

**"Scan QR = get access" is the industry standard for local device pairing** and entirely acceptable for studio/rehearsal use. Chromecast, AirPlay, Spotify Connect, Wi-Fi sharing (built into Android and iOS), and Microsoft Phone Link all use this model. TouchOSC doesn't even have that — users manually enter IP addresses.

**v1 QR flow:** The QR code simply encodes `http://<local-ip>:9224/`. The musician opens the URL, gets the HTML (with embedded CSRF token), the SPA connects via WebSocket with the token, done. No one-time tokens, no cookie exchange, no expiry logic. The QR code is a convenience shortcut for "type this URL on your phone." Anyone who can reach the URL — whether by scanning the QR or by typing the IP — gets the same access. This is the correct model when LAN presence = authorization.

**The QR code effectively gives anyone who scans it full access to the REAPER session.** In a band rehearsal, someone showing the QR code on a shared screen lets everyone connect. This is a feature, not a bug — it's the same model as sharing a WiFi QR code.

**Future consideration (not v1):** For shared studio or venue scenarios where the "anyone on the network" model is too permissive, a "venue mode" could add a short-lived PIN or per-device approval. This would be a separate security preset, not a modification of the default flow. Don't build it until someone asks for it.

## 9. Why not TLS?

TLS would be the single most impactful security measure — it would break DNS rebinding (certificate mismatch), prevent MitM/ARP spoofing, and encrypt all traffic. It is also **impractical for a local-network service aimed at musicians:**

- **No domain = no certificates.** Let's Encrypt and other CAs don't issue certificates for private IPs or `.local` hostnames. The only option is self-signed certificates.
- **Self-signed = browser warnings.** Every browser shows a full-page security warning for self-signed certs. Musicians would need to click through "Your connection is not private" → "Advanced" → "Proceed to 192.168.1.50 (unsafe)" on every device, every session (browsers don't persistently trust self-signed certs for IPs). This is an unacceptable UX for the target audience.
- **Certificate management is a non-starter.** Generating, distributing, and trusting a custom CA root is reasonable for developers; it's not reasonable for musicians setting up a rehearsal.
- **iOS Safari is especially hostile** to self-signed certs, requiring a multi-step profile installation process.

The Host + Origin + token defense stack achieves the same protection against browser-based attacks (which are the dominant threat) without any of this friction. The residual risks that TLS would additionally address (MitM on the LAN, traffic sniffing) require an attacker with physical or ARP-level access to the network — a threat level where the attacker has far more damaging options available regardless.

**If TLS becomes feasible** (e.g., Zig gains a stable TLS server, or a lightweight embedded TLS library like BearSSL is integrated), it could be offered as an opt-in for advanced users. But it should never be the default or a prerequisite.

## Summary: the complete defense stack

| Layer | What it blocks | Implementation |
|-------|---------------|----------------|
| **Host header validation (all requests)** | DNS rebinding | Whitelist private IPs + localhost + hostname |
| **Origin header validation (WS upgrade)** | Cross-site WebSocket hijacking | Whitelist matching Host whitelist; allow absent Origin |
| **CSRF token in HTML → WS hello** | Residual browser attacks; naive scripted access | 16 random bytes, hex-encoded, regenerated per REAPER session |
| **No CORS headers** | Cross-origin token extraction | Browser default SOP blocks reads |
| **`frame-ancestors 'none'`** | Clickjacking, iframe-based DNS rebinding | CSP + X-Frame-Options: DENY |
| **`Cross-Origin-Opener-Policy`** | Window reference attacks | `same-origin` |
| **Connection limits + timeouts** | DoS, Slowloris, accidental exposure | Per-IP caps, 5s header timeout |

Each layer is independently useful and blocks a distinct attack class. No layer requires user interaction. The musician's experience is: install extension → open URL on phone → control REAPER.
