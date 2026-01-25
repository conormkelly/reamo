/// Network interface detection for USB tethering discovery.
/// macOS implementation using POSIX getifaddrs().
///
/// Detects:
/// - iOS USB tethering: 172.20.10.0/28 (iOS 3-16) or 192.0.0.0/24 (iOS 17+)
/// - Android USB tethering: 192.168.42.0/24
/// - WiFi/Ethernet: Other private IP ranges

const std = @import("std");

// POSIX network interface types
const c = @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
});

const AF_INET: c_int = 2;

/// Network type classification
pub const NetworkType = enum {
    ios_usb, // 172.20.10.0/28 (iOS 3-16) or 192.0.0.0/24 (iOS 17+)
    android_usb, // 192.168.42.0/24
    wifi_lan, // Other private IPs (WiFi, Ethernet)

    pub fn label(self: NetworkType) []const u8 {
        return switch (self) {
            .ios_usb => "iOS USB",
            .android_usb => "Android USB",
            .wifi_lan => "LAN",
        };
    }
};

/// Information about a detected network interface
pub const NetworkInfo = struct {
    ip: [4]u8,
    interface_name: [16]u8,
    interface_name_len: u8,
    network_type: NetworkType,

    pub fn ipString(self: *const NetworkInfo, buf: []u8) []const u8 {
        const written = std.fmt.bufPrint(buf, "{}.{}.{}.{}", .{
            self.ip[0],
            self.ip[1],
            self.ip[2],
            self.ip[3],
        }) catch return "";
        return written;
    }

    pub fn interfaceName(self: *const NetworkInfo) []const u8 {
        return self.interface_name[0..self.interface_name_len];
    }
};

/// Check if IP is in a subnet.
/// prefix_len is CIDR notation (e.g., 28 for /28)
fn isInSubnet(ip: [4]u8, net_a: u8, net_b: u8, net_c: u8, prefix_len: u5) bool {
    const ip_val: u32 = (@as(u32, ip[0]) << 24) |
        (@as(u32, ip[1]) << 16) |
        (@as(u32, ip[2]) << 8) |
        @as(u32, ip[3]);

    const net_val: u32 = (@as(u32, net_a) << 24) |
        (@as(u32, net_b) << 16) |
        (@as(u32, net_c) << 8);

    // Create mask from prefix length
    // Compute mask from prefix length. prefix_len=0 means no mask (match all).
    // For prefix_len > 0, create a mask with `prefix_len` leading 1s.
    const shift_amount: u5 = if (prefix_len == 0) 0 else @intCast(32 - @as(u6, prefix_len));
    const mask: u32 = if (prefix_len == 0) 0 else (~@as(u32, 0)) << shift_amount;

    return (ip_val & mask) == (net_val & mask);
}

/// Check if IP is a private address (RFC 1918 + CGNAT)
fn isPrivateIP(ip: [4]u8) bool {
    // 10.0.0.0/8
    if (ip[0] == 10) return true;
    // 172.16.0.0/12
    if (ip[0] == 172 and (ip[1] >= 16 and ip[1] <= 31)) return true;
    // 192.168.0.0/16
    if (ip[0] == 192 and ip[1] == 168) return true;
    // 100.64.0.0/10 (CGNAT)
    if (ip[0] == 100 and (ip[1] >= 64 and ip[1] <= 127)) return true;
    // 169.254.0.0/16 (link-local)
    if (ip[0] == 169 and ip[1] == 254) return true;
    // 192.0.0.0/24 (iOS 17+ hotspot uses this - technically IETF documentation space)
    if (ip[0] == 192 and ip[1] == 0 and ip[2] == 0) return true;
    return false;
}

