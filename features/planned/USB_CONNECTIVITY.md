# USB Connectivity for Venues Without WiFi

## Problem

Musicians performing at venues without WiFi (outdoor gigs, old buildings, strict network policies) cannot use REAmo. The current architecture assumes phone and desktop are on the same LAN.

## Solution

USB tethering (iOS Personal Hotspot, Android USB Tethering) creates a standard TCP/IP network between phone and desktop. The PWA works unchanged over this network - we just need to help users discover the desktop's IP address.

## How It Works

### iOS Personal Hotspot over USB

**iOS 3-16 (traditional):**

| Property | Value |
|----------|-------|
| Subnet | `172.20.10.0/28` |
| iPhone (gateway) | `172.20.10.1` |
| Desktop IP range | `172.20.10.2` - `172.20.10.14` |
| Predictability | High - usually `.2` |

**iOS 17+ (some 5G carriers):**

| Property | Value |
|----------|-------|
| Subnet | `192.0.0.0/24` |
| iPhone (gateway) | `192.0.0.1` |
| Desktop IP | `192.0.0.2` |
| Notes | All clients get same IP, no multicast |

Detection must check both `172.20.10.x` and `192.0.0.x` ranges for full iOS compatibility.

### Android USB Tethering

| Property | Value |
|----------|-------|
| Subnet | `192.168.42.0/24` (AOSP standard) |
| Android phone (gateway) | `192.168.42.129` (hardcoded) |
| Desktop IP range | DHCP-assigned, varies |
| Predictability | Medium - need to detect |

### Why This Works

- USB tethering creates a real network interface on the desktop
- REAPER's HTTP server binds to `0.0.0.0` (all interfaces) by default
- REAmo extension's WebSocket also binds to all interfaces
- Phone's browser can reach desktop via the USB network interface
- No native apps, no jailbreaking, no Developer Mode required

### Platform Compatibility Matrix

| Mobile | Desktop | Works? | Notes |
|--------|---------|--------|-------|
| iOS | macOS | ✅ Zero-config | Native Apple ecosystem support |
| iOS | Windows | ⚠️ Needs iTunes | iTunes installs required drivers |
| iOS | Linux | ⚠️ Usually works | Requires `ipheth` module + `usbmuxd` (included in most distros) |
| Android | macOS Intel | ❌ Needs driver | Requires HoRNDIS (unsigned kext) |
| Android | macOS Apple Silicon | ❌ Very difficult | HoRNDIS doesn't work without SIP disable |
| Android | Windows | ✅ Zero-config | Native RNDIS driver built-in |
| Android | Linux | ✅ Zero-config | Native `rndis_host` / `cdc_ether` modules |

**Practical recommendations:**

- iPhone + Mac: Perfect, just works
- iPhone + Windows: Install iTunes first (or Apple Device Support standalone)
- Android + Windows/Linux: Perfect, just works
- Android + Mac: **Use WiFi hotspot instead** - USB is problematic

## Feature: "Detect USB Networks" Action

### User Flow

1. Connect phone via USB cable
2. Enable Personal Hotspot (iOS) or USB Tethering (Android)
3. In REAPER: Actions → search "REAmo" → "REAmo: Detect USB Networks"
4. Dialog displays all detected networks with URLs
5. User types URL on phone, bookmarks to home screen
6. Done - works every time cable is connected

### Dialog Design

**When networks detected:**

```
┌─────────────────────────────────────────────┐
│  REAmo Network Addresses                    │
├─────────────────────────────────────────────┤
│                                             │
│  iOS USB (en5):                             │
│  http://172.20.10.2:8080/reamo.html         │
│                                             │
│  Android USB (en8):                         │
│  http://192.168.42.65:8080/reamo.html       │
│                                             │
│  WiFi (en0):                                │
│  http://192.168.1.50:8080/reamo.html        │
│                                             │
│  Ethernet (en7):                            │
│  http://192.168.1.51:8080/reamo.html        │
│                                             │
│                                  [ OK ]     │
└─────────────────────────────────────────────┘
```

