# Routing Modal Enhancement Plan

## Executive Summary

Enhance the RoutingModal with send pan/mode controls and hardware outputs. All APIs validated against REAPER documentation and existing codebase patterns.

---

## 1. Current State

### Backend Polling (sends.zig)

| Field | Status | Notes |
|-------|--------|-------|
| `srcTrackIdx` | ✅ Polled | Line 104 |
| `sendIndex` | ✅ Polled | Line 105 |
| `destName` | ✅ Polled | Lines 107-112 |
| `volume` | ✅ Polled | Line 115 |
| `muted` | ✅ Polled | Line 116 |
| `mode` | ✅ Polled | Line 117 (0=post-fader, 1=pre-fx, 3=post-fx) |
| `pan` | ❌ Not polled | Comment at line 119: "would require additional API calls" |
| `destTrackIdx` | ❌ Not polled | **Skipping** - O(n) cost, destName sufficient |

### Backend Commands

| Command | Status |
|---------|--------|
| `send/setVolume` | ✅ Exists (with CSurf + gesture tracking) |
| `send/setMute` | ✅ Exists |
| `send/setPan` | ❌ Missing |
| `send/setMode` | ❌ Missing |

### Frontend Types (WebSocketTypes.ts)

```typescript
export interface WSSendSlot {
  srcTrackIdx: number;   // ✅ Populated
  destTrackIdx: number;  // ❌ Always 0 (skipping)
  sendIndex: number;     // ✅ Populated
  volume: number;        // ✅ Populated
  pan: number;           // ❌ Not populated yet
  muted: boolean;        // ✅ Populated
  mode: number;          // ✅ Populated
}
```

### Missing Entirely

- Hardware outputs (REAPER send category 1)

---

## 2. REAPER API Reference

### Category Parameter (CRITICAL)

`GetTrackNumSends` and `GetTrackSendInfo_Value` use a `category` parameter:

| Category | Meaning | Current Status |
|----------|---------|----------------|
| `0` | Sends (track→track) | ✅ Implemented |
| `-1` | Receives (track←track) | ✅ Implemented |
| `1` | Hardware outputs (track→physical) | ❌ Not implemented |

**Note:** Original plan incorrectly stated `1=receives, 2=hardware`. Corrected above.

### CSurf APIs Available

| Function | Status | Use Case |
|----------|--------|----------|
| `CSurf_OnSendVolumeChange` | ✅ Bound in raw.zig | Send volume with undo coalescing |
| `CSurf_OnSendPanChange` | ❌ **Exists but not bound** | Send pan with undo coalescing |

### Send Info Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `D_VOL` | f64 | Volume (linear, 1.0 = 0dB) |
| `D_PAN` | f64 | Pan (-1.0 to +1.0) |
| `B_MUTE` | bool | Mute state |
| `I_SENDMODE` | int | 0=post-fader, 1=pre-fx, 3=post-fx |
| `P_DESTTRACK` | ptr | Destination track pointer (not index!) |
| `I_DSTCHAN` | int | Destination channel (for hw outputs) |

---

## 3. Implementation Plan

### Phase 1: Backend - Send Pan & Mode

**1.1 Add CSurf_OnSendPanChange FFI binding**

File: `extension/src/reaper/raw.zig`

```zig
// In Api struct
csurf_OnSendPanChange: ?*const fn (?*anyopaque, c_int, f64, bool) callconv(.C) f64 = null,

// In loadFunctions()
self.csurf_OnSendPanChange = @ptrCast(rec.GetFunc("CSurf_OnSendPanChange"));

// Wrapper method
pub fn trackSendSetPan(self: *const Api, track: *anyopaque, send_idx: c_int, pan: f64) f64 {
    const f = self.csurf_OnSendPanChange orelse return pan;
    return f(track, send_idx, pan, false); // absolute mode
}

pub fn trackSendGetPan(self: *const Api, track: *anyopaque, send_idx: c_int) f64 {
    const f = self.getTrackSendInfo_Value orelse return 0.0;
    return f(track, 0, send_idx, "D_PAN");
}
```

**1.2 Add pan to sends polling**

File: `extension/src/sends.zig` (around line 117)

```zig
slot.pan = api.trackSendGetPan(track, @intCast(send_i));
```

