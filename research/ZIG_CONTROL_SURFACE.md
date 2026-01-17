# REAPER's IReaperControlSurface API for Zig-based WebSocket Extensions

**You can eliminate most 30Hz polling by implementing IReaperControlSurface callbacks**, which provide instant push notifications for transport state, track volume/pan/mute/solo, selection changes, and FX parameters. However, **playhead position and audio metering must still be polled** since no callbacks exist for continuously changing values. The optimal architecture combines a control surface for instant state notifications with a reduced-frequency timer (~10Hz) for position/meter polling, broadcasting both to WebSocket clients.

---

## Push vs. poll: what callbacks exist for your current polling

The IReaperControlSurface interface provides push notifications for most DAW state changes. Here's how your current 30Hz polling maps to available callbacks:

| State | Current Poll | Push Callback Available? | Method |
|-------|-------------|-------------------------|--------|
| Transport play/pause/rec | 30Hz | **✅ Yes** | `SetPlayState(bool play, bool pause, bool rec)` |
| Playhead position | 30Hz | **❌ No** - must poll | Use `GetPlayPosition()` in `Run()` |
| Track volume | 30Hz | **✅ Yes** | `SetSurfaceVolume(MediaTrack*, double)` |
| Track mute/solo | 30Hz | **✅ Yes** | `SetSurfaceMute()` / `SetSurfaceSolo()` |
| Track selection | 30Hz | **✅ Yes** | `SetSurfaceSelected()` + `OnTrackSelection()` |
| FX parameter changes | 5Hz | **✅ Yes** | `Extended(CSURF_EXT_SETFXPARAM, ...)` |
| Markers/regions | 5Hz | **✅ Yes** | `Extended(CSURF_EXT_SETPROJECTMARKERCHANGE, ...)` |
| Undo state | 5Hz | **❌ No** - must poll | Poll `Undo_CanUndo2()` |

This means you can eliminate polling for **6 of 8 state categories** and reduce your timer from 30Hz to ~10Hz for position tracking only.

---

## Complete IReaperControlSurface callback catalog

The interface lives in `reaper_plugin.h`. REAPER calls these virtual methods as push notifications when state changes occur.

### Core push notification callbacks

```cpp
class IReaperControlSurface {
public:
    virtual ~IReaperControlSurface() { }
    
    // Identity (not callbacks - configuration methods)
    virtual const char* GetTypeString() { return ""; }   // Unique ID (A-Z, 0-9)
    virtual const char* GetDescString() { return ""; }   // Human-readable name
    virtual const char* GetConfigString() { return ""; } // Saved configuration
    
    // PERIODIC CALLBACK - called ~30Hz for polling
    virtual void Run() { }
    
    // TRANSPORT CALLBACKS
    virtual void SetPlayState(bool play, bool pause, bool rec) { }
    virtual void SetRepeatState(bool rep) { }
    
    // TRACK LIST CALLBACK - fires on add/remove/reorder
    virtual void SetTrackListChange() { }
    
    // PER-TRACK STATE CALLBACKS
    virtual void SetSurfaceVolume(MediaTrack* trackid, double volume) { }  // 0.0-1.0 normalized
    virtual void SetSurfacePan(MediaTrack* trackid, double pan) { }        // -1.0 to +1.0
    virtual void SetSurfaceMute(MediaTrack* trackid, bool mute) { }
    virtual void SetSurfaceSolo(MediaTrack* trackid, bool solo) { }
    virtual void SetSurfaceRecArm(MediaTrack* trackid, bool recarm) { }
    virtual void SetSurfaceSelected(MediaTrack* trackid, bool selected) { }
    virtual void SetTrackTitle(MediaTrack* trackid, const char* title) { }
    
    // AUTOMATION AND SELECTION
    virtual void SetAutoMode(int mode) { }  // 0=Trim, 1=Read, 2=Touch, 3=Write, 4=Latch
    virtual void OnTrackSelection(MediaTrack* trackid) { }  // Last-touched track
    
    // STATE QUERIES (REAPER asks surface)
    virtual bool GetTouchState(MediaTrack* trackid, int isPan) { return false; }
    virtual bool IsKeyDown(int key) { return false; }
    
    // CACHE MANAGEMENT
    virtual void ResetCachedVolPanStates() { }
    virtual void CloseNoReset() { }
    
    // EXTENDED NOTIFICATIONS - handles many additional events
    virtual int Extended(int call, void* parm1, void* parm2, void* parm3) { return 0; }
};
```