**When no USB network detected:**

```
┌─────────────────────────────────────────────┐
│  REAmo Network Addresses                    │
├─────────────────────────────────────────────┤
│                                             │
│  No USB network detected.                   │
│                                             │
│  For iOS: Enable Personal Hotspot, then     │
│           connect USB cable                 │
│                                             │
│  For Android: Connect USB cable, then       │
│               enable USB Tethering          │
│                                             │
│  WiFi (en0):                                │
│  http://192.168.1.50:8080/reamo.html        │
│                                             │
│                                  [ OK ]     │
└─────────────────────────────────────────────┘
```

## Implementation

### New Files

- `extension/src/network_detect.zig` - Cross-platform interface enumeration

### Network Detection Logic

```zig
const NetworkType = enum {
    ios_usb,      // 172.20.10.0/28 (iOS 3-16) or 192.0.0.0/24 (iOS 17+)
    android_usb,  // 192.168.42.0/24
    wifi_lan,     // Other private IPs
};

const NetworkInfo = struct {
    ip: [4]u8,
    interface_name: []const u8,
    adapter_description: ?[]const u8,  // Windows only, useful for classification
    network_type: NetworkType,
};

// Zig 0.15: ArrayList is unmanaged, pass allocator to methods
fn detectNetworks(allocator: Allocator) ![]NetworkInfo {
    var results: std.ArrayList(NetworkInfo) = .empty;
    errdefer results.deinit(allocator);  // Only runs on error, not success

    const interfaces = try platform.getNetworkInterfaces(allocator);
    defer allocator.free(interfaces);

    for (interfaces) |iface| {
        const ip = iface.ipv4_address orelse continue;
        if (ip[0] == 127) continue;  // Skip loopback

        const net_type: NetworkType =
            if (isInSubnet(ip, 172, 20, 10, 28))
                .ios_usb  // iOS 3-16 traditional
            else if (isInSubnet(ip, 192, 0, 0, 24))
                .ios_usb  // iOS 17+ (some 5G carriers)
            else if (isInSubnet(ip, 192, 168, 42, 24))
                .android_usb
            else if (isPrivateIP(ip))
                .wifi_lan
            else
                continue;  // Skip public IPs

        try results.append(allocator, .{  // Zig 0.15: allocator required
            .ip = ip,
            .interface_name = iface.name,
            .adapter_description = iface.description,
            .network_type = net_type,
        });
    }

    return results.toOwnedSlice(allocator);  // Zig 0.15: allocator required
}
```

**Note on 192.0.0.0/24:** This is technically IETF "Documentation" space (RFC 5737), but Apple uses it for Personal Hotspot on iOS 17+ with some 5G carriers. Collision risk is low but possible with exotic network configs.

### Platform APIs

| OS | API | Link Library | Notes |
|----|-----|--------------|-------|
| macOS | `getifaddrs()` | libc (default) | POSIX standard |
| Linux | `getifaddrs()` | libc (default) | POSIX standard |
| Windows | `GetAdaptersAddresses()` | `iphlpapi.lib` | Returns useful adapter descriptions |

### Windows Adapter Descriptions

Windows provides human-readable descriptions that help classification:

- `"Apple Mobile Device Ethernet Adapter"` → iOS USB
- `"Remote NDIS Compatible Device"` → Android USB (RNDIS)
- `"USB Ethernet/RNDIS Gadget"` → Android USB variant

Can use these as fallback heuristic when subnet matching is ambiguous.

### Getting the HTTP Port

Web interface configuration is stored in `reaper.ini` as control surfaces, not as a simple config variable:

```ini
[reaper]
csurf_cnt=2
csurf_0=HTTP 0 8080 '' 'index.html' 0 ''
csurf_1=OSC ...
```

Format: `HTTP 0 {port} '{username}' '{default_page}' {flags} '{password}'`

Detection logic:

