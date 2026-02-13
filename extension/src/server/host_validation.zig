const std = @import("std");

/// Validate Host header to prevent DNS rebinding attacks.
/// A malicious website can resolve to a local IP and attempt to connect,
/// but the Host header will contain the attacker's domain (e.g., "evil.com"),
/// not the actual IP. We accept connections where Host is a local/private IP.
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

test "accepts [::1]:9224" {
    try std.testing.expect(isValidLocalHost("[::1]:9224"));
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

test "extractOriginHost strips scheme" {
    try std.testing.expectEqualStrings("192.168.1.5:9224", extractOriginHost("http://192.168.1.5:9224"));
    try std.testing.expectEqualStrings("localhost:9224", extractOriginHost("https://localhost:9224"));
}

test "extractOriginHost handles bare host" {
    try std.testing.expectEqualStrings("192.168.1.5:9224", extractOriginHost("192.168.1.5:9224"));
}
