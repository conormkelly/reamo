# Reamo WebSocket API Reference

WebSocket extension for REAPER control surfaces. Connect to `ws://localhost:9224` (ports 9224-9233 tried on startup).

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
2. Client sends value changes (`track/setVolume`, `track/setPan`)
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
| `controlType` | string | Yes | `"volume"` or `"pan"` |
| `trackIdx` | int | Yes | Track index (0 = master, 1+ = user tracks) |

```json
{"type": "command", "command": "gesture/start", "controlType": "volume", "trackIdx": 1}
```

### `gesture/end`

End a gesture on a continuous control. Triggers undo point creation.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `controlType` | string | Yes | `"volume"` or `"pan"` |
| `trackIdx` | int | Yes | Track index |

```json
{"type": "command", "command": "gesture/end", "controlType": "volume", "trackIdx": 1}
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
    "timeSelection": {"start": 0.000, "end": 60.000}
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

**Note:** Project-level settings (`repeat`, `metronome`, `projectLength`, `barOffset`) are in the `project` event.

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
        "fxEnabled": true
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
| `tracks[].idx` | int | Track index (0-based) |
| `tracks[].name` | string | Track name |
| `tracks[].color` | int | Track color (native OS format, 0=default) |
| `tracks[].volume` | float | Volume (1.0 = 0dB) |
| `tracks[].pan` | float | Pan (-1.0 to 1.0) |
| `tracks[].mute` | bool | Muted |
| `tracks[].solo` | int | Solo state (0=off, 1=solo, 2=solo in place) |
| `tracks[].recArm` | bool | Record armed |
| `tracks[].recMon` | int | Record monitoring (0=off, 1=on, 2=not when playing) |
| `tracks[].fxEnabled` | bool | FX enabled |
| `meters[].trackIdx` | int | Track index |
| `meters[].peakL/R` | float | Peak level (0.0-1.0+, 1.0 = 0dB) |
| `meters[].clipped` | bool | Clip indicator (sticky until cleared) |

**Note:** Meters only included for tracks that are record-armed AND input-monitoring.

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

Low-frequency event broadcast when project state changes. Contains undo/redo availability and project-level settings.

```json
{
  "type": "event",
  "event": "project",
  "payload": {
    "canUndo": "Changed marker",
    "canRedo": null,
    "stateChangeCount": 42,
    "repeat": false,
    "metronome": {"enabled": true, "volume": 0.5000, "volumeDb": -6.02},
    "master": {"stereoEnabled": true},
    "projectLength": 180.500,
    "barOffset": -4
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `canUndo` | string\|null | Description of next undo action, or null if nothing to undo |
| `canRedo` | string\|null | Description of next redo action, or null if nothing to redo |
| `stateChangeCount` | int | Project state change counter (for detecting changes) |
| `repeat` | bool | Repeat/loop mode enabled |
| `metronome` | object | Metronome state and volume |
| `master` | object | Master track settings |
| `master.stereoEnabled` | bool | `true` = stereo, `false` = mono (L+R summed) |
| `projectLength` | float | Project length in seconds (based on last item/region end) |
| `barOffset` | int | Bar offset (e.g., -4 means time 0 = bar 1, display starts at bar -4) |

---

## Limits

| Resource | Max |
|----------|-----|
| Tracks polled | 128 |
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
