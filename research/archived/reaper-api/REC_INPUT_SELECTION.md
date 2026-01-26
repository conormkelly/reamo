# REAPER I_RECINPUT encoding: Complete specification verified

The I_RECINPUT parameter uses a compact bitfield encoding that handles audio (mono, stereo, multichannel, ReaRoute) and MIDI inputs in a single 32-bit integer. The authoritative source—the official **reaper_plugin_functions.h** from Justin Frankel's SDK—confirms all encoding details below. The reaper.fm web documentation is outdated (shows 5-bit MIDI device encoding); use the SDK specification.

## Complete bitfield structure

**For audio inputs** (bit 12/4096 NOT set):

- **Bits 0-9** (low 10 bits): Input channel index, 0-indexed (0..1023)
- **Bit 10** (1024): Stereo flag — uses 2 channels starting at the index
- **Bit 11** (2048): Multichannel flag — uses I_NCHAN channels starting at the index

**For MIDI inputs** (bit 12/4096 IS set):

- **Bits 0-4** (low 5 bits): Channel (0=all, 1-16=specific channel)
- **Bits 5-10** (next 6 bits): Device index (0-61=hardware, 62=VKB, 63=all inputs)

**Special value**: `-1` = no input selected

---

## Audio encoding answers

**Q1: Mono and stereo verification** — Your values are correct:

| Input | Value | Formula |
|-------|-------|---------|
| Mono channel 1 | 0 | channel_index |
| Mono channel 2 | 1 | channel_index |
| Stereo 1+2 | 1024 | 0 + 1024 |
| Stereo 3+4 | 1026 | 2 + 1024 |

**Arbitrary stereo pairs**: Yes, you can encode odd-start pairs like channels 2+3 as `1025` (1 + 1024). REAPER accepts any start index with the stereo flag. However, REAPER's UI only shows even-start pairs, so users cannot manually select odd pairs via the dropdown. Your web app could expose this if desired—it's technically valid.

**Q4: ReaRoute/Loopback encoding** — ReaRoute channels start at index **512**:

| Input | Value | Formula |
|-------|-------|---------|
| ReaRoute channel 1 (mono) | 512 | 512 + 0 |
| ReaRoute channel 2 (mono) | 513 | 512 + 1 |
| ReaRoute stereo 1/2 | 1536 | 512 + 0 + 1024 |
| ReaRoute stereo 3/4 | 1538 | 512 + 2 + 1024 |

**Q5: Multichannel bit 2048** — When set, the track records multiple channels determined by I_NCHAN (track channel count, 2-128 even). Practical use cases: surround recording (5.1, 7.1), ambisonic capture, multitrack drum sessions where you want contiguous channels routed through a single track. Formula: `channel_index + 2048`. The input grabs I_NCHAN channels starting at channel_index.

---

## MIDI encoding answers

**Q2: Bitfield verification** — All confirmed correct:

| Configuration | Value | Calculation |
|---------------|-------|-------------|
| Device 0, all channels | 4096 | 4096 + 0 + (0 << 5) |
| Device 0, channel 1 | 4097 | 4096 + 1 + (0 << 5) |
| Device 1, all channels | 4128 | 4096 + 0 + (1 << 5) = 4096 + 32 |
| All inputs, all channels | 6112 | 4096 + 0 + (63 << 5) = 4096 + 2016 |
| Virtual keyboard, all channels | 6080 | 4096 + 0 + (62 << 5) = 4096 + 1984 |

**Exact formula**: `4096 + channel + (device_index << 5)`

**Q3: Device index mapping** — Yes, `GetMIDIInputName(dev, ...)` device indices map **directly** to I_RECINPUT bits 5-10. No offset. Device 0 from GetMIDIInputName = device index 0 in encoding. Reserved indices 62 (VKB) and 63 (all inputs) are not enumerated by GetMIDIInputName.

**Q7: Virtual MIDI devices** — `GetNumMIDIInputs()` and `GetMaxMidiInputs()` **include** virtual MIDI devices (IAC Driver on macOS, loopMIDI on Windows) alongside hardware devices. These must be enabled in REAPER Preferences → Audio → MIDI Devices to appear. The functions return the same value—GetMaxMidiInputs is an alias.

---

## Reading and decoding

**Q6: Decoding reliability** — Yes, I_RECINPUT can be reliably decoded using the same bit logic. Reading via `GetMediaTrackInfo_Value` returns an integer (as double); writing via `SetMediaTrackInfo_Value` accepts the same encoding.

**Edge cases to handle**:

- Value -1: No input (not "record disabled"—that's I_RECARM = 0)
- Stereo/multichannel flags are mutually exclusive in practice
- MIDI flag (4096) takes precedence over audio encoding
- Invalid values don't crash REAPER but produce undefined behavior—validate before setting

---

## Complete test vectors

| Configuration | I_RECINPUT Value |
|---------------|------------------|
| No input | -1 |
| First mono audio channel (ch 1) | 0 |
| First stereo pair (ch 1+2) | 1024 |
| 8th mono channel (index 7) | 7 |
| Stereo 7+8 | 1030 (6 + 1024) |
| ReaRoute mono ch 1 | 512 |
| ReaRoute stereo 1+2 | 1536 |
| Multichannel from ch 1 | 2048 |
| All MIDI inputs, all channels | 6112 |
| All MIDI inputs, channel 10 | 6122 (4096 + 10 + 2016) |
| First MIDI device, channel 10 | 4106 (4096 + 10 + 0) |
| Virtual keyboard, all channels | 6080 |
| Virtual keyboard, channel 1 | 6081 |

---

## Helper function specifications

### encodeAudioInput(channelIndex, stereo, multichannel, isReaRoute)

```javascript
function encodeAudioInput(channelIndex, stereo = false, multichannel = false, isReaRoute = false) {
    let value = channelIndex;
    if (isReaRoute) value += 512;
    if (multichannel) value += 2048;
    else if (stereo) value += 1024;
    return value;
}
```

### encodeMidiInput(deviceIndex, channel)

```javascript
function encodeMidiInput(deviceIndex, channel = 0) {
    // deviceIndex: 0-61 hardware, 62 = VKB, 63 = all inputs
    // channel: 0 = all channels, 1-16 = specific channel
    return 4096 + channel + (deviceIndex << 5);
}

// Constants for clarity
const MIDI_DEVICE_VKB = 62;
const MIDI_DEVICE_ALL = 63;
```

### decodeRecInput(value)

```javascript
function decodeRecInput(value) {
    if (value < 0) {
        return { type: 'none' };
    }
    
    if (value & 4096) {
        // MIDI input
        return {
            type: 'midi',
            channel: value & 0x1F,           // bits 0-4 (0=all, 1-16=specific)
            deviceIndex: (value >> 5) & 0x3F, // bits 5-10 (62=VKB, 63=all)
            isVKB: ((value >> 5) & 0x3F) === 62,
            isAllDevices: ((value >> 5) & 0x3F) === 63
        };
    }
    
    // Audio input
    const channelIndex = value & 0x3FF; // bits 0-9
    return {
        type: 'audio',
        channelIndex: channelIndex,
        isReaRoute: channelIndex >= 512,
        isStereo: !!(value & 1024),
        isMultichannel: !!(value & 2048),
        actualChannelIndex: channelIndex >= 512 ? channelIndex - 512 : channelIndex
    };
}
```

---

## Input enumeration guidance

**Audio inputs**: Use `GetNumAudioInputs()` for count (note: this function exists but is underdocumented). Use `GetInputChannelName(index)` to get display names. Index maps directly to I_RECINPUT mono values.

**MIDI inputs**:

```javascript
// Enumerate hardware MIDI inputs
for (let i = 0; i < GetMaxMidiInputs(); i++) {
    const [exists, name] = GetMIDIInputName(i, "");
    if (exists) {
        // Device i is available
        // To encode: 4096 + channel + (i << 5)
    }
}

// Always add these special options manually:
// - "All MIDI Inputs" = device index 63
// - "Virtual MIDI Keyboard" = device index 62
```

**GetNumMIDIInputs vs GetMaxMidiInputs**: These are identical (alias). Both return the maximum device index value to iterate through. Some indices may be unpopulated—always check `GetMIDIInputName` return value.

---

## Critical implementation notes

1. **Bit 2048 vs 1024**: These are mutually exclusive. If both are set, 2048 takes precedence (multichannel mode).

2. **Channel validation**: MIDI channels 1-16 encode as 1-16, not 0-15. Value 0 means "all channels."

3. **ReaRoute detection**: For decoding, channel indices ≥512 indicate ReaRoute. Subtract 512 to get the actual ReaRoute channel number.

4. **Documentation discrepancy**: The reaper.fm website shows outdated 5-bit MIDI encoding (31=all, 30=VKB). The SDK header is authoritative—use **6 bits** (63=all, 62=VKB).

5. **Cross-platform**: ReaRoute is Windows-only (virtual ASIO). On macOS/Linux, indices 512+ may represent other loopback mechanisms or be unused.

This encoding has been stable since approximately REAPER v5.91 when documentation was corrected. The 6-bit MIDI device encoding (supporting 62 hardware devices) has been verified in REAPER v7.x and is consistent across all SDK sources.
