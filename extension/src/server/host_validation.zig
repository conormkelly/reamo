const std = @import("std");

/// Maximum number of user-configured allowed hostnames.
/// Covers machine hostname, hostname.local, Tailscale names, VPN hostnames, etc.
const MAX_ALLOWED_HOSTS = 16;

/// Maximum hostname length (RFC 1035: 253 chars, but we use a practical limit).
const MAX_HOST_LEN = 128;

/// Fixed storage for allowed hostnames. No allocator needed — hostnames are short
/// and the count is bounded. Each entry stores the hostname without port.
var g_allowed_hosts: [MAX_ALLOWED_HOSTS][MAX_HOST_LEN]u8 = undefined;
var g_allowed_lens: [MAX_ALLOWED_HOSTS]u8 = [_]u8{0} ** MAX_ALLOWED_HOSTS;
var g_allowed_count: usize = 0;

/// Add a hostname to the allowed list.
/// The hostname should NOT include a port (e.g., "mypc", "mypc.local", "mypc.tailnet.ts.net").
/// Duplicate hostnames are silently ignored. Returns false if the list is full.
pub fn addAllowedHost(hostname: []const u8) bool {
    if (hostname.len == 0 or hostname.len > MAX_HOST_LEN) return false;

    // Check for duplicate
    for (0..g_allowed_count) |i| {
        const existing = g_allowed_hosts[i][0..g_allowed_lens[i]];
        if (std.mem.eql(u8, existing, hostname)) return true; // Already present
    }

    if (g_allowed_count >= MAX_ALLOWED_HOSTS) return false;

    @memcpy(g_allowed_hosts[g_allowed_count][0..hostname.len], hostname);
    g_allowed_lens[g_allowed_count] = @intCast(hostname.len);
    g_allowed_count += 1;
    return true;
}

/// Clear all allowed hostnames.
pub fn clearAllowedHosts() void {
    g_allowed_count = 0;
    g_allowed_lens = [_]u8{0} ** MAX_ALLOWED_HOSTS;
}

/// Get the current allowed hostnames as slices. Caller must not store the pointers.
pub fn getAllowedHosts(out: [][]const u8) usize {
    const n = @min(g_allowed_count, out.len);
    for (0..n) |i| {
        out[i] = g_allowed_hosts[i][0..g_allowed_lens[i]];
    }
    return n;
}

/// Get the count of allowed hostnames.
pub fn getAllowedHostCount() usize {
    return g_allowed_count;
}

/// Validate Host header to prevent DNS rebinding attacks.
/// A malicious website can resolve to a local IP and attempt to connect,
/// but the Host header will contain the attacker's domain (e.g., "evil.com"),
/// not the actual IP. We accept connections where Host is a local/private IP,
/// a .local mDNS name, or a user-configured allowed hostname.
///
/// Note: 0.0.0.0 is explicitly rejected (0.0.0.0-day attack vector) even though
/// the server binds to 0.0.0.0 to listen on all interfaces — these are different things.
pub fn isValidLocalHost(host: []const u8) bool {
    if (host.len == 0) return false;

    // Reject 0.0.0.0 — valid bind address but not a valid Host header
    if (std.mem.startsWith(u8, host, "0.0.0.0")) return false;

    // Localhost patterns
    if (std.mem.startsWith(u8, host, "127.") or
        std.mem.startsWith(u8, host, "localhost:") or
        std.mem.eql(u8, host, "localhost") or
        std.mem.startsWith(u8, host, "[::1]:") or
        std.mem.eql(u8, host, "[::1]"))
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

    // Link-local: 169.254.x.x (used for direct device-to-device connections)
    if (std.mem.startsWith(u8, host, "169.254.")) {
        return true;
    }

    // Private network: 172.16.x.x - 172.31.x.x
    if (std.mem.startsWith(u8, host, "172.")) {
        const rest = host[4..];
        const dot_pos = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second_octet = std.fmt.parseInt(u8, rest[0..dot_pos], 10) catch return false;
        if (second_octet >= 16 and second_octet <= 31) {
            return true;
        }
    }

    // Strip port from host for hostname matching ("mypc:9224" → "mypc")
    const hostname = stripPort(host);

    // Allow any .local hostname — mDNS resolution is LAN-only by definition,
    // so a .local Host header proves the client resolved via multicast DNS
    // on the local network segment.
    if (std.mem.endsWith(u8, hostname, ".local")) {
        return true;
    }

    // Check user-configured allowed hostnames
    for (0..g_allowed_count) |i| {
        const allowed = g_allowed_hosts[i][0..g_allowed_lens[i]];
        if (std.mem.eql(u8, hostname, allowed)) {
            return true;
        }
    }

    return false;
}