**1.3 Add send/setPan command**

File: `extension/src/commands/send.zig`

```zig
pub fn handleSetPan(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const send_idx = cmd.getInt("sendIdx") orelse {
        response.err("MISSING_SEND_IDX", "sendIdx is required");
        return;
    };
    const pan = cmd.getFloat("pan") orelse {
        response.err("MISSING_PAN", "pan is required (-1.0 to 1.0)");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const clamped = @max(-1.0, @min(1.0, pan));
    _ = api.trackSendSetPan(track, send_idx, clamped);

    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.sendPan(track_idx, send_idx));
    }

    response.success(null);
}
```

**1.4 Add send/setMode command**

```zig
pub fn handleSetMode(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const send_idx = cmd.getInt("sendIdx") orelse {
        response.err("MISSING_SEND_IDX", "sendIdx is required");
        return;
    };
    const mode = cmd.getInt("mode") orelse {
        response.err("MISSING_MODE", "mode is required (0=post-fader, 1=pre-fx, 3=post-fx)");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Validate mode value (no mode 2 in REAPER)
    if (mode != 0 and mode != 1 and mode != 3) {
        response.err("INVALID_MODE", "mode must be 0, 1, or 3");
        return;
    }

    _ = api.trackSendSetMode(track, send_idx, mode);
    response.success(null);
}
```

**1.5 Add gesture control type**

File: `extension/src/gesture_state.zig`

```zig
pub const ControlType = enum {
    volume,
    pan,
    send_volume,
    send_pan,  // ADD
};

pub fn sendPan(track_idx: c_int, send_idx: c_int) ControlId {
    return .{ .control_type = .send_pan, .track_idx = track_idx, .sub_idx = send_idx };
}
```

File: `extension/src/commands/gesture.zig` (in parseControlId)

```zig
} else if (std.mem.eql(u8, control_type_str, "sendPan")) {
    const send_idx = cmd.getInt("sendIdx") orelse return null;
    return gesture_state.ControlId.sendPan(track_idx, send_idx);
}
```

**1.6 Register commands**

File: `extension/src/commands/registry.zig`

```zig
.{ "send/setPan", send.handleSetPan },
.{ "send/setMode", send.handleSetMode },
```

---

### Phase 2: Frontend - Send Pan & Mode UI

**2.1 Add WebSocket commands**

File: `frontend/src/core/WebSocketCommands.ts`

```typescript
export const send = {
  // ... existing
  setPan: (trackIdx: number, sendIdx: number, pan: number): WSCommand => ({
    command: 'send/setPan',
    params: { trackIdx, sendIdx, pan },
  }),
  setMode: (trackIdx: number, sendIdx: number, mode: number): WSCommand => ({
    command: 'send/setMode',
    params: { trackIdx, sendIdx, mode },
  }),
};

export const gesture = {
  // ... existing, add:
  startSendPan: (trackIdx: number, sendIdx: number): WSCommand => ({
    command: 'gesture/start',
    params: { controlType: 'sendPan', trackIdx, sendIdx },
  }),
  endSendPan: (trackIdx: number, sendIdx: number): WSCommand => ({
    command: 'gesture/end',
    params: { controlType: 'sendPan', trackIdx, sendIdx },
  }),
};
```

**2.2 Add MiniPanControl component**

File: `frontend/src/components/Mixer/MiniPanControl.tsx`

```tsx
interface MiniPanControlProps {
  pan: number;
  onChange: (pan: number) => void;
  onGestureStart?: () => void;
  onGestureEnd?: () => void;
  disabled?: boolean;
}

function MiniPanControl({ pan, onChange, onGestureStart, onGestureEnd, disabled }: MiniPanControlProps) {
  // Horizontal slider: -1 (L) to +1 (R)
  // Double-tap to center
  // Uses sends-* design tokens
  // 44px min touch target height
  // Gesture tracking for undo coalescing
}
```

**2.3 Add SendModeToggle component**

File: `frontend/src/components/Mixer/SendModeToggle.tsx`