### State changes with NO callback (must poll in Run)

These continuously-changing values have no push mechanism:

- **Playhead position** - `GetPlayPosition()` / `GetPlayPosition2()`
- **Edit cursor position** - `GetCursorPosition()`
- **Time selection** - `GetSet_LoopTimeRange()`
- **Peak metering** - `Track_GetPeakInfo()`
- **Zoom/scroll state** - No API callback
- **Undo state** - Poll `Undo_CanUndo2()`
- **Item/take changes** - No direct callback
- **Envelope point changes** - No callback

---

## CSURF_EXT_* notification codes for Extended()

The `Extended()` method handles additional notifications beyond the core callbacks. Return 0 if unsupported, non-zero if handled.

### FX-related notifications

| Code | Hex | Parameters | Description |
|------|-----|------------|-------------|
| **CSURF_EXT_SETFXPARAM** | 0x00010008 | parm1=`MediaTrack*`, parm2=`int*` (packed), parm3=`double*` | FX parameter changed |
| **CSURF_EXT_SETFXPARAM_RECFX** | 0x00010018 | Same as above | Input/monitoring FX param changed |
| **CSURF_EXT_SETFXENABLED** | 0x00010007 | parm1=track, parm2=fxidx, parm3=enabled | FX bypass toggled |
| **CSURF_EXT_SETFXCHANGE** | 0x00010013 | parm1=track, parm2=flags | FX added/removed/reordered |
| **CSURF_EXT_SETFXOPEN** | 0x00010012 | parm1=track, parm2=fxidx, parm3=isopen | FX window opened/closed |
| **CSURF_EXT_SETLASTTOUCHEDFX** | 0x0001000A | parm1=track, parm2=item, parm3=fxidx | Last touched FX changed |
| **CSURF_EXT_TRACKFX_PRESET_CHANGED** | 0x00010015 | parm1=track, parm2=fxidx | FX preset changed |

**Decoding CSURF_EXT_SETFXPARAM** - the parameter packing:

```cpp
int packed = *(int*)parm2;
int fxidx = (packed >> 16) & 0xFFFF;    // High 16 bits = FX index
int paramidx = packed & 0xFFFF;          // Low 16 bits = param index
double value = *(double*)parm3;          // Normalized 0.0-1.0
```

### Routing and sends

| Code | Hex | Parameters | Description |
|------|-----|------------|-------------|
| **CSURF_EXT_SETSENDVOLUME** | 0x00010005 | parm1=track, parm2=sendidx, parm3=volume | Send volume changed |
| **CSURF_EXT_SETSENDPAN** | 0x00010006 | parm1=track, parm2=sendidx, parm3=pan | Send pan changed |
| **CSURF_EXT_SETRECVVOLUME** | 0x00010010 | parm1=track, parm2=recvidx, parm3=volume | Receive volume changed |
| **CSURF_EXT_SETRECVPAN** | 0x00010011 | parm1=track, parm2=recvidx, parm3=pan | Receive pan changed |

### Global state and markers

| Code | Hex | Parameters | Description |
|------|-----|------------|-------------|
| **CSURF_EXT_SETPROJECTMARKERCHANGE** | 0x00010014 | All NULL | Marker/region added/removed/moved |
| **CSURF_EXT_SETBPMANDPLAYRATE** | 0x00010009 | parm1=bpm*, parm2=playrate* | Tempo or playrate changed |
| **CSURF_EXT_SETMETRONOME** | 0x00010002 | parm1=enabled | Metronome toggled |
| **CSURF_EXT_SETINPUTMONITOR** | 0x00010001 | parm1=track, parm2=monitor | Input monitoring changed |
| **CSURF_EXT_SETRECMODE** | 0x00010004 | parm1=mode | Recording mode changed |
| **CSURF_EXT_RESET** | 0x0001FFFF | None | Full surface reset requested |

---

## C++ shim for Zig interop