/// Classify an IP address by network type
fn classifyNetwork(ip: [4]u8) ?NetworkType {
    // Skip loopback
    if (ip[0] == 127) return null;

    // iOS USB: 172.20.10.0/28 (iOS 3-16 traditional)
    if (isInSubnet(ip, 172, 20, 10, 28)) return .ios_usb;

    // iOS USB: 192.0.0.0/24 (iOS 17+ with some 5G carriers)
    if (isInSubnet(ip, 192, 0, 0, 24)) return .ios_usb;

    // Android USB: 192.168.42.0/24 (AOSP standard)
    if (isInSubnet(ip, 192, 168, 42, 24)) return .android_usb;

    // Other private IPs are WiFi/Ethernet
    if (isPrivateIP(ip)) return .wifi_lan;

    // Skip public IPs
    return null;
}

/// Detect all network interfaces and classify them.
/// Returns the number of networks found.
/// buf must have space for at least max_networks entries.
pub fn detectNetworks(buf: []NetworkInfo) usize {
    var ifap: ?*c.ifaddrs = null;

    if (c.getifaddrs(&ifap) != 0) {
        return 0;
    }
    defer c.freeifaddrs(ifap);

    var count: usize = 0;
    var ifa = ifap;

    while (ifa) |iface| : (ifa = iface.ifa_next) {
        if (count >= buf.len) break;

        const addr = iface.ifa_addr orelse continue;
        if (addr[0].sa_family != AF_INET) continue;

        // Cast to sockaddr_in to get IP address
        const sin: *const c.sockaddr_in = @ptrCast(@alignCast(addr));
        const ip_raw = sin.sin_addr.s_addr;

        // Convert from network byte order to host byte order bytes
        const ip: [4]u8 = .{
            @truncate(ip_raw),
            @truncate(ip_raw >> 8),
            @truncate(ip_raw >> 16),
            @truncate(ip_raw >> 24),
        };

        const net_type = classifyNetwork(ip) orelse continue;

        // Copy interface name
        var name_buf: [16]u8 = .{0} ** 16;
        var name_len: u8 = 0;
        if (iface.ifa_name) |name_ptr| {
            const name = std.mem.sliceTo(name_ptr, 0);
            const copy_len = @min(name.len, 15);
            @memcpy(name_buf[0..copy_len], name[0..copy_len]);
            name_len = @intCast(copy_len);
        }

        buf[count] = .{
            .ip = ip,
            .interface_name = name_buf,
            .interface_name_len = name_len,
            .network_type = net_type,
        };
        count += 1;
    }

    return count;
}

// Tests
test "isInSubnet - iOS USB range" {
    // 172.20.10.2 should be in 172.20.10.0/28
    try std.testing.expect(isInSubnet(.{ 172, 20, 10, 2 }, 172, 20, 10, 28));
    try std.testing.expect(isInSubnet(.{ 172, 20, 10, 14 }, 172, 20, 10, 28));
    // 172.20.10.16 is outside /28
    try std.testing.expect(!isInSubnet(.{ 172, 20, 10, 16 }, 172, 20, 10, 28));
}

test "isInSubnet - Android USB range" {
    try std.testing.expect(isInSubnet(.{ 192, 168, 42, 1 }, 192, 168, 42, 24));
    try std.testing.expect(isInSubnet(.{ 192, 168, 42, 255 }, 192, 168, 42, 24));
    try std.testing.expect(!isInSubnet(.{ 192, 168, 43, 1 }, 192, 168, 42, 24));
}

test "classifyNetwork" {
    try std.testing.expectEqual(NetworkType.ios_usb, classifyNetwork(.{ 172, 20, 10, 2 }).?);
    try std.testing.expectEqual(NetworkType.ios_usb, classifyNetwork(.{ 192, 0, 0, 2 }).?);
    try std.testing.expectEqual(NetworkType.android_usb, classifyNetwork(.{ 192, 168, 42, 65 }).?);
    try std.testing.expectEqual(NetworkType.wifi_lan, classifyNetwork(.{ 192, 168, 1, 100 }).?);
    try std.testing.expectEqual(NetworkType.wifi_lan, classifyNetwork(.{ 10, 0, 0, 5 }).?);
    try std.testing.expect(classifyNetwork(.{ 127, 0, 0, 1 }) == null); // loopback
    try std.testing.expect(classifyNetwork(.{ 8, 8, 8, 8 }) == null); // public
}