```zig
// Zig 0.15: ArrayList is unmanaged, pass allocator to methods
fn getWebInterfacePorts(allocator: Allocator) ![]u16 {
    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    const ini_path = reaper.get_ini_file();
    const ini_content = try std.fs.cwd().readFileAlloc(allocator, ini_path, 1024 * 1024);
    defer allocator.free(ini_content);

    // Parse INI - find [reaper] section, get csurf_cnt
    const csurf_cnt = parseIniInt(ini_content, "reaper", "csurf_cnt") orelse 0;

    // Check each csurf_N entry for HTTP interfaces
    var i: usize = 0;
    while (i < csurf_cnt) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "csurf_{}", .{i});
        defer allocator.free(key);

        if (parseIniString(ini_content, "reaper", key)) |value| {
            if (std.mem.startsWith(u8, value, "HTTP ")) {
                // Split by space, port is third token (index 2)
                var iter = std.mem.splitScalar(u8, value, ' ');
                _ = iter.next(); // "HTTP"
                _ = iter.next(); // "0"
                if (iter.next()) |port_str| {
                    if (std.fmt.parseInt(u16, port_str, 10)) |port| {
                        try ports.append(allocator, port);  // Zig 0.15: allocator required
                    } else |_| {}
                }
            }
        }
    }

    return ports.toOwnedSlice(allocator);  // Zig 0.15: allocator required
}
```

| Situation | Handling |
|-----------|----------|
| No web interface configured | Return empty list, show "Enable web interface in Preferences" message |
| Multiple web interfaces | Return all ports, show URL for each |
| User/password set | Still works - just extract port |

**Note:** There's no `get_web_port()` API - must parse reaper.ini directly. The `get_config_var_string()` function only reads simple key=value pairs, not the csurf array.

### Registering the Action

**Critical**: Strings in `custom_action_register_t` are NOT copied - must be static/comptime.

```zig
const std = @import("std");

// Static storage - these pointers must remain valid for plugin lifetime
const ACTION_ID = "REAMO_SHOW_NETWORKS";
const ACTION_NAME = "REAmo: Show Network Addresses";

var g_cmd_show_networks: c_int = 0;

pub fn registerActions(plugin_register: PluginRegisterFn) bool {
    // Register the action - returns command ID
    var action = reaper.custom_action_register_t{
        .uniqueSectionId = 0,  // 0 = Main section
        .idStr = ACTION_ID,    // Must be unique across ALL extensions
        .name = ACTION_NAME,
        .extra = null,
    };
    g_cmd_show_networks = plugin_register("custom_action", &action);
    if (g_cmd_show_networks == 0) return false;

    // Register command handler (one callback handles all our actions)
    _ = plugin_register("hookcommand2", @ptrCast(&onAction));

    return true;
}

pub fn unregisterActions(plugin_register: PluginRegisterFn) void {
    // Use "-" prefix to unregister on plugin unload
    _ = plugin_register("-hookcommand2", @ptrCast(&onAction));
}

fn onAction(
    section: ?*anyopaque,
    command: c_int,
    val: c_int,
    val2hw: c_int,
    relmode: c_int,
    hwnd: ?*anyopaque,
) callconv(.C) bool {
    _ = .{ section, val, val2hw, relmode, hwnd };

    if (command == g_cmd_show_networks) {
        showNetworkAddresses();
        return true;  // We handled it
    }
    return false;  // Not our command
}

fn showNetworkAddresses() void {
    var buf: [2048]u8 = undefined;
    const msg = formatNetworkInfo(&buf);  // Build the dialog text
    // ShowMessageBox(msg, title, type) - type: 0=OK, 1=OKCANCEL, 4=YESNO, 5=RETRYCANCEL
    // Returns: 1=OK, 2=CANCEL, 4=RETRY, 6=YES, 7=NO
    const result = reaper.ShowMessageBox(msg.ptr, "REAmo Network Addresses", 5);  // 5 = Retry/Cancel
    if (result == 4) {  // Retry clicked
        showNetworkAddresses();  // Rescan
    }
}
```

**Registration flow:**