Zig cannot directly call C++ virtual methods due to vtable incompatibility. The solution is an **hourglass pattern**: a C++ class that inherits from `IReaperControlSurface` and forwards all virtual calls through C function pointers that Zig can implement.

### Header file: `zig_control_surface.h`

```c
#ifndef ZIG_CONTROL_SURFACE_H
#define ZIG_CONTROL_SURFACE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

typedef void* ZigCSurfHandle;
typedef void* MediaTrackHandle;

// Callback function pointer types
typedef const char* (*ZigGetStringCb)(void* ctx);
typedef void (*ZigRunCb)(void* ctx);
typedef void (*ZigSetPlayStateCb)(void* ctx, bool play, bool pause, bool rec);
typedef void (*ZigSetRepeatStateCb)(void* ctx, bool rep);
typedef void (*ZigSetTrackListChangeCb)(void* ctx);
typedef void (*ZigSetSurfaceVolumeCb)(void* ctx, MediaTrackHandle track, double vol);
typedef void (*ZigSetSurfacePanCb)(void* ctx, MediaTrackHandle track, double pan);
typedef void (*ZigSetSurfaceMuteCb)(void* ctx, MediaTrackHandle track, bool mute);
typedef void (*ZigSetSurfaceSoloCb)(void* ctx, MediaTrackHandle track, bool solo);
typedef void (*ZigSetSurfaceSelectedCb)(void* ctx, MediaTrackHandle track, bool sel);
typedef void (*ZigSetSurfaceRecArmCb)(void* ctx, MediaTrackHandle track, bool arm);
typedef void (*ZigOnTrackSelectionCb)(void* ctx, MediaTrackHandle track);
typedef void (*ZigSetAutoModeCb)(void* ctx, int mode);
typedef int  (*ZigExtendedCb)(void* ctx, int call, void* p1, void* p2, void* p3);

typedef struct {
    void* user_context;  // Passed to all callbacks (your Zig struct pointer)
    
    ZigGetStringCb      get_type_string;
    ZigGetStringCb      get_desc_string;
    ZigRunCb            run;
    ZigSetPlayStateCb   set_play_state;
    ZigSetRepeatStateCb set_repeat_state;
    ZigSetTrackListChangeCb set_track_list_change;
    ZigSetSurfaceVolumeCb   set_surface_volume;
    ZigSetSurfacePanCb      set_surface_pan;
    ZigSetSurfaceMuteCb     set_surface_mute;
    ZigSetSurfaceSoloCb     set_surface_solo;
    ZigSetSurfaceSelectedCb set_surface_selected;
    ZigSetSurfaceRecArmCb   set_surface_rec_arm;
    ZigOnTrackSelectionCb   on_track_selection;
    ZigSetAutoModeCb        set_auto_mode;
    ZigExtendedCb           extended;
} ZigCSurfCallbacks;

// C API for Zig
ZigCSurfHandle zig_csurf_create(const ZigCSurfCallbacks* callbacks);
void zig_csurf_destroy(ZigCSurfHandle handle);
bool zig_csurf_register(ZigCSurfHandle handle, void* plugin_register_fn);
void zig_csurf_unregister(ZigCSurfHandle handle, void* plugin_register_fn);

#ifdef __cplusplus
}
#endif
#endif
```

### Implementation: `zig_control_surface.cpp`