/// Validate Origin header for WebSocket upgrade requests.
/// - Absent origin → allow (non-browser clients like websocat, curl)
/// - "null" origin → reject (sandboxed iframe / suspicious)
/// - Present origin → extract host portion and validate against local host whitelist
pub fn isValidOrigin(origin: ?[]const u8, host: []const u8) bool {
    const origin_val = origin orelse return true; // absent = non-browser, allow

    // Reject literal "null" string (sandboxed iframe)
    if (std.mem.eql(u8, origin_val, "null")) return false;

    // Extract host from origin URL (e.g., "http://192.168.1.5:9224" → "192.168.1.5:9224")
    const origin_host = extractOriginHost(origin_val);

    // Origin host must match a valid local address
    if (!isValidLocalHost(origin_host)) return false;

    // Origin host must match the request Host header (same-origin check)
    return std.mem.eql(u8, origin_host, host);
}

/// Extract the host:port portion from an origin URL.
/// "http://192.168.1.5:9224" → "192.168.1.5:9224"
/// "https://localhost:9224" → "localhost:9224"
fn extractOriginHost(origin: []const u8) []const u8 {
    // Skip past "://" if present
    if (std.mem.indexOf(u8, origin, "://")) |idx| {
        return origin[idx + 3 ..];
    }
    return origin;
}

/// Strip the port suffix from a host string.
/// "mypc:9224" → "mypc"
/// "mypc.local:9224" → "mypc.local"
/// "mypc" → "mypc" (no port)
/// "[::1]:9224" → "[::1]:9224" (IPv6 — don't strip, handled separately)
fn stripPort(host: []const u8) []const u8 {
    // Don't strip from IPv6 addresses (contain multiple colons)
    if (std.mem.startsWith(u8, host, "[")) return host;

    // Find the last colon — if the part after it is all digits, it's a port
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon_pos| {
        const after = host[colon_pos + 1 ..];
        if (after.len > 0 and after.len <= 5) {
            // Verify all digits
            for (after) |c| {
                if (c < '0' or c > '9') return host; // Not a port
            }
            return host[0..colon_pos];
        }
    }
    return host;
}

// ── Tests ──────────────────────────────────────────────────────────

test "accepts 127.0.0.1:9224" {
    try std.testing.expect(isValidLocalHost("127.0.0.1:9224"));
}

test "accepts 127.0.0.1 without port" {
    try std.testing.expect(isValidLocalHost("127.0.0.1"));
}

test "accepts localhost:9224" {
    try std.testing.expect(isValidLocalHost("localhost:9224"));
}

test "accepts localhost without port" {
    try std.testing.expect(isValidLocalHost("localhost"));
}

test "accepts [::1]:9224" {
    try std.testing.expect(isValidLocalHost("[::1]:9224"));
}

test "accepts [::1] without port" {
    try std.testing.expect(isValidLocalHost("[::1]"));
}

test "accepts 192.168.1.5:9224" {
    try std.testing.expect(isValidLocalHost("192.168.1.5:9224"));
}

test "accepts 10.0.0.1:9224" {
    try std.testing.expect(isValidLocalHost("10.0.0.1:9224"));
}

test "accepts 172.16.0.1:9224" {
    try std.testing.expect(isValidLocalHost("172.16.0.1:9224"));
}

test "accepts 172.31.255.255:9224" {
    try std.testing.expect(isValidLocalHost("172.31.255.255:9224"));
}

test "accepts 169.254.1.1:9224" {
    try std.testing.expect(isValidLocalHost("169.254.1.1:9224"));
}

test "rejects 0.0.0.0:9224" {
    try std.testing.expect(!isValidLocalHost("0.0.0.0:9224"));
}

test "rejects 0.0.0.0" {
    try std.testing.expect(!isValidLocalHost("0.0.0.0"));
}

test "rejects evil.com:9224" {
    try std.testing.expect(!isValidLocalHost("evil.com:9224"));
}

test "rejects empty host" {
    try std.testing.expect(!isValidLocalHost(""));
}

