# Reamo WebSocket API Reference

WebSocket extension for REAPER control surfaces. Connect to `ws://localhost:9224` (ports 9224-9233 tried on startup).

## Table of Contents

**Protocol**
- [Protocol Overview](#protocol-overview) — Connection flow, message format, hello handshake
- [Clock Sync](#clock-sync) — NTP-style clock synchronization for beat display

**Commands**
- [Transport](#transport-commands) — play, stop, pause, record, seek
- [Time Selection](#time-selection-commands) — set, setByBars, goStart, goEnd, clear
- [Repeat](#repeat-commands) — set, toggle
- [Marker](#marker-commands) — add, update, delete, goto, prev, next
- [Region](#region-commands) — add, update, delete, goto
- [Item](#item-commands) — setActiveTake, move, setColor, delete, getPeaks, getNotes, getTakes
- [Take](#take-commands) — deleteCurrent, cropToActive
- [Track](#track-commands) — setVolume, setPan, setMute, setSolo, setRecArm, setRecMon, rename, create, duplicate, delete, getFx, getSends
- [Master](#master-commands) — toggleMono
- [Tempo](#tempo-commands) — set, tap
- [Time Signature](#time-signature-commands) — set
- [Metronome](#metronome-commands) — toggle, getVolume, setVolume
- [ExtState](#extstate-commands) — get, set, projGet, projSet
- [Project Notes](#project-notes-commands) — subscribe, unsubscribe, get, set
- [Undo](#undo-commands) — add, begin, end, do, redo
- [Gesture](#gesture-commands) — start, end
- [Action](#action-commands) — getToggleState, execute, executeByName
- [MIDI](#midi-commands) — cc, pc
- [FX](#fx-commands) — presetNext, presetPrev, presetSet
- [Send](#send-commands) — setVolume, setMute
- [Playlist](#playlist-commands) — create, delete, rename, addEntry, removeEntry, play, stop, next, prev
- [Preferences](#preferences-commands) — getSeekSettings, setSeekSettings
- [Debug](#debug-commands) — memoryStats

**Events**
- [Events (Broadcast)](#events-broadcast) — transport, tracks, markers, regions, items, project

**Reference**
- [Limits](#limits)
- [Error Responses](#error-responses)
- [Implementation Notes](#implementation-notes)

---

## Protocol Overview

### Connection Flow

1. Connect to WebSocket endpoint
2. Send `hello` message with protocol version and optional auth token
3. Receive `hello` response confirming connection
4. Send commands, receive responses and events

### Message Format

All messages are JSON. Three types:

**Commands** (client → server):

```json
{
  "type": "command",
  "command": "transport/play",
  "id": "optional-correlation-id",
  ...parameters
}
```

**Responses** (server → client):

```json
{
  "type": "response",
  "id": "correlation-id",
  "success": true,
  "payload": { ... }
}
```

**Events** (server → all clients, broadcast ~30ms):

```json
{
  "type": "event",
  "event": "transport",
  "payload": { ... }
}
```

### Hello Handshake

```json
{
  "type": "hello",
  "clientVersion": "1.0.0",
  "protocolVersion": 1,
  "token": "optional-session-token"
}
```

Response:

```json
{
  "type": "hello",
  "extensionVersion": "0.6.0",
  "protocolVersion": 1
}
```

If token authentication is enabled and the token is invalid, the connection is closed with code `4001`. Protocol version mismatch closes with code `4002`.

### Clock Sync

NTP-style clock synchronization for accurate beat display over WiFi. Achieves ±15ms visual accuracy.

**Request** (client → server):

```json
{
  "type": "clockSync",
  "t0": 1704067200000.123
}
```

**Response** (server → client):

```json
{
  "type": "clockSyncResponse",
  "t0": 1704067200000.123,
  "t1": 1704067200010.456,
  "t2": 1704067200010.789
}
```

| Field | Type | Description |
|-------|------|-------------|
| `t0` | float | Client send time (ms, echoed back) |
| `t1` | float | Server receive time (ms, high-precision) |
| `t2` | float | Server send time (ms, high-precision) |

The client calculates clock offset using NTP formula:
- RTT = (t3 - t0) - (t2 - t1)
- Offset = ((t1 - t0) + (t2 - t3)) / 2

**Note:** Clock sync messages bypass the command queue for minimal latency jitter.

---

## Transport Commands

### `transport/play`

Start playback.

```json
{"type": "command", "command": "transport/play"}
```

### `transport/stop`

Stop playback.

```json
{"type": "command", "command": "transport/stop"}
```

### `transport/pause`

Pause playback.

```json
{"type": "command", "command": "transport/pause"}
```

### `transport/record`

Start recording.

```json
{"type": "command", "command": "transport/record"}
```

### `transport/playPause`

Toggle play/pause. If playing, pauses. If stopped/paused, plays.

```json
{"type": "command", "command": "transport/playPause"}
```

### `transport/seek`

Move cursor to a position in seconds.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `position` | float | Yes | Position in seconds (≥0) |

```json
{"type": "command", "command": "transport/seek", "position": 30.5}
```

### `transport/seekBeats`

Move cursor to a bar/beat position.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `bar` | int | Yes | Bar number (1-based) |
| `beat` | float | No | Beat within bar (default: 1.0) |

```json
{"type": "command", "command": "transport/seekBeats", "bar": 5, "beat": 2.5}
```

### `transport/goStart`

Move cursor to project start.

```json
{"type": "command", "command": "transport/goStart"}
```

### `transport/goEnd`

Move cursor to project end.

```json
{"type": "command", "command": "transport/goEnd"}
```

### `transport/stopAndDelete`

Stop recording and **DELETE all recorded media**. Use with caution.

```json
{"type": "command", "command": "transport/stopAndDelete"}
```

---

## Time Selection Commands

### `timeSelection/set`

Set time selection by seconds.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `start` | float | Yes | Start position in seconds |
| `end` | float | Yes | End position in seconds |

```json
{"type": "command", "command": "timeSelection/set", "start": 10.0, "end": 20.0}
```

### `timeSelection/setByBars`

Set time selection by bar numbers. Great for touch interfaces.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `startBar` | int | Yes | Start bar (1-based) |
| `endBar` | int | Yes | End bar (1-based) |
| `startBeat` | float | No | Beat within start bar (default: 1.0) |
| `endBeat` | float | No | Beat within end bar (default: 1.0) |

```json
{"type": "command", "command": "timeSelection/setByBars", "startBar": 1, "endBar": 9}
```

### `timeSelection/setStartAtCursor`

Set time selection start at current cursor position.

```json
{"type": "command", "command": "timeSelection/setStartAtCursor"}
```

### `timeSelection/setEndAtCursor`

Set time selection end at current cursor position.

```json
{"type": "command", "command": "timeSelection/setEndAtCursor"}
```

### `timeSelection/goStart`

Move cursor to start of time selection.

```json
{"type": "command", "command": "timeSelection/goStart"}
```

### `timeSelection/goEnd`

Move cursor to end of time selection.

```json
{"type": "command", "command": "timeSelection/goEnd"}
```

### `timeSelection/clear`

Remove time selection.

```json
{"type": "command", "command": "timeSelection/clear"}
```

---

## Repeat Commands

### `repeat/set`

Set repeat mode explicitly.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `enabled` | int | Yes | 0 = off, 1 = on |

```json
{"type": "command", "command": "repeat/set", "enabled": 1}
```

### `repeat/toggle`

Toggle repeat mode.

```json
{"type": "command", "command": "repeat/toggle"}
```

---

## Marker Commands

### `marker/add`

Create a new marker.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `position` | float | Yes | Position in seconds |
| `name` | string | No | Marker name (max 128 chars) |
| `color` | int | No | Native OS color value |

```json
{"type": "command", "command": "marker/add", "position": 30.0, "name": "Verse 1"}
```

### `marker/update`

Update an existing marker. Uses PATCH semantics - omitted fields preserve current values.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | int | Yes | Marker ID |
| `position` | float | No | New position in seconds (preserves current if omitted) |
| `name` | string | No | New name (preserves current if omitted or empty) |
| `color` | int | No | New color: omit to preserve, `0` to reset to default red |

**Color behavior:**
- Omitted → preserve current color
- `0` → reset to REAPER's default marker color (red)
- Non-zero → set to that color value

```json
{"type": "command", "command": "marker/update", "id": 1, "name": "Chorus"}
{"type": "command", "command": "marker/update", "id": 1, "color": 0}
```

### `marker/delete`

Delete a marker.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | int | Yes | Marker ID |

```json
{"type": "command", "command": "marker/delete", "id": 1}
```

### `marker/goto`

Move cursor to a marker's position.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | int | Yes | Marker ID |

```json
{"type": "command", "command": "marker/goto", "id": 1}
```

### `marker/prev`

Move cursor to previous marker/region boundary.

```json
{"type": "command", "command": "marker/prev"}
```

### `marker/next`

Move cursor to next marker/region boundary.

```json
{"type": "command", "command": "marker/next"}
```

---

## Region Commands

### `region/add`

Create a new region.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `start` | float | Yes | Start position in seconds |
| `end` | float | Yes | End position in seconds |
| `name` | string | No | Region name (max 128 chars) |
| `color` | int | No | Native OS color value |

```json
{"type": "command", "command": "region/add", "start": 0.0, "end": 30.0, "name": "Intro"}
```

### `region/update`

Update an existing region.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | int | Yes | Region ID |
| `start` | float | No | New start position |
| `end` | float | No | New end position |
| `name` | string | No | New name |
| `color` | int | No | New color |

```json
{"type": "command", "command": "region/update", "id": 1, "name": "Verse"}
```

### `region/delete`

Delete a region.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | int | Yes | Region ID |

```json
{"type": "command", "command": "region/delete", "id": 1}
```

### `region/goto`

Move cursor to a region's start position.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | int | Yes | Region ID |

```json
{"type": "command", "command": "region/goto", "id": 1}
```

---

## Item Commands

Items are identified by track index + item index within that track.

### `item/setActiveTake`

Set the active take for an item.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0-based) |
| `itemIdx` | int | Yes | Item index within track (0-based) |
| `takeIdx` | int | Yes | Take index to activate (0-based) |

```json
{"type": "command", "command": "item/setActiveTake", "trackIdx": 0, "itemIdx": 0, "takeIdx": 1}
```

### `item/move`

Move an item to a new position.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `itemIdx` | int | Yes | Item index |
| `position` | float | Yes | New position in seconds |

```json
{"type": "command", "command": "item/move", "trackIdx": 0, "itemIdx": 0, "position": 15.0}
```

### `item/setColor`

Set an item's color.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `itemIdx` | int | Yes | Item index |
| `color` | int | Yes | Native OS color value |

```json
{"type": "command", "command": "item/setColor", "trackIdx": 0, "itemIdx": 0, "color": 16711680}
```

### `item/setLock`

Lock or unlock an item. Toggles if no explicit value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `itemIdx` | int | Yes | Item index |
| `locked` | int | No | 0=unlock, 1=lock (toggles if omitted) |

```json
{"type": "command", "command": "item/setLock", "trackIdx": 0, "itemIdx": 0, "locked": 1}
```

### `item/setNotes`

Set an item's notes.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `itemIdx` | int | Yes | Item index |
| `notes` | string | Yes | Notes text (max 1024 chars) |

```json
{"type": "command", "command": "item/setNotes", "trackIdx": 0, "itemIdx": 0, "notes": "Verse vocals"}
```

### `item/delete`

Delete an item.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `itemIdx` | int | Yes | Item index |

```json
{"type": "command", "command": "item/delete", "trackIdx": 0, "itemIdx": 0}
```

### `item/goto`

Move cursor to an item's position.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `itemIdx` | int | Yes | Item index |

```json
{"type": "command", "command": "item/goto", "trackIdx": 0, "itemIdx": 0}
```

### `item/select`

Select a single item (deselects all others first).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `itemIdx` | int | Yes | Item index |

```json
{"type": "command", "command": "item/select", "trackIdx": 0, "itemIdx": 0}
```

### `item/selectInTimeSel`

Select all items within the current time selection (on selected tracks).

```json
{"type": "command", "command": "item/selectInTimeSel"}
```

### `item/unselectAll`

Deselect all items.

```json
{"type": "command", "command": "item/unselectAll"}
```

### `item/getPeaks`

Get waveform peak data for an item's active take. Use for waveform visualization.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (unified: 0 = master, 1+ = user tracks) |
| `itemIdx` | int | Yes | Item index within track (0-based) |
| `width` | int | No | Number of peaks to return (default: 400, max: 2000) |

```json
{"type": "command", "command": "item/getPeaks", "trackIdx": 1, "itemIdx": 0, "width": 800, "id": "1"}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "itemGUID": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
    "takeGUID": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
    "length": 5.0,
    "startOffset": 0.0,
    "playrate": 1.0,
    "channels": 2,
    "peaks": [
      {"l": [-0.5, 0.6], "r": [-0.4, 0.5]},
      {"l": [-0.7, 0.8], "r": [-0.6, 0.7]}
    ]
  }
}
```

**Peak format:**
- Stereo: `{"l": [min, max], "r": [min, max]}`
- Mono: `[min, max]`
- Values normalized to -1.0 to 1.0

**Errors:**
- `NOT_FOUND` - Item not found at trackIdx/itemIdx
- `NO_TAKE` - Item has no active take
- `MIDI_ITEM` - Item contains MIDI, not audio
- `EMPTY_ITEM` - Item has zero length
- `INVALID_WIDTH` - Width out of range (1-2000)
- `ACCESSOR_ERROR` - Failed to create audio accessor
- `SERIALIZE_ERROR` - Failed to serialize peaks

**Cache key:** Frontend should cache using `{itemGUID, takeGUID, length, startOffset, playrate}`. Re-fetch when any of these change in the `items` event.

### `item/getNotes`

Get notes content for a single item. Use for on-demand fetching when displaying item notes.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0-based) |
| `itemIdx` | int | Yes | Item index within track (0-based) |

```json
{"type": "command", "command": "item/getNotes", "trackIdx": 1, "itemIdx": 0, "id": "1"}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {"notes": "Verse 1 vocals - take 3 selected"}
}
```

### `item/getTakes`

Get full take list for a single item. Use for on-demand fetching when displaying take details.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0-based) |
| `itemIdx` | int | Yes | Item index within track (0-based) |

```json
{"type": "command", "command": "item/getTakes", "trackIdx": 1, "itemIdx": 0, "id": "1"}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "takes": [
      {"takeIdx": 0, "guid": "{XXXX...}", "name": "Take 1", "isActive": false, "isMidi": false, "startOffset": 0.0, "playrate": 1.0},
      {"takeIdx": 1, "guid": "{YYYY...}", "name": "Take 2", "isActive": true, "isMidi": false, "startOffset": 0.0, "playrate": 1.0}
    ]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `takeIdx` | int | Take index (0-based) |
| `guid` | string | Take GUID |
| `name` | string | Take name (usually source filename) |
| `isActive` | bool | Whether this is the currently active take |
| `isMidi` | bool | Whether this take contains MIDI data |
| `startOffset` | float | Start offset in seconds |
| `playrate` | float | Playback rate (1.0 = normal) |

---

## Take Commands

These operate on currently **selected items**.

### `take/next`

Activate the next take in selected items.

```json
{"type": "command", "command": "take/next"}
```

### `take/prev`

Activate the previous take in selected items.

```json
{"type": "command", "command": "take/prev"}
```

### `take/delete`

Delete the active take from selected items.

```json
{"type": "command", "command": "take/delete"}
```

### `take/cropToActive`

Delete all takes except the active one from selected items.

```json
{"type": "command", "command": "take/cropToActive"}
```

---

## Track Commands

Tracks are identified by index (0-based).

### `track/setVolume`

Set track volume. Uses CSurf API for automatic undo coalescing - wrap with `gesture/start` and `gesture/end` for proper undo behavior during fader drags.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `volume` | float | Yes | Volume (0.0 to ∞, 1.0 = 0dB) |

```json
{"type": "command", "command": "track/setVolume", "trackIdx": 0, "volume": 0.5}
```

### `track/setPan`

Set track pan. Uses CSurf API for automatic undo coalescing - wrap with `gesture/start` and `gesture/end` for proper undo behavior during knob drags.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `pan` | float | Yes | Pan (-1.0 to 1.0, 0 = center) |

```json
{"type": "command", "command": "track/setPan", "trackIdx": 0, "pan": -0.5}
```

### `track/setMute`

Mute or unmute a track. Toggles if no explicit value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `mute` | int | No | 0=unmute, 1=mute (toggles if omitted) |

```json
{"type": "command", "command": "track/setMute", "trackIdx": 0, "mute": 1}
```

### `track/setSolo`

Set track solo. Toggles between 0 and 1 if no explicit value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `solo` | int | No | 0=off, 1=solo, 2=solo in place, etc. |

```json
{"type": "command", "command": "track/setSolo", "trackIdx": 0, "solo": 1}
```

### `track/setRecArm`

Arm or disarm track for recording. Toggles if no explicit value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `arm` | int | No | 0=disarm, 1=arm (toggles if omitted) |

```json
{"type": "command", "command": "track/setRecArm", "trackIdx": 0, "arm": 1}
```

### `track/setRecMon`

Set input monitoring mode. Cycles 0→1→2 if no explicit value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `mon` | int | No | 0=off, 1=normal, 2=not when playing |

```json
{"type": "command", "command": "track/setRecMon", "trackIdx": 0, "mon": 1}
```

### `track/setFxEnabled`

Enable or disable track FX. Toggles if no explicit value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |
| `enabled` | int | No | 0=disabled, 1=enabled (toggles if omitted) |

```json
{"type": "command", "command": "track/setFxEnabled", "trackIdx": 0, "enabled": 0}
```

### `meter/clearClip`

Clear the clip indicator for a track's input meter.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index |

```json
{"type": "command", "command": "meter/clearClip", "trackIdx": 0}
```

### `track/rename`

Rename a track. Master track (idx 0) cannot be renamed.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (1+ for user tracks) |
| `name` | string | Yes | New track name |

```json
{"type": "command", "command": "track/rename", "trackIdx": 1, "name": "Guitar Clean"}
```

### `track/create`

Create a new track. Returns the new track's index.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | No | Initial track name (empty = "Track N") |
| `afterTrackIdx` | int | No | Insert after this track index (omit = append at end) |

```json
{"type": "command", "command": "track/create", "name": "New Guitar", "afterTrackIdx": 2, "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"trackIdx": 3}}
```

### `track/duplicate`

Duplicate a track including FX chain, items, and routing. Master track (idx 0) cannot be duplicated. Returns the duplicated track's index.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index to duplicate (1+ for user tracks) |

```json
{"type": "command", "command": "track/duplicate", "trackIdx": 1, "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"trackIdx": 2}}
```

**Note:** Creates a single undo point "Duplicate track N".

### `track/delete`

Delete a track. Master track (idx 0) cannot be deleted.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index to delete (1+ for user tracks) |

```json
{"type": "command", "command": "track/delete", "trackIdx": 3}
```

**Note:** Deleting a folder track does not delete its children — they become orphaned/promoted to parent level.

### `track/duplicateSelected`

Duplicate all currently selected tracks. Uses REAPER's native action which handles full duplication including FX, items, envelopes, and routing.

```json
{"type": "command", "command": "track/duplicateSelected"}
```

**Note:** Duplicated tracks appear immediately after their source tracks.

### `track/deleteSelected`

Delete all currently selected tracks. Uses REAPER's native action with proper undo support.

```json
{"type": "command", "command": "track/deleteSelected"}
```

**Note:** Master track cannot be deleted even if selected.

### `track/getFx`

Get full FX detail for a single track. Use for on-demand fetching when displaying FX chain details.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |

```json
{"type": "command", "command": "track/getFx", "trackIdx": 1, "id": "1"}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "fx": [
      {"fxIndex": 0, "name": "VST: Pro-Q 3 (FabFilter)", "presetName": "Vocal Cut", "presetIndex": 5, "presetCount": 120, "modified": false, "enabled": true},
      {"fxIndex": 1, "name": "VST: LA-2A (Universal Audio)", "presetName": "", "presetIndex": -1, "presetCount": 50, "modified": true, "enabled": true}
    ]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `fxIndex` | int | FX index in chain (0-based) |
| `name` | string | FX plugin name |
| `presetName` | string | Currently loaded preset name (empty if none) |
| `presetIndex` | int | Current preset index (-1 if no preset loaded) |
| `presetCount` | int | Total number of presets available |
| `modified` | bool | Whether preset has been modified from saved state |
| `enabled` | bool | Whether FX is enabled (bypassed if false) |

### `track/getSends`

Get full send detail for a single track. Use for on-demand fetching when displaying routing details.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |

```json
{"type": "command", "command": "track/getSends", "trackIdx": 1, "id": "1"}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "sends": [
      {"sendIndex": 0, "destName": "Reverb Bus", "volume": 0.5, "muted": false, "mode": 0},
      {"sendIndex": 1, "destName": "Delay Bus", "volume": 0.25, "muted": true, "mode": 0}
    ]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `sendIndex` | int | Send index (0-based) |
| `destName` | string | Destination track name |
| `volume` | float | Send volume (0.0 to ∞, 1.0 = 0dB) |
| `muted` | bool | Whether send is muted |
| `mode` | int | Send mode (0=post-fader, 1=pre-fx, 3=pre-fader) |

---

## Master Commands

### `master/toggleMono`

Toggle master track between mono (L+R summed) and stereo output.

```json
{"type": "command", "command": "master/toggleMono", "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"stereoEnabled": true}}
```

| Field | Type | Description |
|-------|------|-------------|
| `stereoEnabled` | bool | `true` = stereo, `false` = mono (L+R summed) |

---

## Tempo Commands

### `tempo/set`

Set project tempo.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `bpm` | float | Yes | Tempo in BPM (2-960) |

```json
{"type": "command", "command": "tempo/set", "bpm": 128.0}
```

### `tempo/tap`

Tap tempo. Call repeatedly to set tempo from tap intervals.

```json
{"type": "command", "command": "tempo/tap"}
```

---

## Time Signature Commands

### `timesig/set`

Set project time signature. Uses REAPER's project settings (no tempo marker created).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `numerator` | int | Yes | Beats per measure (1-32) |
| `denominator` | int | Yes | Beat note value (2, 4, 8, or 16) |

```json
{"type": "command", "command": "timesig/set", "numerator": 6, "denominator": 8}
```

---

## Metronome Commands

### `metronome/toggle`

Toggle metronome on/off.

```json
{"type": "command", "command": "metronome/toggle"}
```

### `metronome/getVolume`

Get current metronome volume. **Returns data.**

```json
{"type": "command", "command": "metronome/getVolume", "id": "1"}
```

Response:

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {"volume": 0.5, "volumeDb": -6.02}
}
```

### `metronome/setVolume`

Set metronome volume. Accepts dB or linear.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `volumeDb` | float | No* | Volume in dB (preferred) |
| `volume` | float | No* | Volume linear (0.0-4.0, 1.0 = 0dB) |

*One of `volumeDb` or `volume` is required.

```json
{"type": "command", "command": "metronome/setVolume", "volumeDb": -6.0}
```

---

## ExtState Commands

Persistent key-value storage.

### `extstate/get`

Get a global extended state value. **Returns data.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `section` | string | Yes | Section name (max 64 chars) |
| `key` | string | Yes | Key name (max 64 chars) |

```json
{"type": "command", "command": "extstate/get", "section": "MyApp", "key": "setting1", "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"value": "stored_value"}}
```

Returns `{"value": null}` if key doesn't exist.

### `extstate/set`

Set a global extended state value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `section` | string | Yes | Section name |
| `key` | string | Yes | Key name |
| `value` | string | Yes | Value to store (max 1024 chars) |
| `persist` | int | No | 1 = persist to reaper-extstate.ini |

```json
{"type": "command", "command": "extstate/set", "section": "MyApp", "key": "setting1", "value": "hello", "persist": 1}
```

### `extstate/projGet`

Get a project-specific extended state value. **Returns data.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `extname` | string | Yes | Extension name (max 64 chars) |
| `key` | string | Yes | Key name (max 64 chars) |

```json
{"type": "command", "command": "extstate/projGet", "extname": "MyApp", "key": "projectSetting", "id": "1"}
```

### `extstate/projSet`

Set a project-specific extended state value.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `extname` | string | Yes | Extension name |
| `key` | string | Yes | Key name |
| `value` | string | Yes | Value to store (max 16384 chars) |

```json
{"type": "command", "command": "extstate/projSet", "extname": "MyApp", "key": "projectSetting", "value": "data"}
```

---

## Project Notes Commands

Read and write REAPER project notes (session metadata). Notes are stored in the project file and are separate from REAPER's undo system.

### `projectNotes/subscribe`

Subscribe to project notes updates. Returns current notes and starts receiving `projectNotesChanged` events when notes are modified externally (e.g., in REAPER's Project Notes window). **Returns data.**

```json
{"type": "command", "command": "projectNotes/subscribe", "id": "1"}
```

Response:

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "notes": "Session notes content here...",
    "hash": "7c81ba9ee693c1de"
  }
}
```

The `hash` is a hex-encoded 64-bit hash of the notes content, used for change detection.

### `projectNotes/unsubscribe`

Unsubscribe from project notes updates.

```json
{"type": "command", "command": "projectNotes/unsubscribe"}
```

### `projectNotes/get`

Get current project notes without subscribing. **Returns data.**

```json
{"type": "command", "command": "projectNotes/get", "id": "1"}
```

Response: Same as subscribe.

### `projectNotes/set`

Set project notes. Returns the saved notes and new hash. **Returns data.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `notes` | string | Yes | Notes content (max 64KB) |

```json
{"type": "command", "command": "projectNotes/set", "notes": "Updated notes content", "id": "1"}
```

Response:

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "notes": "Updated notes content",
    "hash": "cf9ffd3db2b5bfee"
  }
}
```

**Note:** Setting notes marks the project as dirty (unsaved). Notes are outside REAPER's undo system.

### `projectNotesChanged` Event

Broadcast to subscribed clients when notes are modified externally (polled at ~1Hz).

```json
{
  "type": "event",
  "event": "projectNotesChanged",
  "payload": {
    "hash": "newHashValue"
  }
}
```

Clients should compare the hash to their last known hash to detect changes.

---

## Undo Commands

### `undo/add`

Add a simple undo point.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `description` | string | Yes | Undo point description (max 255 chars) |

```json
{"type": "command", "command": "undo/add", "description": "Changed marker"}
```

### `undo/begin`

Begin an undo block. Use to group multiple operations into one undo step.

```json
{"type": "command", "command": "undo/begin"}
```

### `undo/end`

End an undo block.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `description` | string | Yes | Description for the grouped operations |

```json
{"type": "command", "command": "undo/end", "description": "Batch edit"}
```

### `undo/do`

Execute undo (revert last action). **Returns data.**

```json
{"type": "command", "command": "undo/do", "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"action": "Changed marker"}}
```

Returns the description of what was undone. If nothing to undo, returns `{"action": null}`.

### `redo/do`

Execute redo (re-apply last undone action). **Returns data.**

```json
{"type": "command", "command": "redo/do", "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"action": "Changed marker"}}
```

Returns the description of what was redone. If nothing to redo, returns `{"action": null}`.

---

## Gesture Commands

Gestures enable undo coalescing for continuous controls (faders, knobs). When a user drags a fader, multiple rapid value changes should result in a single undo point rather than one per change.

**How it works:**

1. Client sends `gesture/start` when user begins dragging
2. Client sends value changes (`track/setVolume`, `track/setPan`, `send/setVolume`)
3. Client sends `gesture/end` when user releases
4. Server creates a single undo point for the entire gesture

**Safety nets:**

- If client disconnects during gesture, server flushes undo automatically
- If `gesture/end` is missed, a 500ms timeout flushes the gesture
- Multiple clients can gesture the same control (reference counted)

### `gesture/start`

Begin a gesture on a continuous control.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `controlType` | string | Yes | `"volume"`, `"pan"`, or `"send"` |
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `sendIdx` | int | For send | Send index (required when `controlType` is `"send"`) |

```json
{"type": "command", "command": "gesture/start", "controlType": "volume", "trackIdx": 1}
{"type": "command", "command": "gesture/start", "controlType": "send", "trackIdx": 1, "sendIdx": 0}
```

### `gesture/end`

End a gesture on a continuous control. Triggers undo point creation.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `controlType` | string | Yes | `"volume"`, `"pan"`, or `"send"` |
| `trackIdx` | int | Yes | Track index |
| `sendIdx` | int | For send | Send index (required when `controlType` is `"send"`) |

```json
{"type": "command", "command": "gesture/end", "controlType": "volume", "trackIdx": 1}
{"type": "command", "command": "gesture/end", "controlType": "send", "trackIdx": 1, "sendIdx": 0}
```

---

## Action Commands

Execute any REAPER action by command ID.

### `action/getToggleState`

Get the toggle state of an action. **Returns data.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `commandId` | int | Yes | REAPER command ID |

```json
{"type": "command", "command": "action/getToggleState", "commandId": 40364, "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"state": 1}}
```

State values: `1` = on, `0` = off, `-1` = not a toggle action.

### `action/execute`

Execute a REAPER action by command ID.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `commandId` | int | Yes | REAPER command ID |

```json
{"type": "command", "command": "action/execute", "commandId": 40364}
```

### `action/executeByName`

Execute a REAPER action by named command identifier. Useful for SWS, ReaPack, or custom script actions.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | Yes | Named command identifier (e.g., `"_SWS_ABOUT"`) |

```json
{"type": "command", "command": "action/executeByName", "name": "_SWS_ABOUT"}
```

Returns `NOT_FOUND` error if the named command doesn't exist.

---

## MIDI Commands

Inject MIDI messages into REAPER. Messages are dual-sent to both VKB (Virtual MIDI Keyboard) and Control paths, so the same button works for both MIDI Learn and parameter control.

### `midi/cc`

Send MIDI Control Change message.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `cc` | int | Yes | - | CC number (0-127) |
| `value` | int | Yes | - | CC value (0-127) |
| `channel` | int | No | 0 | MIDI channel (0-15) |

```json
{"type": "command", "command": "midi/cc", "cc": 20, "value": 127, "channel": 9}
```

### `midi/pc`

Send MIDI Program Change message.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `program` | int | Yes | - | Program number (0-127) |
| `channel` | int | No | 0 | MIDI channel (0-15) |

```json
{"type": "command", "command": "midi/pc", "program": 5, "channel": 0}
```

---

## FX Commands

Control track FX presets. FX state is included in the `tracks` event — see [tracks event](#tracks-event) for the `fx[]` array format.

### `fx/presetNext`

Navigate to the next preset for a track FX.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `fxIdx` | int | Yes | FX index within track (0-based) |

```json
{"type": "command", "command": "fx/presetNext", "trackIdx": 1, "fxIdx": 0}
```

### `fx/presetPrev`

Navigate to the previous preset for a track FX.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `fxIdx` | int | Yes | FX index within track (0-based) |

```json
{"type": "command", "command": "fx/presetPrev", "trackIdx": 1, "fxIdx": 0}
```

### `fx/presetSet`

Jump to a specific preset by index.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `fxIdx` | int | Yes | FX index within track (0-based) |
| `presetIdx` | int | Yes | Preset index (-1 = default user, -2 = factory, 0+ = preset index) |

```json
{"type": "command", "command": "fx/presetSet", "trackIdx": 1, "fxIdx": 0, "presetIdx": 5}
```

**Note:** Each preset change creates a REAPER undo point. Consider debouncing rapid clicks in the frontend.

---

## Send Commands

Control track send levels and mute states. Send state is included in the `tracks` event — see [tracks event](#tracks-event) for the `sends[]` array format.

### `send/setVolume`

Set the volume level for a track send. Uses CSurf API for automatic undo coalescing - wrap with `gesture/start` and `gesture/end` (controlType `"send"`) for proper undo behavior during fader drags.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `sendIdx` | int | Yes | Send index within track (0-based) |
| `volume` | float | Yes | Volume level (linear, 1.0 = 0dB) |

```json
{"type": "command", "command": "send/setVolume", "trackIdx": 1, "sendIdx": 0, "volume": 0.5}
```

### `send/setMute`

Set the mute state for a track send.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |
| `sendIdx` | int | Yes | Send index within track (0-based) |
| `muted` | int | Yes | Mute state (0 = unmuted, 1 = muted) |

```json
{"type": "command", "command": "send/setMute", "trackIdx": 1, "sendIdx": 0, "muted": 1}
```

---

## Playlist Commands

Playlist (cue list) management for setlist/arrangement playback. Playlists contain ordered entries referencing regions with loop counts. The playlist engine monitors playback position and auto-advances at region boundaries using REAPER's native loop points for seamless looping.

**Data persistence:** Playlists are stored in project EXTSTATE and persist with the project file.

### `playlist/create`

Create a new playlist. **Returns data.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | Yes | Playlist name (max 128 chars) |

```json
{"type": "command", "command": "playlist/create", "name": "Friday Gig", "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"playlistIdx": 0}}
```

### `playlist/delete`

Delete a playlist. Stops playback if the deleted playlist is active.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index (0-based) |

```json
{"type": "command", "command": "playlist/delete", "playlistIdx": 0}
```

### `playlist/rename`

Rename a playlist.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |
| `name` | string | Yes | New name (max 128 chars) |

```json
{"type": "command", "command": "playlist/rename", "playlistIdx": 0, "name": "Saturday Gig"}
```

### `playlist/addEntry`

Add a region to a playlist. **Returns data.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |
| `regionId` | int | Yes | Region ID (from `regions` event) |
| `loopCount` | int | Yes | Loop count: -1=infinite, 0=skip, 1+=times to play |
| `atIdx` | int | No | Insert position (default: end of playlist) |

```json
{"type": "command", "command": "playlist/addEntry", "playlistIdx": 0, "regionId": 1, "loopCount": 4, "id": "1"}
```

Response:

```json
{"type": "response", "id": "1", "success": true, "payload": {"entryIdx": 0}}
```

### `playlist/removeEntry`

Remove an entry from a playlist.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |
| `entryIdx` | int | Yes | Entry index within playlist (0-based) |

```json
{"type": "command", "command": "playlist/removeEntry", "playlistIdx": 0, "entryIdx": 2}
```

### `playlist/setLoopCount`

Change an entry's loop count.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |
| `entryIdx` | int | Yes | Entry index |
| `loopCount` | int | Yes | New loop count (-1=infinite, 0=skip, 1+=times) |

```json
{"type": "command", "command": "playlist/setLoopCount", "playlistIdx": 0, "entryIdx": 1, "loopCount": 2}
```

### `playlist/reorderEntry`

Move an entry to a new position within the playlist.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |
| `fromIdx` | int | Yes | Current entry index |
| `toIdx` | int | Yes | Target entry index |

```json
{"type": "command", "command": "playlist/reorderEntry", "playlistIdx": 0, "fromIdx": 0, "toIdx": 3}
```

### `playlist/play`

Start playlist playback from entry 0, or resume if paused.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |

```json
{"type": "command", "command": "playlist/play", "playlistIdx": 0}
```

### `playlist/playFromEntry`

Start playlist playback from a specific entry.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |
| `entryIdx` | int | Yes | Entry index to start from |

```json
{"type": "command", "command": "playlist/playFromEntry", "playlistIdx": 0, "entryIdx": 2}
```

### `playlist/pause`

Pause playlist playback. Remembers current position for resume.

```json
{"type": "command", "command": "playlist/pause"}
```

### `playlist/stop`

Stop playlist playback and exit playlist mode entirely.

```json
{"type": "command", "command": "playlist/stop"}
```

### `playlist/next`

Advance to the next entry immediately. No-op if playlist not active.

```json
{"type": "command", "command": "playlist/next"}
```

### `playlist/prev`

Go to the previous entry. No-op if playlist not active.

```json
{"type": "command", "command": "playlist/prev"}
```

### `playlist/advanceAfterLoop`

Set flag to advance to next entry after the current loop completes. Useful for exiting an infinite loop or cutting remaining loops short. Flag clears automatically after advance.

```json
{"type": "command", "command": "playlist/advanceAfterLoop"}
```

### `playlist/setStopAfterLast`

Set whether transport stops after the final region's last loop completes. Per-playlist setting, persisted with the playlist.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playlistIdx` | int | Yes | Playlist index |
| `stopAfterLast` | int | Yes | 1 = stop after last, 0 = continue looping |

```json
{"type": "command", "command": "playlist/setStopAfterLast", "playlistIdx": 0, "stopAfterLast": 1}
```

---

## Preferences Commands

Read and write REAPER preference/configuration values. Currently focused on seek settings for playlist engine integration.

### `preferences/getSeekSettings`

Get current seek-related settings. **Returns data.**

```json
{"type": "command", "command": "preferences/getSeekSettings", "id": "1"}
```

Response:

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {"enabled": true, "measures": 1, "mode": "measures"}
}
```

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Smooth seek enabled (queue seeks to measure boundaries) |
| `measures` | int | Number of measures to pre-buffer when smooth seeking |
| `mode` | string | `"measures"` = play to end of N measures; `"marker"` = play to next marker/region |

**Important:** The playlist engine requires `mode: "measures"` for correct non-contiguous region transitions. The `"marker"` mode causes premature seeks if markers exist inside regions.

### `preferences/setSeekSettings`

Set seek-related settings. All parameters are optional - only provided values are updated.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `enabled` | int | No | 0=disable, 1=enable smooth seek |
| `measures` | int | No | Pre-buffer measures (1-8) |
| `mode` | int | No | 0=measures, 1=marker |

```json
{"type": "command", "command": "preferences/setSeekSettings", "enabled": 1, "measures": 2, "mode": 0}
```

**Note:** These settings allow the UI to save/restore the user's original seek preferences when entering/exiting playlist mode, since the playlist engine may temporarily modify seek behavior for seamless looping.

---

## Debug Commands

Commands for monitoring extension internals and diagnostics.

### `debug/memoryStats`

Get memory usage statistics for all tiered arenas. Use for monitoring memory consumption and debugging allocation issues.

```json
{"type": "command", "command": "debug/memoryStats", "id": "1"}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "high": {"used": 51200, "capacity": 1048576, "peak": 102400, "utilization": 9.8},
    "medium": {"used": 4500000, "capacity": 18874368, "peak": 8000000, "utilization": 42.4},
    "low": {"used": 2048, "capacity": 131072, "peak": 4096, "utilization": 3.1},
    "scratch": {"used": 0, "capacity": 2097152},
    "total": {"allocated": 22151168, "allocatedMB": 21.13},
    "sizes": {"high": 1048576, "medium": 18874368, "low": 131072, "scratch": 2097152},
    "frameCount": 12345
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `high` | object | HIGH tier arena stats (30Hz polling - tracks, meters) |
| `medium` | object | MEDIUM tier arena stats (5Hz polling - items, markers, regions, FX, sends) |
| `low` | object | LOW tier arena stats (1Hz polling - tempo map) |
| `scratch` | object | Scratch arena stats (JSON serialization buffer) |
| `total` | object | Aggregate memory stats |
| `sizes` | object | Configured arena sizes in bytes |
| `frameCount` | int | Total frames processed since startup |

**Arena stats fields:**
- `used` - Bytes currently allocated in this frame
- `capacity` - Total arena capacity in bytes
- `peak` - High water mark (max bytes used in any frame)
- `utilization` - Peak usage as percentage of capacity

**Errors:**
- `NOT_INITIALIZED` - Tiered arenas not yet initialized

---

## Events (Broadcast)

Events are sent to all connected clients when state changes. Polling occurs ~30ms.

### `transport` Event

High-frequency event broadcast every ~30ms during playback, containing position-dependent data.

```json
{
  "type": "event",
  "event": "transport",
  "payload": {
    "playState": 1,
    "position": 30.500,
    "positionBeats": "8.3.25",
    "cursorPosition": 30.500,
    "bpm": 120.00,
    "timeSignature": {"numerator": 4, "denominator": 4},
    "timeSelection": {"start": 0.000, "end": 60.000},
    "t": 1704067200000.123,
    "b": 61.000
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `playState` | int | 0=stopped, 1=playing, 2=paused, 5=recording, 6=rec paused |
| `position` | float | Current position in seconds (play pos if playing, cursor if stopped) |
| `positionBeats` | string | Position as "bar.beat.ticks" (e.g., "12.3.45") |
| `cursorPosition` | float | Edit cursor position in seconds |
| `bpm` | float | Current tempo |
| `timeSignature` | object | Current time signature |
| `timeSelection` | object | Start/end of time selection (0,0 if none) |
| `t` | float | Server timestamp in ms (high-precision, for clock sync) |
| `b` | float | Raw beat position (total beats from project start, for beat prediction) |

**Note:** Project-level settings (`repeat`, `metronome`, `projectLength`, `barOffset`) are in the `project` event.

**Note:** The `t` and `b` fields are used for client-side beat prediction to achieve ±15ms visual accuracy over WiFi. See [Clock Sync](#clock-sync) for the synchronization protocol.

### `tt` Event (Transport Tick)

Lightweight transport tick event sent during playback when only position changes (~30Hz). Contains minimal data for efficient position updates without the overhead of full `transport` events.

```json
{
  "type": "event",
  "event": "tt",
  "payload": {
    "p": 45.500,
    "t": 1704067200000.123,
    "b": 91.000,
    "bpm": 120.00,
    "ts": [4, 4],
    "bbt": "23.1.00"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `p` | float | Position in seconds (critical for accurate display after seeks) |
| `t` | float | Server timestamp in ms (high-precision, for clock sync) |
| `b` | float | Raw beat position (total beats from project start) |
| `bpm` | float | Current tempo (for tempo-map-aware prediction) |
| `ts` | [int, int] | Time signature [numerator, denominator] |
| `bbt` | string | Pre-computed bar.beat.ticks (e.g., "23.1.00") |

**When sent:**
- During playback when only position has changed (no state/tempo/time-sig changes)
- Full `transport` events are sent on state changes (play/pause/stop) or tempo/time-sig changes

**Frontend usage:**
- `TransportSyncEngine` uses `tt` events for clock-synchronized beat display
- `TransportAnimationEngine` uses the `p` field to correct client-side interpolation after seeks

### `tracks` Event

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [
      {
        "idx": 0,
        "name": "Drums",
        "color": 16711680,
        "volume": 1.0000,
        "pan": 0.000,
        "mute": false,
        "solo": 0,
        "recArm": true,
        "recMon": 1,
        "fxEnabled": true,
        "selected": false,
        "folderDepth": 0,
        "fx": [
          {
            "name": "ReaEQ",
            "presetName": "My EQ",
            "presetIndex": 3,
            "presetCount": 12,
            "modified": false
          }
        ],
        "sends": [
          {
            "idx": 0,
            "destName": "Reverb Bus",
            "volume": 0.5,
            "muted": false,
            "mode": 0
          }
        ]
      }
    ],
    "meters": [
      {"trackIdx": 0, "peakL": 0.7500, "peakR": 0.6800, "clipped": false}
    ]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `tracks[].idx` | int | Track index (0=master, 1+=user tracks) |
| `tracks[].name` | string | Track name |
| `tracks[].color` | int | Track color (native OS format, 0=default) |
| `tracks[].volume` | float | Volume (1.0 = 0dB) |
| `tracks[].pan` | float | Pan (-1.0 to 1.0) |
| `tracks[].mute` | bool | Muted |
| `tracks[].solo` | int | Solo state (0=off, 1=solo, 2=solo in place) |
| `tracks[].recArm` | bool | Record armed |
| `tracks[].recMon` | int | Record monitoring (0=off, 1=on, 2=not when playing) |
| `tracks[].fxEnabled` | bool | FX chain enabled |
| `tracks[].selected` | bool | Track is selected |
| `tracks[].folderDepth` | int | Folder hierarchy: 1=folder parent, 0=normal, -N=closes N folder levels |
| `tracks[].fx` | array | FX chain (polled at 5Hz, empty if no FX) |
| `tracks[].fx[].name` | string | Plugin name |
| `tracks[].fx[].presetName` | string | Current preset name |
| `tracks[].fx[].presetIndex` | int | Current preset index (-1 if none) |
| `tracks[].fx[].presetCount` | int | Total number of presets |
| `tracks[].fx[].modified` | bool | `true` if params don't match preset |
| `tracks[].sends` | array | Sends (polled at 5Hz, empty if no sends) |
| `tracks[].sends[].idx` | int | Send index |
| `tracks[].sends[].destName` | string | Destination track name |
| `tracks[].sends[].volume` | float | Volume (linear, 1.0 = 0dB) |
| `tracks[].sends[].muted` | bool | Mute state |
| `tracks[].sends[].mode` | int | Send mode (0=post-fader, 1=pre-FX, 3=post-FX) |
| `meters[].trackIdx` | int | Track index |
| `meters[].peakL/R` | float | Peak level (0.0-1.0+, 1.0 = 0dB) |
| `meters[].clipped` | bool | Clip indicator (sticky until cleared) |

**Note:** Meters only included for tracks that are record-armed AND input-monitoring.

**Note:** FX and sends are polled at 5Hz (for efficiency) but included in the 30Hz track events. Max 64 FX per track, max 16 sends per track.

### `markers` Event

```json
{
  "type": "event",
  "event": "markers",
  "payload": {
    "markers": [
      {"id": 1, "position": 0.000, "name": "Start", "color": 0},
      {"id": 2, "position": 30.500, "name": "Verse", "color": 16711680}
    ]
  }
}
```

### `regions` Event

```json
{
  "type": "event",
  "event": "regions",
  "payload": {
    "regions": [
      {"id": 1, "start": 0.000, "end": 30.000, "name": "Intro", "color": 255}
    ]
  }
}
```

### `items` Event

Broadcasts all items in the project. Frontend filters by time selection as needed.

```json
{
  "type": "event",
  "event": "items",
  "payload": {
    "items": [
      {
        "guid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
        "trackIdx": 1,
        "itemIdx": 0,
        "position": 10.000,
        "length": 5.000,
        "color": 0,
        "locked": false,
        "selected": false,
        "activeTakeIdx": 0,
        "notes": "",
        "takes": [
          {
            "guid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
            "name": "Take 1",
            "isActive": true,
            "isMIDI": false
          },
          {
            "guid": "{YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY}",
            "name": "Take 2",
            "isActive": false,
            "isMIDI": false
          }
        ]
      }
    ]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `items[].guid` | string | Stable item identifier (REAPER GUID) |
| `items[].trackIdx` | int | Track index (unified: 0 = master, 1+ = user tracks) |
| `items[].itemIdx` | int | Item index within track (0-based) |
| `items[].takes[].guid` | string | Stable take identifier for cache keying |
| `items[].takes[].isMIDI` | bool | If true, skip peaks request (MIDI items have no audio waveform) |

### `project` Event

Low-frequency event broadcast when project state changes. Contains project identity, undo/redo availability, and project-level settings.

```json
{
  "type": "event",
  "event": "project",
  "payload": {
    "canUndo": "Changed marker",
    "canRedo": null,
    "projectName": "MySong.rpp",
    "projectPath": "/Users/musician/Projects/MySong.rpp",
    "stateChangeCount": 42,
    "repeat": false,
    "metronome": {"enabled": true, "volume": 0.5000, "volumeDb": -6.02},
    "master": {"stereoEnabled": true},
    "projectLength": 180.500,
    "barOffset": -4,
    "isDirty": false,
    "frameRate": 29.97,
    "dropFrame": true,
    "memoryWarning": false
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `canUndo` | string\|null | Description of next undo action, or null if nothing to undo |
| `canRedo` | string\|null | Description of next redo action, or null if nothing to redo |
| `projectName` | string\|null | Project filename (e.g., "MySong.rpp"), or null if unsaved |
| `projectPath` | string\|null | Full path to .rpp file, or null if unsaved |
| `stateChangeCount` | int | Project state change counter (for detecting changes) |
| `repeat` | bool | Repeat/loop mode enabled |
| `metronome` | object | Metronome state and volume |
| `master` | object | Master track settings |
| `master.stereoEnabled` | bool | `true` = stereo, `false` = mono (L+R summed) |
| `projectLength` | float | Project length in seconds (based on last item/region end) |
| `barOffset` | int | Bar offset (e.g., -4 means time 0 = bar 1, display starts at bar -4) |
| `isDirty` | bool | Project has unsaved changes |
| `frameRate` | float | Project frame rate for SMPTE timecode (e.g., 23.976, 24, 25, 29.97, 30) |
| `dropFrame` | bool | `true` if using drop-frame timecode (29.97fps or 59.94fps) |
| `memoryWarning` | bool | `true` when arena memory utilization exceeds 80% (any tier). Frontend should show warning. |

**Note:** When the project changes (user switches tabs or opens a different file), the playlist engine automatically stops and playlists are reloaded from the new project's saved state.

#### SMPTE Timecode Conversion

To display SMPTE timecode (HH:MM:SS:FF) from seconds:

```javascript
function secondsToSMPTE(seconds, frameRate, dropFrame) {
  const totalFrames = Math.floor(seconds * frameRate);

  if (dropFrame && (frameRate > 29 && frameRate < 30)) {
    // Drop-frame: skip frames 0,1 every minute except every 10th minute
    // This keeps timecode in sync with wall-clock time for 29.97fps
    const D = Math.floor(totalFrames / 17982);  // 10-minute chunks
    const M = totalFrames % 17982;
    const additionalFrames = 18 * D + 2 * Math.floor((M - 2) / 1798);
    const adjustedFrames = totalFrames + (M > 1 ? additionalFrames : 18 * D);

    const ff = adjustedFrames % 30;
    const ss = Math.floor(adjustedFrames / 30) % 60;
    const mm = Math.floor(adjustedFrames / 1800) % 60;
    const hh = Math.floor(adjustedFrames / 108000);

    return `${hh.toString().padStart(2,'0')}:${mm.toString().padStart(2,'0')}:${ss.toString().padStart(2,'0')};${ff.toString().padStart(2,'0')}`;
  }

  // Non-drop-frame
  const roundedRate = Math.round(frameRate);
  const ff = totalFrames % roundedRate;
  const ss = Math.floor(totalFrames / roundedRate) % 60;
  const mm = Math.floor(totalFrames / (roundedRate * 60)) % 60;
  const hh = Math.floor(totalFrames / (roundedRate * 3600));

  return `${hh.toString().padStart(2,'0')}:${mm.toString().padStart(2,'0')}:${ss.toString().padStart(2,'0')}:${ff.toString().padStart(2,'0')}`;
}
```

**Note:** Drop-frame timecode uses semicolons (`;`) as the frame separator, while non-drop-frame uses colons (`:`).

### `playlist` Event

Broadcast when playlist state changes (polled at 5Hz). Includes all playlists and engine state for late-joining clients.

```json
{
  "type": "event",
  "event": "playlist",
  "payload": {
    "playlists": [
      {
        "name": "Friday Gig",
        "entries": [
          {"regionId": 1, "loopCount": 4},
          {"regionId": 2, "loopCount": 2},
          {"regionId": 99, "loopCount": 1, "deleted": true}
        ],
        "stopAfterLast": true
      }
    ],
    "activePlaylistIndex": 0,
    "currentEntryIndex": 1,
    "loopsRemaining": 3,
    "currentLoopIteration": 2,
    "isPlaylistActive": true,
    "isPaused": false,
    "advanceAfterLoop": false
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `playlists` | array | All playlists in the project |
| `playlists[].name` | string | Playlist name |
| `playlists[].entries` | array | Ordered entries in the playlist |
| `playlists[].entries[].regionId` | int | Region ID (matches `id` in `regions` event) |
| `playlists[].entries[].loopCount` | int | -1=infinite, 0=skip, N=times to play |
| `playlists[].entries[].deleted` | bool? | `true` if region no longer exists (absent if valid) |
| `playlists[].stopAfterLast` | bool | Stop transport after final entry completes (default: true) |
| `activePlaylistIndex` | int\|null | Currently playing playlist (null if none) |
| `currentEntryIndex` | int\|null | Currently playing entry (null if none) |
| `loopsRemaining` | int\|null | Loops left on current entry (-1 if infinite) |
| `currentLoopIteration` | int\|null | Current loop number (1-indexed) |
| `isPlaylistActive` | bool | Playlist engine active (playing or paused) |
| `isPaused` | bool | Playlist paused (vs actively playing) |
| `advanceAfterLoop` | bool | Flag: will advance after current loop completes |

**Note:** `valid: false` indicates the referenced region was deleted. Frontend should show a warning and allow removal of invalid entries.

---

## Limits

| Resource | Max |
|----------|-----|
| Tracks polled | 128 |
| FX per track | 64 |
| Sends per track | 16 |
| Metered tracks | 16 |
| Markers | 256 |
| Regions | 256 |
| Items | 512 |
| Takes per item | 8 |
| Track/take name | 128 chars |
| Marker/region name | 128 chars |
| Item notes | 1024 chars |
| ExtState global value | 1024 chars |
| ExtState project value | 16384 chars |
| Playlists | 16 |
| Entries per playlist | 64 |
| Playlist name | 128 chars |
| Command queue | 256 pending |

---

## Error Responses

```json
{
  "type": "response",
  "id": "correlation-id",
  "success": false,
  "error": {"code": "NOT_FOUND", "message": "Item not found"}
}
```

Common error codes:

- `INVALID_POSITION` - Position is negative, NaN, or Inf
- `MISSING_*` - Required parameter not provided
- `NOT_FOUND` - Referenced item/marker/region doesn't exist
- `INVALID_RANGE` - End before start
- `QUEUE_FULL` - Command queue overflow (slow down!)

## Implementation Notes

### Position Precision

REAPER's HTTP API uses 15 decimal places for time positions (e.g., `17.332999999999998`). The WebSocket extension matches this precision for marker/region positions and time selection to avoid beat calculation errors at boundaries. Display values (position, cursorPosition, projectLength) use 3 decimal places to match REAPER's UI.