1. `plugin_register("custom_action", ...)` - registers action, returns command ID
2. `plugin_register("hookcommand2", callback)` - receives triggers for ALL actions
3. Callback checks `command == g_cmd_show_networks` to identify our action
4. On plugin unload (rec == NULL), use `"-hookcommand2"` to unregister

**Why `custom_action` not `gaccel`:**

- `custom_action`: No default keybinding, REAPER assigns command ID
- `gaccel`: Provides default keybinding, you provide command ID
- Users can assign their own shortcuts via Actions list - no default needed

## Edge Cases

### Interface Not Yet Ready

USB tethering can take 1-2 seconds to get DHCP. If user runs action immediately after connecting:

- Show "No USB network detected" with setup instructions
- They run action again after a moment

### Multiple Interfaces in Same Category

User might have WiFi + Ethernet. Show all with interface name hints so they can identify which is which.

### Android OEM Subnet Variance

Some manufacturers modify the `192.168.42.0/24` default. Fallback heuristic:

- Interface name contains `usb`, `rndis`, or `ncm`
- Is a private IP
- Not in typical home WiFi ranges (`192.168.0.x`, `192.168.1.x`, `10.0.0.x`)

### macOS Firewall

First time REAPER opens a listening socket, macOS may prompt "Allow incoming connections?"

- If user clicks Deny, connections fail silently
- Document this in setup instructions
- Code-signing the extension gives cleaner prompts

### iOS Local Network Permission

iOS 14+ requires apps to request local network access. Safari handles this automatically but may show a system prompt on first connection.

## OS Detection and Platform-Specific Troubleshooting

The extension should detect the host OS and provide tailored troubleshooting guidance when no USB network is found.

### OS Detection

```zig
const HostOS = enum { windows, macos, linux };

fn getHostOS() HostOS {
    // Zig's builtin target detection
    return switch (@import("builtin").os.tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => .linux,
        else => .linux,  // Fallback
    };
}
```

### Troubleshooting Messages

When no USB network is detected, show platform-specific guidance:

**macOS - No iOS detected:**

```
No iOS USB network found.

To use iPhone USB tethering:
1. Connect iPhone via USB cable
2. On iPhone: Settings → Personal Hotspot → Allow Others to Join
3. If prompted on iPhone, tap "Trust" this computer
4. Click Retry to scan again

[Retry] [Cancel]
```

**macOS - No Android detected:**

```
No Android USB network found.

⚠️ Android USB tethering requires additional drivers on macOS.

Recommended alternatives:
• Use your Android as a WiFi hotspot instead
• Connect both devices to the same WiFi network

For advanced users: HoRNDIS driver (Intel Macs only, requires
disabling SIP on Apple Silicon - not recommended)

[Retry] [Cancel]
```

**Windows - No iOS detected:**

```
No iOS USB network found.

To use iPhone USB tethering:
1. Install iTunes (or "Apple Devices" from Microsoft Store)
   - This installs required Apple Mobile Device drivers
2. Connect iPhone via USB cable
3. On iPhone: Settings → Personal Hotspot → Allow Others to Join
4. Click Retry to scan again

[Retry] [Cancel]
```

**Windows - No Android detected:**

```
No Android USB network found.

To use Android USB tethering:
1. Connect Android phone via USB cable
2. On Android: Settings → Network → Hotspot & tethering → USB tethering
3. Windows may take a few seconds to recognize the device
4. Click Retry to scan again

[Retry] [Cancel]
```

**Linux - No USB detected:**

```
No USB network found.

For iPhone:
• Ensure 'usbmuxd' service is running: systemctl status usbmuxd
• Connect iPhone and enable Personal Hotspot

For Android:
• Connect Android and enable USB Tethering in settings
• Interface should appear as usb0 or enp*s*u*

Click Retry to scan again.

[Retry] [Cancel]
```

### Implementation