```cpp
#include "zig_control_surface.h"
#include "reaper_plugin.h"

class ZigControlSurface : public IReaperControlSurface {
    ZigCSurfCallbacks m_cb;
public:
    ZigControlSurface(const ZigCSurfCallbacks* cb) : m_cb(*cb) {}
    
    const char* GetTypeString() override {
        return m_cb.get_type_string ? m_cb.get_type_string(m_cb.user_context) : "zig_ws";
    }
    const char* GetDescString() override {
        return m_cb.get_desc_string ? m_cb.get_desc_string(m_cb.user_context) : "Zig WebSocket Surface";
    }
    const char* GetConfigString() override { return ""; }
    
    void Run() override {
        if (m_cb.run) m_cb.run(m_cb.user_context);
    }
    
    void SetPlayState(bool play, bool pause, bool rec) override {
        if (m_cb.set_play_state) m_cb.set_play_state(m_cb.user_context, play, pause, rec);
    }
    
    void SetRepeatState(bool rep) override {
        if (m_cb.set_repeat_state) m_cb.set_repeat_state(m_cb.user_context, rep);
    }
    
    void SetTrackListChange() override {
        if (m_cb.set_track_list_change) m_cb.set_track_list_change(m_cb.user_context);
    }
    
    void SetSurfaceVolume(MediaTrack* track, double vol) override {
        if (m_cb.set_surface_volume) m_cb.set_surface_volume(m_cb.user_context, track, vol);
    }
    
    void SetSurfacePan(MediaTrack* track, double pan) override {
        if (m_cb.set_surface_pan) m_cb.set_surface_pan(m_cb.user_context, track, pan);
    }
    
    void SetSurfaceMute(MediaTrack* track, bool mute) override {
        if (m_cb.set_surface_mute) m_cb.set_surface_mute(m_cb.user_context, track, mute);
    }
    
    void SetSurfaceSolo(MediaTrack* track, bool solo) override {
        if (m_cb.set_surface_solo) m_cb.set_surface_solo(m_cb.user_context, track, solo);
    }
    
    void SetSurfaceSelected(MediaTrack* track, bool sel) override {
        if (m_cb.set_surface_selected) m_cb.set_surface_selected(m_cb.user_context, track, sel);
    }
    
    void SetSurfaceRecArm(MediaTrack* track, bool arm) override {
        if (m_cb.set_surface_rec_arm) m_cb.set_surface_rec_arm(m_cb.user_context, track, arm);
    }
    
    void OnTrackSelection(MediaTrack* track) override {
        if (m_cb.on_track_selection) m_cb.on_track_selection(m_cb.user_context, track);
    }
    
    void SetAutoMode(int mode) override {
        if (m_cb.set_auto_mode) m_cb.set_auto_mode(m_cb.user_context, mode);
    }
    
    int Extended(int call, void* p1, void* p2, void* p3) override {
        if (m_cb.extended) return m_cb.extended(m_cb.user_context, call, p1, p2, p3);
        return 0;
    }
};

extern "C" {
    ZigCSurfHandle zig_csurf_create(const ZigCSurfCallbacks* cb) {
        return new ZigControlSurface(cb);
    }
    
    void zig_csurf_destroy(ZigCSurfHandle handle) {
        delete static_cast<ZigControlSurface*>(handle);
    }
    
    bool zig_csurf_register(ZigCSurfHandle handle, void* plugin_register_fn) {
        auto reg = reinterpret_cast<int(*)(const char*, void*)>(plugin_register_fn);
        return reg("csurf_inst", handle) != 0;
    }
    
    void zig_csurf_unregister(ZigCSurfHandle handle, void* plugin_register_fn) {
        auto reg = reinterpret_cast<int(*)(const char*, void*)>(plugin_register_fn);
        reg("-csurf_inst", handle);
    }
}
```

---

## Zig implementation with WebSocket broadcast

