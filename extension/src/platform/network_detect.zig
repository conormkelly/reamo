/// Network interface detection for USB tethering discovery.
/// Cross-platform: macOS/Linux use POSIX getifaddrs(), Windows uses GetAdaptersAddresses().
///
/// Detects:
/// - iOS USB tethering: 172.20.10.0/28 (iOS 3-16) or 192.0.0.0/24 (iOS 17+)
/// - Android USB tethering: 192.168.42.0/24
/// - WiFi/Ethernet: Other private IP ranges

const std = @import("std");
const builtin = @import("builtin");

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

// =============================================================================
// Platform-specific implementations
// =============================================================================

/// Detect all network interfaces and classify them.
/// Returns the number of networks found.
/// buf must have space for at least max_networks entries.
pub const detectNetworks = switch (builtin.os.tag) {
    .macos, .linux, .freebsd, .netbsd, .openbsd => detectNetworksPosix,
    .windows => detectNetworksWindows,
    else => detectNetworksStub,
};

// -----------------------------------------------------------------------------
// POSIX implementation (macOS, Linux, BSD)
// -----------------------------------------------------------------------------

const posix = if (builtin.os.tag != .windows) @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
}) else struct {};

const AF_INET: c_int = 2;

fn detectNetworksPosix(buf: []NetworkInfo) usize {
    var ifap: ?*posix.ifaddrs = null;

    if (posix.getifaddrs(&ifap) != 0) {
        return 0;
    }
    defer posix.freeifaddrs(ifap);

    var count: usize = 0;
    var ifa = ifap;

    while (ifa) |iface| : (ifa = iface.ifa_next) {
        if (count >= buf.len) break;

        const addr = iface.ifa_addr orelse continue;
        if (addr.*.sa_family != AF_INET) continue;

        // Cast to sockaddr_in to get IP address
        const sin: *const posix.sockaddr_in = @ptrCast(@alignCast(addr));
        const ip_raw = sin.sin_addr.s_addr;

        // Note: Assumes little-endian host (x86, ARM). s_addr is in network
        // byte order (big-endian), but stored in memory LSB-first on LE hosts.
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

// -----------------------------------------------------------------------------
// Windows implementation
// -----------------------------------------------------------------------------

const win32 = if (builtin.os.tag == .windows) struct {
    // Windows API constants
    const AF_INET: c_ulong = 2;
    const GAA_FLAG_SKIP_ANYCAST: c_ulong = 0x0002;
    const GAA_FLAG_SKIP_MULTICAST: c_ulong = 0x0004;
    const GAA_FLAG_SKIP_DNS_SERVER: c_ulong = 0x0008;

    // Minimal struct definitions for GetAdaptersAddresses
    const SOCKET_ADDRESS = extern struct {
        lpSockaddr: ?*sockaddr,
        iSockaddrLength: c_int,
    };

    const sockaddr = extern struct {
        sa_family: u16,
        sa_data: [14]u8,
    };

    const sockaddr_in = extern struct {
        sin_family: u16,
        sin_port: u16,
        sin_addr: in_addr,
        sin_zero: [8]u8,
    };

    const in_addr = extern struct {
        s_addr: u32,
    };

    const IP_ADAPTER_UNICAST_ADDRESS = extern struct {
        length: c_ulong,
        flags: c_ulong,
        next: ?*IP_ADAPTER_UNICAST_ADDRESS,
        address: SOCKET_ADDRESS,
        prefix_origin: c_int,
        suffix_origin: c_int,
        dad_state: c_int,
        valid_lifetime: c_ulong,
        preferred_lifetime: c_ulong,
        lease_lifetime: c_ulong,
        on_link_prefix_length: u8,
    };

    const IP_ADAPTER_ADDRESSES = extern struct {
        length: c_ulong,
        if_index: c_ulong,
        next: ?*IP_ADAPTER_ADDRESSES,
        adapter_name: [*:0]u8,
        first_unicast_address: ?*IP_ADAPTER_UNICAST_ADDRESS,
        first_anycast_address: ?*anyopaque,
        first_multicast_address: ?*anyopaque,
        first_dns_server_address: ?*anyopaque,
        dns_suffix: [*:0]u16,
        description: [*:0]u16,
        friendly_name: [*:0]u16,
        // ... more fields we don't need
    };

    extern "iphlpapi" fn GetAdaptersAddresses(
        family: c_ulong,
        flags: c_ulong,
        reserved: ?*anyopaque,
        addresses: ?*IP_ADAPTER_ADDRESSES,
        size: *c_ulong,
    ) callconv(.winapi) c_ulong;
} else struct {};

fn detectNetworksWindows(buf: []NetworkInfo) usize {
    if (builtin.os.tag != .windows) return 0;

    const flags = win32.GAA_FLAG_SKIP_ANYCAST |
        win32.GAA_FLAG_SKIP_MULTICAST |
        win32.GAA_FLAG_SKIP_DNS_SERVER;

    // First call to get required size
    var size: c_ulong = 0;
    _ = win32.GetAdaptersAddresses(win32.AF_INET, flags, null, null, &size);

    if (size == 0) return 0;

    // Allocate buffer on stack (up to 16KB should be fine)
    var adapter_buf: [16 * 1024]u8 align(@alignOf(win32.IP_ADAPTER_ADDRESSES)) = undefined;
    if (size > adapter_buf.len) return 0;

    const adapters: *win32.IP_ADAPTER_ADDRESSES = @ptrCast(&adapter_buf);

    // Get adapter addresses
    const result = win32.GetAdaptersAddresses(win32.AF_INET, flags, null, adapters, &size);
    if (result != 0) return 0;

    var count: usize = 0;
    var adapter: ?*win32.IP_ADAPTER_ADDRESSES = adapters;

    while (adapter) |a| : (adapter = a.next) {
        if (count >= buf.len) break;

        var unicast = a.first_unicast_address;
        while (unicast) |u| : (unicast = u.next) {
            if (count >= buf.len) break;

            const sockaddr = u.address.lpSockaddr orelse continue;
            if (sockaddr.sa_family != win32.AF_INET) continue;

            const sin: *const win32.sockaddr_in = @ptrCast(@alignCast(sockaddr));
            const ip_raw = sin.sin_addr.s_addr;

            const ip: [4]u8 = .{
                @truncate(ip_raw),
                @truncate(ip_raw >> 8),
                @truncate(ip_raw >> 16),
                @truncate(ip_raw >> 24),
            };

            const net_type = classifyNetwork(ip) orelse continue;

            // Copy friendly_name (UTF-16) to UTF-8 for display
            // adapter_name is a GUID like {4D36E972-...}, not useful
            var name_buf: [16]u8 = .{0} ** 16;
            var name_len: u8 = 0;
            var i: usize = 0;
            while (a.friendly_name[i] != 0 and name_len < 15) : (i += 1) {
                const c = a.friendly_name[i];
                if (c < 128) { // ASCII only, good enough for interface names
                    name_buf[name_len] = @truncate(c);
                    name_len += 1;
                }
            }

            buf[count] = .{
                .ip = ip,
                .interface_name = name_buf,
                .interface_name_len = name_len,
                .network_type = net_type,
            };
            count += 1;
        }
    }

    return count;
}

// -----------------------------------------------------------------------------
// Stub for unsupported platforms
// -----------------------------------------------------------------------------

fn detectNetworksStub(_: []NetworkInfo) usize {
    return 0;
}

// =============================================================================
// Tests
// =============================================================================

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
