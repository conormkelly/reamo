# REAPER MIDI routing and latency for touch instruments

**WebSocket with StuffMIDIMessage is the optimal architecture for REAmo's touch instruments**, achieving **5-15ms total latency** from touch to audio. This matches Logic Remote's performance target and avoids cross-platform virtual MIDI port complexity. StuffMIDIMessage mode 0 (VKB) is the correct API for real-time note input, processing MIDI at audio block boundaries with negligible internal latency.

The critical latency factor is REAPER's audio buffer setting—not the transport layer. At **128 samples/44.1kHz**, buffer latency is just 2.9ms, making the WebSocket→Extension→StuffMIDIMessage path entirely viable for professional touch instrument response.

## StuffMIDIMessage is the right API for real-time input

The `StuffMIDIMessage(int mode, int msg1, int msg2, int msg3)` function is REAPER's primary mechanism for extension-injected MIDI. For touch instruments, **mode 0 (VKB)** is the correct choice:

| Mode | Behavior | Use case |
|------|----------|----------|
| **0** | Virtual Keyboard input | Note on/off, CC, pitch bend to armed tracks |
| **1** | Control/Actions path | MIDI Learn, action triggers, shortcuts |
| **2** | VKB on current channel | Ignores msg1 channel, uses VKB's selected channel |
| **16+** | External MIDI output | Sends to hardware MIDI outputs (16=device 0) |

Mode 0 routes MIDI to all tracks with input set to "Virtual MIDI Keyboard" or "All MIDI Inputs" that are record-armed. The message bytes follow standard MIDI format: `msg1` = status byte with channel (e.g., `0x90` for Note On channel 1), `msg2` = note/CC number, `msg3` = velocity/value.

**Thread safety is critical**: StuffMIDIMessage must be called from REAPER's main thread only. Your Zig extension receiving WebSocket messages should queue incoming MIDI and process it during the main thread callback (like `timer()` or a registered hook). Messages are queued and processed at audio block boundaries, similar to hardware MIDI input, which provides deterministic timing but means resolution is limited to buffer size.

No explicit rate limiting exists in the API, but flooding StuffMIDIMessage faster than the audio block rate provides no benefit—messages simply queue until the next block processes.

## Latency breakdown favors the WebSocket architecture

The total touch-to-audio latency comprises several stages. Here's the breakdown for the WebSocket path:

| Component | Typical latency |
|-----------|-----------------|
| Touch detection → JavaScript | 1-5ms |
| WebSocket localhost transmission | 0.1-0.5ms |
| Zig extension message processing | <0.1ms |
| StuffMIDIMessage → VKB queue | <0.1ms |
| Audio buffer processing | Buffer size ÷ sample rate |
| DAC output | 1-3ms |

At **128 samples/44.1kHz**, total estimated latency is **5-12ms**. At **256 samples**, expect **8-18ms**. This comfortably meets the professional target of **10ms with <1ms jitter** established by Wessel and Wright's widely-cited research. Logic Remote users report 60ms+ latency primarily due to WiFi variability—your localhost WebSocket eliminates this uncertainty entirely.

The buffer setting dominates perceived latency. Recommend exposing audio buffer configuration in REAmo's UI so users can optimize for their hardware. Buffer latency formula: `latency_ms = (buffer_size / sample_rate) × 1000`.

## WebMIDI offers minimal advantage, adds complexity

Comparing the two architectures:

**WebSocket → Extension → StuffMIDIMessage**

- Transport latency: ~0.5ms localhost
- Single connection for all data (control, MIDI, state sync)
- No per-platform virtual MIDI setup required
- Full REAPER API access for track info, routing, feedback
- Works in any modern browser

**WebMIDI → Virtual Port → REAPER MIDI Input**

- Transport latency: 1-10ms through virtual port (IAC Driver, loopMIDI)
- Requires user to configure virtual MIDI ports and select them in REAPER
- macOS IAC Driver is built-in; Windows requires third-party loopMIDI installation
- Firefox WebMIDI support is limited; Chrome/Edge only
- Cannot easily query REAPER state or send bidirectional data