```tsx
interface SendModeToggleProps {
  mode: number;
  onToggle: (newMode: number) => void;
  disabled?: boolean;
}

function SendModeToggle({ mode, onToggle, disabled }: SendModeToggleProps) {
  // Badge showing: POST (mode 0), PRE-FX (mode 1), PRE (mode 3)
  // Tap to cycle: 0 → 1 → 3 → 0
  // Visual distinction per mode using semantic tokens
}
```

**2.4 Integrate into RoutingModal**

File: `frontend/src/components/Mixer/RoutingModal.tsx`

Add to HorizontalSendFader row:

- Mode toggle badge (left of mute button)
- MiniPanControl (between fader and dB readout)

---

### Phase 3: Backend - Hardware Outputs

**3.1 Add HardwareOutputSlot struct**

File: `extension/src/sends.zig`

```zig
pub const HardwareOutputSlot = struct {
    src_track_idx: c_int = 0,
    hw_output_idx: u16 = 0,
    output_name: [MAX_SEND_NAME_LEN]u8 = undefined,
    output_name_len: usize = 0,
    volume: f64 = 1.0,
    pan: f64 = 0.0,
    muted: bool = false,
    mode: c_int = 0,

    pub fn getOutputName(self: *const HardwareOutputSlot) []const u8 {
        return self.output_name[0..self.output_name_len];
    }
};
```

**3.2 Add HwOutputsState and polling**

File: `extension/src/sends.zig`

```zig
pub const HwOutputsState = struct {
    hw_outputs: []HardwareOutputSlot = &.{},

    pub fn poll(allocator: Allocator, api: anytype) !HwOutputsState {
        // Count hw outputs across all tracks
        var total: usize = 0;
        const track_count = api.countTracks();
        for (0..@intCast(track_count + 1)) |i| {
            if (api.getTrackByUnifiedIdx(@intCast(i))) |track| {
                total += @intCast(api.trackHwOutputCount(track));
            }
        }

        if (total == 0) return .{};

        const slots = try allocator.alloc(HardwareOutputSlot, total);
        // Populate using category=1 API calls
        var idx: usize = 0;
        for (0..@intCast(track_count + 1)) |i| {
            if (api.getTrackByUnifiedIdx(@intCast(i))) |track| {
                const hw_count = api.trackHwOutputCount(track);
                for (0..@intCast(hw_count)) |hw_i| {
                    slots[idx].src_track_idx = @intCast(i);
                    slots[idx].hw_output_idx = @intCast(hw_i);
                    slots[idx].volume = api.trackHwOutputGetVolume(track, @intCast(hw_i));
                    slots[idx].pan = api.trackHwOutputGetPan(track, @intCast(hw_i));
                    slots[idx].muted = api.trackHwOutputGetMute(track, @intCast(hw_i));
                    slots[idx].mode = api.trackHwOutputGetMode(track, @intCast(hw_i));
                    // Generate output name from channel index
                    const chan = api.trackHwOutputGetDestChannel(track, @intCast(hw_i));
                    const name = generateHwOutputName(chan, &slots[idx].output_name);
                    slots[idx].output_name_len = name.len;
                    idx += 1;
                }
            }
        }
        return .{ .hw_outputs = slots };
    }
};

fn generateHwOutputName(chan: c_int, buf: []u8) []const u8 {
    // I_DSTCHAN encodes: (dest_chan_index) | (num_chans << 10)
    const dest_chan = chan & 0x3FF;
    const num_chans = (chan >> 10) & 0x3FF;
    const end_chan = dest_chan + num_chans;
    return std.fmt.bufPrint(buf, "HW Out {d}/{d}", .{ dest_chan + 1, end_chan }) catch "HW Out";
}
```

**3.3 Add raw API methods**

File: `extension/src/reaper/raw.zig`