```zig
const std = @import("std");
const c = @cImport({ @cInclude("zig_control_surface.h"); });

pub const ReaperBridge = struct {
    csurf_handle: c.ZigCSurfHandle,
    plugin_register: *const fn ([*:0]const u8, ?*anyopaque) callconv(.C) c_int,
    ws_broadcast_fn: *const fn ([]const u8) void,  // Your WebSocket broadcast
    
    // Cached state for change detection in Run()
    last_play_pos: f64 = 0,
    is_playing: bool = false,

    const Self = @This();

    pub fn init(
        plugin_register: anytype,
        ws_broadcast: *const fn ([]const u8) void,
    ) !Self {
        var self = Self{
            .csurf_handle = undefined,
            .plugin_register = plugin_register,
            .ws_broadcast_fn = ws_broadcast,
        };
        
        const callbacks = c.ZigCSurfCallbacks{
            .user_context = &self,
            .get_type_string = getTypeString,
            .get_desc_string = getDescString,
            .run = runCallback,
            .set_play_state = setPlayStateCallback,
            .set_repeat_state = setRepeatStateCallback,
            .set_track_list_change = setTrackListChangeCallback,
            .set_surface_volume = setSurfaceVolumeCallback,
            .set_surface_mute = setSurfaceMuteCallback,
            .set_surface_solo = setSurfaceSoloCallback,
            .set_surface_selected = setSurfaceSelectedCallback,
            .extended = extendedCallback,
            // ... other callbacks
        };
        
        self.csurf_handle = c.zig_csurf_create(&callbacks) orelse return error.CreateFailed;
        return self;
    }

    pub fn register(self: *Self) void {
        _ = c.zig_csurf_register(self.csurf_handle, @ptrCast(self.plugin_register));
    }

    pub fn unregister(self: *Self) void {
        c.zig_csurf_unregister(self.csurf_handle, @ptrCast(self.plugin_register));
    }

    fn broadcast(self: *Self, msg_type: []const u8, payload: anytype) void {
        // Serialize to JSON and broadcast via WebSocket
        var buf: [1024]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, 
            "{{\"type\":\"{s}\",\"data\":{}}}", .{msg_type, payload}) catch return;
        self.ws_broadcast_fn(json);
    }
};

// ===== EXPORTED CALLBACKS =====

fn getTypeString(_: ?*anyopaque) callconv(.C) [*:0]const u8 {
    return "zig_websocket";
}

fn getDescString(_: ?*anyopaque) callconv(.C) [*:0]const u8 {
    return "Zig WebSocket Remote Control";
}

fn runCallback(ctx: ?*anyopaque) callconv(.C) void {
    const self = @as(*ReaperBridge, @ptrCast(@alignCast(ctx)));
    
    // Poll playhead position (no callback exists for this)
    if (self.is_playing) {
        const pos = GetPlayPosition();  // Call REAPER API
        if (@abs(pos - self.last_play_pos) > 0.001) {
            self.last_play_pos = pos;
            self.broadcast("playhead", .{ .position = pos });
        }
    }
}

fn setPlayStateCallback(ctx: ?*anyopaque, play: bool, pause: bool, rec: bool) callconv(.C) void {
    const self = @as(*ReaperBridge, @ptrCast(@alignCast(ctx)));
    self.is_playing = play and !pause;
    self.broadcast("transport", .{ .play = play, .pause = pause, .rec = rec });
}

fn setSurfaceVolumeCallback(ctx: ?*anyopaque, track: c.MediaTrackHandle, vol: f64) callconv(.C) void {
    const self = @as(*ReaperBridge, @ptrCast(@alignCast(ctx)));
    self.broadcast("track_volume", .{ .track = @intFromPtr(track), .volume = vol });
}

fn extendedCallback(ctx: ?*anyopaque, call: c_int, p1: ?*anyopaque, p2: ?*anyopaque, p3: ?*anyopaque) callconv(.C) c_int {
    const self = @as(*ReaperBridge, @ptrCast(@alignCast(ctx)));
    
    switch (call) {
        0x00010008 => {  // CSURF_EXT_SETFXPARAM
            const track = p1;
            const packed = @as(*i32, @ptrCast(@alignCast(p2))).*;
            const value = @as(*f64, @ptrCast(@alignCast(p3))).*;
            const fxidx = (packed >> 16) & 0xFFFF;
            const paramidx = packed & 0xFFFF;
            self.broadcast("fx_param", .{ 
                .track = @intFromPtr(track),
                .fx = fxidx,
                .param = paramidx,
                .value = value 
            });
            return 1;
        },
        0x00010014 => {  // CSURF_EXT_SETPROJECTMARKERCHANGE
            self.broadcast("markers_changed", .{});
            return 1;
        },
        else => return 0,
    }
}
```

---

## Registration and lifecycle

### Can you have both timer AND csurf_inst simultaneously?

**Yes, absolutely.** SWS Extension does exactly this. The timer callback (`plugin_register("timer", ...)`) and control surface callbacks (`plugin_register("csurf_inst", ...)`) are independent registration mechanisms. However, with a control surface, you likely don't need a separate timer—use the `Run()` callback for polling instead.

### Thread safety guarantees

**All callbacks run on the main thread.** REAPER's extension API is single-threaded for all GUI and control surface operations. Key implications:

- Safe to call any REAPER API function from callbacks
- Safe to access shared state without locks between callbacks
- **WebSocket I/O must be handled carefully** - either use non-blocking sends or queue messages for a separate I/O thread

### Registration sequence