test "rejects 172.15.0.1 (below private range)" {
    try std.testing.expect(!isValidLocalHost("172.15.0.1:9224"));
}

test "rejects 172.32.0.1 (above private range)" {
    try std.testing.expect(!isValidLocalHost("172.32.0.1:9224"));
}

// ── .local hostname tests ──

test "accepts mypc.local:9224" {
    try std.testing.expect(isValidLocalHost("mypc.local:9224"));
}

test "accepts mypc.local without port" {
    try std.testing.expect(isValidLocalHost("mypc.local"));
}

test "accepts studio-mac.local:9224" {
    try std.testing.expect(isValidLocalHost("studio-mac.local:9224"));
}

// ── Allowed hosts tests ──

test "allowed host matches with port" {
    clearAllowedHosts();
    try std.testing.expect(addAllowedHost("studio-pc"));
    try std.testing.expect(isValidLocalHost("studio-pc:9224"));
    clearAllowedHosts();
}

test "allowed host matches without port" {
    clearAllowedHosts();
    try std.testing.expect(addAllowedHost("studio-pc"));
    try std.testing.expect(isValidLocalHost("studio-pc"));
    clearAllowedHosts();
}

test "allowed host tailscale domain" {
    clearAllowedHosts();
    try std.testing.expect(addAllowedHost("mypc.tailnet.ts.net"));
    try std.testing.expect(isValidLocalHost("mypc.tailnet.ts.net:9224"));
    try std.testing.expect(!isValidLocalHost("evil.tailnet.ts.net:9224")); // Different host
    clearAllowedHosts();
}

test "allowed host deduplication" {
    clearAllowedHosts();
    try std.testing.expect(addAllowedHost("mypc"));
    try std.testing.expect(addAllowedHost("mypc")); // Duplicate — returns true (already present)
    try std.testing.expectEqual(@as(usize, 1), getAllowedHostCount());
    clearAllowedHosts();
}

test "allowed host rejects unlisted hostname" {
    clearAllowedHosts();
    try std.testing.expect(addAllowedHost("studio-pc"));
    try std.testing.expect(!isValidLocalHost("other-pc:9224"));
    clearAllowedHosts();
}

// ── stripPort tests ──

test "stripPort removes port" {
    try std.testing.expectEqualStrings("mypc", stripPort("mypc:9224"));
}

test "stripPort preserves bare hostname" {
    try std.testing.expectEqualStrings("mypc", stripPort("mypc"));
}

test "stripPort preserves IPv6" {
    try std.testing.expectEqualStrings("[::1]:9224", stripPort("[::1]:9224"));
}

test "stripPort handles dotted hostname with port" {
    try std.testing.expectEqualStrings("mypc.local", stripPort("mypc.local:9224"));
}

// ── Origin tests ──

test "origin absent allows" {
    try std.testing.expect(isValidOrigin(null, "127.0.0.1:9224"));
}

test "origin null rejects" {
    try std.testing.expect(!isValidOrigin("null", "127.0.0.1:9224"));
}

test "origin matches host allows" {
    try std.testing.expect(isValidOrigin("http://192.168.1.5:9224", "192.168.1.5:9224"));
}

test "origin mismatch rejects" {
    try std.testing.expect(!isValidOrigin("http://192.168.1.5:9224", "192.168.1.6:9224"));
}

test "origin from external domain rejects" {
    try std.testing.expect(!isValidOrigin("http://evil.com", "127.0.0.1:9224"));
}

test "origin with .local hostname" {
    try std.testing.expect(isValidOrigin("http://mypc.local:9224", "mypc.local:9224"));
}

test "origin with allowed hostname" {
    clearAllowedHosts();
    _ = addAllowedHost("studio-pc");
    try std.testing.expect(isValidOrigin("http://studio-pc:9224", "studio-pc:9224"));
    clearAllowedHosts();
}

test "extractOriginHost strips scheme" {
    try std.testing.expectEqualStrings("192.168.1.5:9224", extractOriginHost("http://192.168.1.5:9224"));
    try std.testing.expectEqualStrings("localhost:9224", extractOriginHost("https://localhost:9224"));
}

test "extractOriginHost handles bare host" {
    try std.testing.expectEqualStrings("192.168.1.5:9224", extractOriginHost("192.168.1.5:9224"));
}