```zig
pub fn trackHwOutputCount(self: *const Api, track: *anyopaque) c_int {
    const f = self.getTrackNumSends orelse return 0;
    return f(track, 1);  // category 1 = hardware outputs
}

pub fn trackHwOutputGetVolume(self: *const Api, track: *anyopaque, hw_idx: c_int) f64 {
    const f = self.getTrackSendInfo_Value orelse return 1.0;
    return f(track, 1, hw_idx, "D_VOL");
}

pub fn trackHwOutputGetPan(self: *const Api, track: *anyopaque, hw_idx: c_int) f64 {
    const f = self.getTrackSendInfo_Value orelse return 0.0;
    return f(track, 1, hw_idx, "D_PAN");
}

pub fn trackHwOutputGetMute(self: *const Api, track: *anyopaque, hw_idx: c_int) bool {
    const f = self.getTrackSendInfo_Value orelse return false;
    return f(track, 1, hw_idx, "B_MUTE") != 0;
}

pub fn trackHwOutputGetMode(self: *const Api, track: *anyopaque, hw_idx: c_int) c_int {
    const f = self.getTrackSendInfo_Value orelse return 0;
    return @intFromFloat(f(track, 1, hw_idx, "I_SENDMODE"));
}

pub fn trackHwOutputGetDestChannel(self: *const Api, track: *anyopaque, hw_idx: c_int) c_int {
    const f = self.getTrackSendInfo_Value orelse return 0;
    return @intFromFloat(f(track, 1, hw_idx, "I_DSTCHAN"));
}

// Setters
pub fn trackHwOutputSetVolume(self: *const Api, track: *anyopaque, hw_idx: c_int, volume: f64) bool {
    const f = self.setTrackSendInfo_Value orelse return false;
    return f(track, 1, hw_idx, "D_VOL", volume);
}

pub fn trackHwOutputSetPan(self: *const Api, track: *anyopaque, hw_idx: c_int, pan: f64) bool {
    const f = self.setTrackSendInfo_Value orelse return false;
    return f(track, 1, hw_idx, "D_PAN", pan);
}

pub fn trackHwOutputSetMute(self: *const Api, track: *anyopaque, hw_idx: c_int, muted: bool) bool {
    const f = self.setTrackSendInfo_Value orelse return false;
    return f(track, 1, hw_idx, "B_MUTE", if (muted) 1.0 else 0.0);
}

pub fn trackHwOutputSetMode(self: *const Api, track: *anyopaque, hw_idx: c_int, mode: c_int) bool {
    const f = self.setTrackSendInfo_Value orelse return false;
    return f(track, 1, hw_idx, "I_SENDMODE", @floatFromInt(mode));
}
```