```zig
// Plugin load - called by REAPER
export fn ReaperPluginEntry(instance: HINSTANCE, rec: *reaper_plugin_info_t) c_int {
    if (rec == null) {
        // UNLOAD - rec is NULL
        g_bridge.unregister();
        g_bridge.deinit();
        return 0;
    }
    
    // LOAD - import APIs, then register
    plugin_register = rec.GetFunc("plugin_register");
    // ... import other functions
    
    g_bridge = ReaperBridge.init(plugin_register, ws_broadcast) catch return 0;
    g_bridge.register();
    
    return 1;  // Success
}
```

---

## Hybrid architecture for WebSocket remote control

### Recommended pattern

```
┌─────────────────────────────────────────────────────────────────┐
│                    REAPER Main Thread                           │
├─────────────────────────────────────────────────────────────────┤
│  IReaperControlSurface callbacks (PUSH - instant)               │
│  ├─ SetPlayState() ──────────────┐                              │
│  ├─ SetSurfaceVolume() ──────────┤                              │
│  ├─ SetSurfaceMute() ────────────┼──► Event Queue ──► WS Send   │
│  ├─ Extended(SETFXPARAM) ────────┤    (lock-free)               │
│  └─ Extended(MARKERCHANGE) ──────┘                              │
│                                                                  │
│  Run() callback (POLL @ ~30Hz - only for position/meters)       │
│  ├─ GetPlayPosition() ───────────┐                              │
│  └─ Track_GetPeakInfo() ─────────┼──► Throttle ──► WS Send      │
│       (if playing)               │    (10Hz max)                │
└─────────────────────────────────────────────────────────────────┘
```

### Avoiding duplicate state checks

With callbacks handling most state, your `Run()` method becomes minimal:

```zig
fn runCallback(ctx: ?*anyopaque) callconv(.C) void {
    const self = getSelf(ctx);
    
    // Only poll what has NO callback
    if (self.is_playing) {
        // Throttle position updates to 10Hz (every 3rd Run() call)
        self.run_counter += 1;
        if (self.run_counter % 3 == 0) {
            const pos = GetPlayPosition();
            self.broadcast("position", .{ .time = pos });
        }
    }
    
    // Peak meters - only when clients subscribed
    if (self.meter_subscribers > 0) {
        self.broadcastMeterLevels();
    }
}
```

---

## Critical gotchas and best practices

1. **MSVC required on Windows** - REAPER's C++ ABI requires MSVC. Your C++ shim must be compiled with MSVC (or compatible clang-cl). The Zig portion links against the compiled C++ shim.

2. **Volume values are normalized (0.0-1.0)**, not dB. Use `SLIDER2DB()` from the REAPER API to convert to decibels for display.

3. **SetSurfaceSelected fires per-track** - When selecting multiple tracks, you'll receive one callback per track. Consider debouncing before broadcasting.

4. **Extended() parameter lifetime** - Pointer parameters are only valid during the callback. Copy values immediately if needed.

5. **Marker change callback has no details** - `CSURF_EXT_SETPROJECTMARKERCHANGE` only signals that *something* changed. You must re-enumerate all markers with `EnumProjectMarkers3()` to determine what.

6. **OnTrackSelection has quirks** - Per SWS source comments, it "doesn't work if Mixer option 'Scroll view when tracks activated' is disabled" and may be called before `CSURF_EXT_SETLASTTOUCHEDTRACK`.

7. **Empty strings are valid for hidden surfaces** - Return `""` from `GetTypeString()` to create an invisible surface (like SWS does) that won't appear in Preferences.

8. **Run() frequency varies** - While nominally ~30Hz, the actual frequency depends on REAPER's `g_config_csurf_rate` setting and system load.

---

## Conclusion

The IReaperControlSurface API provides push-based notifications for most DAW state, enabling you to replace 30Hz polling with instant callbacks for transport, volume, pan, mute, solo, selection, FX parameters, and markers. **Only playhead position and audio metering require continued polling**, which can be reduced to ~10Hz. The C++ shim pattern with function pointers provides a clean bridge to Zig while maintaining compatibility with REAPER's MSVC-dependent ABI. Register both `csurf_inst` for callbacks and use `Run()` for minimal polling—no separate timer needed.