**Recommendation**: Stay with WebSocket-only architecture. The **0.5-10ms** latency difference doesn't justify the setup complexity and cross-platform inconsistency. A hybrid approach (WebMIDI for notes, WebSocket for control) doubles the connection surface area without meaningful latency gains.

If users report latency issues, investigate REAPER's buffer settings first—transport latency is not the bottleneck.

## MIDI message implementation patterns

### Note On / Note Off

```zig
// Note On: status 0x90-0x9F, channel in lower nibble
fn sendNoteOn(channel: u8, note: u8, velocity: u8) void {
    const status = 0x90 | (channel & 0x0F);
    reaper.StuffMIDIMessage(0, status, note, velocity);
}

// Note Off: status 0x80-0x8F (or Note On with velocity 0)
fn sendNoteOff(channel: u8, note: u8, velocity: u8) void {
    const status = 0x80 | (channel & 0x0F);
    reaper.StuffMIDIMessage(0, status, note, velocity);
}
```

### Pitch Bend (14-bit resolution)

Pitch bend uses a **14-bit value** split across msg2 (LSB) and msg3 (MSB). Center position is **8192** (0x2000).

```zig
// Pitch Bend: status 0xE0-0xEF
// value range: 0-16383, center = 8192
fn sendPitchBend(channel: u8, value: u14) void {
    const status = 0xE0 | (channel & 0x0F);
    const lsb = @truncate(u8, value & 0x7F);        // lower 7 bits
    const msb = @truncate(u8, (value >> 7) & 0x7F); // upper 7 bits
    reaper.StuffMIDIMessage(0, status, lsb, msb);
}

// Convert from -1.0 to 1.0 float
fn pitchBendFromFloat(bend: f32) u14 {
    const clamped = std.math.clamp(bend, -1.0, 1.0);
    return @floatToInt(u14, (clamped + 1.0) * 8191.5);
}
```

### Channel Aftertouch (mono pressure)

```zig
// Channel Aftertouch: status 0xD0-0xDF
// Single pressure value for entire channel
fn sendChannelAftertouch(channel: u8, pressure: u8) void {
    const status = 0xD0 | (channel & 0x0F);
    reaper.StuffMIDIMessage(0, status, pressure, 0);
}
```

### Polyphonic Aftertouch (per-note pressure)

```zig
// Poly Aftertouch: status 0xA0-0xAF
// Per-note pressure for MPE-style expression
fn sendPolyAftertouch(channel: u8, note: u8, pressure: u8) void {
    const status = 0xA0 | (channel & 0x0F);
    reaper.StuffMIDIMessage(0, status, note, pressure);
}
```

### Continuous controller update rates

For high-frequency continuous controllers, implement rate limiting on the browser side:

| Controller | Recommended rate | Rationale |
|------------|------------------|-----------|
| Pitch bend | 60-120 Hz | Smooth glides without flooding MIDI |
| Channel aftertouch | 50-100 Hz | Pressure changes are gradual |
| Poly aftertouch | 30-50 Hz per note | Multiply by active note count |
| Mod wheel (CC 1) | 20-50 Hz | Slower musical gestures |
| Expression (CC 11) | 20-50 Hz | Similar to mod wheel |

MIDI bandwidth ceiling is approximately **500 Hz** for 3-byte messages. With 4-note polyphony each sending poly aftertouch at 50 Hz, you're consuming 200 messages/second—well within limits. Scale update rates inversely with polyphony.

## Track routing and instrument targeting

### VKB mode routes to armed tracks

StuffMIDIMessage mode 0 sends to REAPER's Virtual MIDI Keyboard system, which routes to tracks with:

1. Input set to "Virtual MIDI Keyboard" or "All MIDI Inputs"
2. Track record-armed (red button)
3. Record monitoring enabled (for audible output without recording)

**There is no API to inject MIDI directly to a specific track by GUID or index** for real-time playback. The VKB system is the only real-time injection point.

### Targeting a specific track programmatically

To route to a specific track, your extension can:

```zig
// 1. Get target track by index or GUID
const track = reaper.GetTrack(null, trackIndex);

// 2. Set track input to VKB (I_RECINPUT = 4096 for VKB input)
reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", 4096 + 63); // 63 = all channels

// 3. Arm track for recording
reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1);

// 4. Enable record monitoring
reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1);

// Now StuffMIDIMessage(0, ...) will reach this track
```