**3.4 Add hw/* commands**

File: `extension/src/commands/hw_output.zig` (NEW FILE)

Commands: `hw/setVolume`, `hw/setMute`, `hw/setPan`, `hw/setMode`

Pattern identical to send.zig handlers but using `hwIdx` parameter and `trackHwOutput*` API methods.

**3.5 Add gesture control types**

File: `extension/src/gesture_state.zig`

```zig
pub const ControlType = enum {
    volume,
    pan,
    send_volume,
    send_pan,
    hw_output_volume,  // ADD
    hw_output_pan,     // ADD
};

pub fn hwOutputVolume(track_idx: c_int, hw_idx: c_int) ControlId {
    return .{ .control_type = .hw_output_volume, .track_idx = track_idx, .sub_idx = hw_idx };
}

pub fn hwOutputPan(track_idx: c_int, hw_idx: c_int) ControlId {
    return .{ .control_type = .hw_output_pan, .track_idx = track_idx, .sub_idx = hw_idx };
}
```

**3.6 Register commands**

File: `extension/src/commands/registry.zig`

```zig
.{ "hw/setVolume", hw_output.handleSetVolume },
.{ "hw/setMute", hw_output.handleSetMute },
.{ "hw/setPan", hw_output.handleSetPan },
.{ "hw/setMode", hw_output.handleSetMode },
```

**3.7 Add polling to main.zig (MEDIUM tier, 5Hz)**

Broadcast `hw_outputs_state` event on change.

---

### Phase 4: Frontend - Hardware Outputs UI

**4.1 Add types**

File: `frontend/src/core/WebSocketTypes.ts`

```typescript
export interface WSHardwareOutputSlot {
  srcTrackIdx: number;
  hwOutputIdx: number;
  outputName: string;
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
}
```

**4.2 Add store slice**

File: `frontend/src/store/slices/hwOutputsSlice.ts` (NEW)

```typescript
export interface HwOutputsSlice {
  hwOutputs: WSHardwareOutputSlot[];
  setHwOutputs: (hwOutputs: WSHardwareOutputSlot[]) => void;
}

export function getHwOutputsFromTrack(
  hwOutputs: WSHardwareOutputSlot[],
  trackIdx: number
): WSHardwareOutputSlot[] {
  return hwOutputs.filter((hw) => hw.srcTrackIdx === trackIdx);
}
```

**4.3 Add WebSocket commands**

File: `frontend/src/core/WebSocketCommands.ts`

```typescript
export const hwOutput = {
  setVolume: (trackIdx: number, hwIdx: number, volume: number): WSCommand => ({
    command: 'hw/setVolume',
    params: { trackIdx, hwIdx, volume },
  }),
  setMute: (trackIdx: number, hwIdx: number, muted: number): WSCommand => ({
    command: 'hw/setMute',
    params: { trackIdx, hwIdx, muted },
  }),
  setPan: (trackIdx: number, hwIdx: number, pan: number): WSCommand => ({
    command: 'hw/setPan',
    params: { trackIdx, hwIdx, pan },
  }),
  setMode: (trackIdx: number, hwIdx: number, mode: number): WSCommand => ({
    command: 'hw/setMode',
    params: { trackIdx, hwIdx, mode },
  }),
};
```

**4.4 Add HardwareOutputRow component**

File: `frontend/src/components/Mixer/HardwareOutputRow.tsx` (NEW)

Same structure as HorizontalSendFader:

- Mode badge
- Mute button
- Output name (e.g., "HW Out 1/2")
- Horizontal fader
- MiniPanControl
- dB readout

**4.5 Update RoutingModal with hardware tab**

File: `frontend/src/components/Mixer/RoutingModal.tsx`

```tsx
type RoutingTab = 'sends' | 'hardware' | 'receives';

// Add tab button
<TabButton
  label={`Hardware (${trackHwOutputs.length})`}
  active={activeTab === 'hardware'}
  onClick={() => setActiveTab('hardware')}
/>

// Render hardware outputs
{activeTab === 'hardware' && trackHwOutputs.map((hw) => (
  <HardwareOutputRow
    key={`${hw.srcTrackIdx}-${hw.hwOutputIdx}`}
    {...hw}
  />
))}
```

---

## 4. Files to Modify

### Backend - Phase 1 (Send Pan/Mode)

| File | Changes |
|------|---------|
| `extension/src/reaper/raw.zig` | Add CSurf_OnSendPanChange FFI, trackSendGetPan, trackSendSetPan |
| `extension/src/reaper/real.zig` | Add RealBackend wrappers with FFI validation |
| `extension/src/reaper/backend.zig` | Add method names to comptime validation |
| `extension/src/reaper/mock/tracks.zig` | Add mock implementations |
| `extension/src/sends.zig` | Poll pan field |
| `extension/src/commands/send.zig` | Add handleSetPan, handleSetMode |
| `extension/src/commands/registry.zig` | Register send/setPan, send/setMode |
| `extension/src/gesture_state.zig` | Add send_pan ControlType |
| `extension/src/commands/gesture.zig` | Parse sendPan control type |

### Backend - Phase 3 (Hardware Outputs)

| File | Changes |
|------|---------|
| `extension/src/reaper/raw.zig` | Add trackHwOutput* methods |
| `extension/src/reaper/real.zig` | Add RealBackend wrappers |
| `extension/src/reaper/backend.zig` | Add hw output method names |
| `extension/src/reaper/mock/tracks.zig` | Add hw output mocks |
| `extension/src/sends.zig` | Add HardwareOutputSlot, HwOutputsState, polling |
| `extension/src/commands/hw_output.zig` | **NEW** - hw/* command handlers |
| `extension/src/commands/registry.zig` | Register hw/* commands |
| `extension/src/gesture_state.zig` | Add hw_output_volume, hw_output_pan |
| `extension/src/commands/gesture.zig` | Parse hw gesture control types |
| `extension/src/tiered_state.zig` | Add hw_output_slots to MediumTierState |
| `extension/src/main.zig` | Add hw outputs polling + broadcast |

### Frontend - Phase 2 (Send UI)

| File | Changes |
|------|---------|
| `frontend/src/core/WebSocketCommands.ts` | Add send.setPan, send.setMode, gesture commands |
| `frontend/src/components/Mixer/MiniPanControl.tsx` | **NEW** |
| `frontend/src/components/Mixer/SendModeToggle.tsx` | **NEW** |
| `frontend/src/components/Mixer/RoutingModal.tsx` | Integrate new controls |

### Frontend - Phase 4 (Hardware UI)

| File | Changes |
|------|---------|
| `frontend/src/core/WebSocketTypes.ts` | Add WSHardwareOutputSlot |
| `frontend/src/core/WebSocketCommands.ts` | Add hwOutput commands |
| `frontend/src/store/slices/hwOutputsSlice.ts` | **NEW** |
| `frontend/src/store/index.ts` | Integrate slice, handle event |
| `frontend/src/components/Mixer/HardwareOutputRow.tsx` | **NEW** |
| `frontend/src/components/Mixer/RoutingModal.tsx` | Add hardware tab |

### Documentation

| File | Changes |
|------|---------|
| `extension/API.md` | Document send/setPan, send/setMode, hw/* commands |
| `DEVELOPMENT.md` | Add send/hw gesture tracking notes |

---

## 5. WebSocket Commands Summary

### New Send Commands

| Command | Parameters | Description |
|---------|------------|-------------|
| `send/setPan` | `trackIdx`, `sendIdx`, `pan` | Set send pan (-1.0 to 1.0) |
| `send/setMode` | `trackIdx`, `sendIdx`, `mode` | Set send mode (0, 1, or 3) |

### New Hardware Output Commands

| Command | Parameters | Description |
|---------|------------|-------------|
| `hw/setVolume` | `trackIdx`, `hwIdx`, `volume` | Set hw output volume |
| `hw/setMute` | `trackIdx`, `hwIdx`, `muted` | Set hw output mute |
| `hw/setPan` | `trackIdx`, `hwIdx`, `pan` | Set hw output pan |
| `hw/setMode` | `trackIdx`, `hwIdx`, `mode` | Set hw output mode |

### New Gesture Control Types

| Control Type | Parameters | Use Case |
|--------------|------------|----------|
| `sendPan` | `trackIdx`, `sendIdx` | Send pan fader drag |
| `hwOutputVolume` | `trackIdx`, `hwIdx` | HW output volume drag |
| `hwOutputPan` | `trackIdx`, `hwIdx` | HW output pan drag |

---

## 6. Testing Requirements

### Backend Unit Tests

- `send.handleSetPan` with valid/invalid params
- `send.handleSetMode` with mode values 0, 1, 3 (valid) and 2 (invalid)
- `hw_output.handleSetVolume/Pan/Mute/Mode`
- HwOutputsState.poll with mock tracks
- Gesture tracking for all new ControlTypes
- MockBackend implementations

### Frontend Tests

- MiniPanControl drag behavior
- SendModeToggle mode cycling (0→1→3→0)
- HardwareOutputRow component
- Gesture start/end for all new control types
- Double-tap to center on pan controls
- Tab switching in RoutingModal

### Integration Tests

- Send pan changes reflect in REAPER
- Mode changes affect signal flow
- Hardware output volume/pan/mute changes
- Undo coalescing during continuous drags

---

## 7. Implementation Order

1. **Phase 1** - Backend send pan/mode polling + commands
2. **Phase 2** - Frontend MiniPanControl + SendModeToggle
3. **Test milestone** - Verify send pan/mode end-to-end
4. **Phase 3** - Backend hardware outputs polling + commands
5. **Phase 4** - Frontend hardware tab + HardwareOutputRow
6. **Test milestone** - Verify hardware outputs end-to-end
7. **Documentation** - Update API.md, DEVELOPMENT.md

Each phase can be merged independently after its test milestone passes.

---

## 8. Design Decisions

### Skip destTrackIdx

- Requires O(n) track enumeration per send
- `destName` is already populated and sufficient for UI
- Can add later via separate command if needed

### Separate send_pan gesture type

- Frontend may have separate pan control with different gesture timing
- Explicit tracking allows fine-grained undo coalescing

### Generated hardware output names

- `GetTrackSendName` doesn't work for category=1
- Generate from `I_DSTCHAN`: "HW Out 1/2"
- Can enhance later with `GetOutputChannelName` for device names

### Separate hw_outputs_state event

- Sends and hw outputs change independently
- Clear separation in frontend store
- Follows existing pattern of domain-specific events