```zig
fn formatNoUsbMessage(buf: []u8, host_os: HostOS, detected_networks: []const NetworkInfo) []u8 {
    // Check what we DID find
    const has_ios = for (detected_networks) |n| {
        if (n.network_type == .ios_usb) break true;
    } else false;

    const has_android = for (detected_networks) |n| {
        if (n.network_type == .android_usb) break true;
    } else false;

    // Build message based on OS and what's missing
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    if (host_os == .macos and !has_android) {
        // Special case: macOS + Android is problematic
        writer.print(macos_android_warning, .{}) catch {};
    } else if (host_os == .windows and !has_ios) {
        writer.print(windows_ios_itunes_hint, .{}) catch {};
    }
    // ... etc

    return fbs.getWritten();
}
```

### Retry Flow

The Retry/Cancel dialog allows users to:

1. Follow the troubleshooting steps
2. Click Retry to rescan without reopening Actions menu
3. Repeat until connection works or they give up

This is much better UX than a single "nothing found" message that requires re-running the action manually.

## Phase 2: QR Code Display

### Concept

Instead of user typing URL, show a QR code they can scan with phone camera.

### Implementation Options

1. **qrcodegen library** - Tiny C library, no dependencies, easy to wrap in Zig
2. **REAPER gfx API** - Can draw bitmaps to floating graphics window
3. **ImGui window** - If we add ImGui for other features

### User Flow with QR

1. Run "REAmo: Show Connection QR" action
2. Floating window appears with QR code
3. Point phone camera at screen
4. iOS/Android native QR scanner opens URL in browser
5. Bookmark to home screen

## Phase 3: PWA Enhancements (Optional)

### Cached IP Fallback

PWA could cache the last working IP and try it on reconnect failure:

```typescript
// In WebSocketConnection.ts
const cachedUsbIp = localStorage.getItem('reamo_usb_ip');
if (cachedUsbIp && connectionFailed) {
    tryConnect(cachedUsbIp);
}
```

### Manual IP Entry in Settings

Settings UI with manual IP override field for edge cases where auto-detection fails.

### USB Subnet Probing

Since iOS subnet is only 13 IPs, PWA could probe them all in parallel:

```typescript
const iosUsbIps = Array.from({length: 13}, (_, i) => `172.20.10.${i + 2}`);
const results = await Promise.allSettled(
    iosUsbIps.map(ip => fetch(`http://${ip}:8080/_/GET/EXTSTATE/Reamo/WebSocketPort`))
);
```

## Technical Notes

### Why Not rc.reaper.fm?

REAPER's `rc.reaper.fm` is a **redirect service**, not a relay. It tells the phone "go to this IP" but the phone still needs to reach that IP directly. Over USB, this only works if REAPER registers the USB interface IP - which it doesn't do automatically.

### HTTP vs HTTPS

REAmo is served from HTTP, so `ws://` WebSocket connections work fine. No mixed content issues. HTTPS would require certificates which adds complexity for local network use.

### Latency Comparison

| Connection Type | Typical Latency |
|-----------------|-----------------|
| USB Tethering | 0.5 - 5ms |
| WiFi (5GHz) | 1 - 10ms |
| WiFi (2.4GHz) | 5 - 50ms |
| Bluetooth PAN | 50 - 150ms |

USB tethering is actually the lowest latency option - a nice bonus for venues without WiFi.

## Success Criteria

- [ ] Action appears in REAPER action list, searchable as "REAmo"
- [ ] Correctly detects iOS USB interface (172.20.10.x)
- [ ] Correctly detects Android USB interface (192.168.42.x)
- [ ] Shows all LAN interfaces (WiFi, Ethernet) as fallbacks
- [ ] Displays helpful message when no USB detected
- [ ] Works on macOS, Windows, Linux
- [ ] URL includes correct HTTP port from REAPER preferences

## References

- iOS Personal Hotspot subnet: Apple developer documentation
- Android USB tethering: AOSP source (`frameworks/base/services/core/java/com/android/server/connectivity/tethering/`)
- Windows IP Helper API: Microsoft docs
- POSIX `getifaddrs()`: man pages