For REAmo, consider exposing track selection in the UI and managing arming state from the extension. The browser sends MIDI; the extension handles routing configuration.

### Recording extension-injected MIDI

MIDI injected via StuffMIDIMessage **can be recorded**. When REAPER transport is recording and a track is armed with VKB input, incoming messages are captured to new MIDI items. REAPER 7+ also supports retroactive MIDI recording—capturing VKB input even when not recording, accessible via "MIDI: Insert recent retroactively recorded MIDI for armed tracks."

## MIDI_eventlist vs StuffMIDIMessage

Use StuffMIDIMessage for **real-time input**. Use MIDI_eventlist APIs for **programmatic MIDI item editing**:

| API | Use case |
|-----|----------|
| `StuffMIDIMessage` | Live note input, touch instruments, OSC conversion |
| `MIDI_InsertNote` | Adding notes to existing MIDI items |
| `MIDI_InsertCC` | Adding CC automation to takes |
| `MIDI_GetAllEvts` / `MIDI_SetAllEvts` | Bulk MIDI manipulation (most efficient for batch ops) |
| `MIDI_eventlist_Create` | Building event lists for takes programmatically |

For REAmo's touch instruments, **StuffMIDIMessage is the only appropriate choice**—the eventlist APIs modify recorded MIDI items, not the real-time input stream.

## Complete REAPER API reference for REAmo

### Real-time MIDI injection

- `StuffMIDIMessage(mode, msg1, msg2, msg3)` — Primary injection API

### Device enumeration

- `GetNumMIDIInputs()` / `GetNumMIDIOutputs()` — Count available devices
- `GetMIDIInputName(dev, nameOut, sz)` / `GetMIDIOutputName(...)` — Get device names
- `GetMaxMidiInputs()` / `GetMaxMidiOutputs()` — Maximum possible devices

### Track configuration

- `GetTrack(proj, idx)` — Get track by index
- `GetTrackGUID(track)` — Get track GUID string
- `SetMediaTrackInfo_Value(track, "I_RECINPUT", val)` — Set MIDI input (4096 = VKB)
- `SetMediaTrackInfo_Value(track, "I_RECARM", 1)` — Arm track
- `SetMediaTrackInfo_Value(track, "I_RECMON", 1)` — Enable monitoring

### MIDI item manipulation (non-real-time)

- `MIDI_InsertNote(take, selected, muted, startppq, endppq, chan, pitch, vel)`
- `MIDI_InsertCC(take, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)`
- `MIDI_GetAllEvts(take, buf, buf_sz)` — Get raw MIDI data
- `MIDI_SetAllEvts(take, buf, buf_sz)` — Set raw MIDI data (call MIDI_Sort after)
- `MIDI_Sort(take)` — Re-sort after bulk edits

### Control surface extension (advanced)

- `plugin_register("csurf_inst", instance)` — Register control surface
- `IReaperControlSurface::Run()` — Main loop for incoming MIDI (main thread)
- `CreateMIDIInput(idx)` / `CreateMIDIOutput(idx, ...)` — Dedicated MIDI port access

For REAmo's architecture, the CSurf API is overkill—StuffMIDIMessage provides everything needed for touch instrument input without the complexity of implementing a full control surface.

## Conclusion

Stick with the **WebSocket → Zig Extension → StuffMIDIMessage(mode=0)** architecture. This path delivers **5-15ms latency** depending on buffer settings, which matches professional standards for touch instruments. The key implementation details:

1. Call StuffMIDIMessage from **main thread only**—queue WebSocket messages and process in timer callback
2. Use **mode 0** for all note/CC/pitch bend input to VKB
3. Rate-limit continuous controllers to **60-120 Hz** for pitch bend, **50 Hz** for aftertouch
4. Target specific tracks by **arming them and setting VKB input** via the extension
5. Advise users to set **128-256 sample buffer** for lowest latency

WebMIDI adds complexity without meaningful latency benefit for localhost communication. The bottleneck is always the audio buffer, not the transport layer.
