# WebSocket Extension Audit Report

## Executive Summary

The Zig WebSocket extension has implemented **23 commands** covering transport, markers, regions, items, and takes. This audit identifies ALL gaps needed for complete frontend feature parity.

**Goal:** Total replacement of HTTP API with WebSocket for all frontend operations.

**Decisions Made:**

1. playState format: Keep integers (update spec to match)
2. Track operations: Add ALL to WebSocket extension
3. Time selection commands: Add to extension
4. Auth/handshake: Implement as best practice

---

## 1. What's Implemented in the Extension

### Commands (23 total)

| Category | Commands | Status |
|----------|----------|--------|
| **Transport (6)** | play, stop, pause, record, toggle, seek | Working |
| **Markers (4)** | add, update, delete, goto | Working |
| **Regions (4)** | add, update, delete, goto | Working |
| **Items (7)** | setActiveTake, move, color, lock, notes, delete, goto | Working |
| **Takes (2)** | delete, cropToActive | Working |

### Events (4 types)

| Event | Payload | Polling Rate |
|-------|---------|--------------|
| `transport` | playState, position, cursorPosition, bpm, timeSignature, timeSelection | ~30ms |
| `markers` | Array of {id, position, name, color} | ~30ms |
| `regions` | Array of {id, start, end, name, color} | ~30ms |
| `items` | Array filtered by time selection, with takes | ~30ms |

### Limits

- Max 256 markers, 256 regions, 512 items
- Max 8 takes per item
- Max 64 chars for marker/region names
- Max 256 chars for item notes

---

## 2. Key Decisions (from user input)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| playState format | Keep integers (0,1,2,5,6) | Matches existing frontend types.ts |
| Track operations | Add ALL to WebSocket | Goal is complete HTTP replacement |
| Time selection | Add to extension | Essential for frontend workflow |
| Auth/handshake | Implement | Best practice for production |
| Field naming | Keep short names (`position`, `start`, `end`) | Extension convention |

---

## 3. Spec Updates Needed

The spec (`docs/websocket-api-spec.yaml`) needs these changes:

1. Change `playState` from string enum to integer (0,1,2,5,6)
2. Add all item/take commands (already implemented)
3. Add track commands and track event schema
4. Add time selection commands
5. Add repeat commands
6. Add metronome/tempo commands
7. Add extstate commands
8. Add undo commands
9. Add action commands
10. Add SWS commands

---

## 4. Implementation Phases

### Phase 4b: Extension Completion (before client integration)

**Batch 1 - High Priority:**

- Time selection commands (6)
- Repeat commands (3)
- Transport additions (5)
- Marker nav commands (2)
- Take nav commands (2)
- Item selection commands (2)

**Batch 2 - Track Control:**

- Track commands (9)
- Track event with full state
- Send commands (3)

**Batch 3 - Advanced:**

- Metronome/tempo commands (5)
- ExtState commands (5)
- Undo commands (3)
- Action commands (2)
- SWS commands (2)

**Batch 4 - Protocol:**

- Token authentication
- Hello handshake
- Version checking

---

## 5. EXHAUSTIVE FEATURE MAPPING TABLE

This table maps EVERY frontend operation to its WebSocket extension equivalent.

**Legend:**

- ✅ = Implemented in extension
- ❌ = NOT implemented (needs work)
- 🔄 = Handled via push event (no command needed)

### 5.1 Transport Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Play | `play()` | `1007` | `transport/play` | ✅ |
| Pause | `pause()` | `1008` | `transport/pause` | ✅ |
| Stop | `stop()` | `40667` | `transport/stop` | ✅ |
| Stop & Save | `stopSave()` | `1016` | `transport/stopSave` | ❌ |
| Record | `record()` | `1013` | `transport/record` | ✅ |
| Abort Recording | `abortRecording()` | `40668` | `transport/abort` | ❌ |
| Play/Pause Toggle | - | - | `transport/toggle` | ✅ |
| Seek (seconds) | `setPosition(sec)` | `SET/POS/{sec}` | `transport/seek` | ✅ |
| Seek (string) | `setPositionString(str)` | `SET/POS_STR/{str}` | `transport/seekStr` | ❌ |
| Seek (beats) | - | - | `transport/seekBeats` | ❌ |
| Go to Project Start | - | `40042` | `transport/goStart` | ❌ |
| Go to Project End | - | `40043` | `transport/goEnd` | ❌ |

### 5.2 Transport State (Events)

| Data | Frontend Type | HTTP Response | WS Event Field | Status |
|------|---------------|---------------|----------------|--------|
| Play State | `PlayState (0,1,2,5,6)` | `TRANSPORT` | `transport.playState` | ✅ |
| Position (seconds) | `positionSeconds` | `TRANSPORT` | `transport.position` | ✅ |
| Position (formatted) | `positionString` | `TRANSPORT` | `transport.positionBeats` | ❌ |
| Cursor Position | - | - | `transport.cursorPosition` | ✅ |
| BPM | calculated from `BEATPOS` | `BEATPOS` | `transport.bpm` | ✅ |
| Time Sig Numerator | `timeSignatureNumerator` | `BEATPOS` | `transport.timeSignature.numerator` | ✅ |
| Time Sig Denominator | `timeSignatureDenominator` | `BEATPOS` | `transport.timeSignature.denominator` | ✅ |
| Bar Offset | calculated | - | `transport.barOffset` | ❌ |
| Repeat State | `isRepeat` | `GET/REPEAT` | `transport.repeat` | ❌ |

### 5.3 Repeat/Loop Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Get Repeat | `getRepeat()` | `GET/REPEAT` | 🔄 event | ❌ |
| Set Repeat | `setRepeat(val)` | `SET/REPEAT/{val}` | `repeat/set` | ❌ |
| Toggle Repeat | `toggleRepeat()` | `1068` | `repeat/toggle` | ❌ |

### 5.4 Time Selection Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Set Start | `setTimeSelectionStart()` | `40625` | `timeSelection/setStart` | ❌ |
| Set End | `setTimeSelectionEnd()` | `40626` | `timeSelection/setEnd` | ❌ |
| Set Range (seconds) | - | - | `timeSelection/set` | ❌ |
| Set Range (bar.beat) | - | - | `timeSelection/setBeats` | ❌ |
| Clear | `clearTimeSelection()` | `40020` | `timeSelection/clear` | ❌ |
| Go to Start | - | `40630` | `timeSelection/goStart` | ❌ |
| Go to End | - | `40631` | `timeSelection/goEnd` | ❌ |

**Notes:**

- Support BOTH seconds and bar.beat.tick for setting time selection
- `timeSelection/set` payload: `{start: seconds, end: seconds}`
- `timeSelection/setBeats` payload with flexible input:
  - Full: `{startBar, startBeat, startTick, endBar, endBeat, endTick}`
  - Partial: `{startBar: 1, startBeat: 1, endBar: 2, endBeat: 1}` → ticks inferred as 0
  - Minimal: `{startBar: 7, endBar: 9}` → beats/ticks inferred as 1.0 (bar start)
- Touch interface friendly: sending just bar numbers is valid for quick selection

### 5.5 Time Selection State (Events)

| Data | HTTP Response | WS Event Field | Status |
|------|---------------|----------------|--------|
| Start | cursor hack | `transport.timeSelection.start` | ✅ |
| End | cursor hack | `transport.timeSelection.end` | ✅ |

### 5.6 Metronome/Tempo Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Toggle Metronome | `toggleMetronome()` | `40364` | `metronome/toggle` | ❌ |
| Get Metronome Vol | - | - | `metronome/getVolume` | ❌ |
| Set Metronome Vol (dB) | `setMetronomeVolume(vol)` | `OSC/action%2F999%2Fcc:{vol}` | `metronome/setVolume` | ❌ |
| Get Metronome State | `getCommandState(40364)` | `GET/40364` | 🔄 event | ❌ |
| Set Tempo | `setTempo(bpm)` | `OSC/tempo%2Fraw:{bpm}` | `tempo/set` | ❌ |
| Tap Tempo | `tapTempo()` | `1134` | `tempo/tap` | ❌ |
| Set Time Signature | - | - | `project/setTimeSignature` | ❌ |
| Get Time Signature | - | - | 🔄 event | ✅ |

**Notes:**

- Metronome volume: Implement as dB slider with get/set (not just increment/decrement)
- Tempo validation: 2-960 BPM (REAPER's supported range)
- Time signature: numerator + denominator (e.g., 4/4, 6/8)

### 5.7 Marker Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Get All | `markers()` | `MARKER` | 🔄 event | ✅ |
| Add | - | - | `marker/add` | ✅ |
| Update (move/rename/color) | - | - | `marker/update` | ✅ |
| Reset Color to Default | - | - | `marker/resetColor` | ❌ |
| Delete | - | - | `marker/delete` | ✅ |
| Go To | - | - | `marker/goto` | ✅ |
| Previous | `prevMarker()` | `40172` | `marker/prev` | ❌ |
| Next | `nextMarker()` | `40173` | `marker/next` | ❌ |

**Notes:**

- `marker/update` supports: position (seconds OR bar.beat.tick with flexible input), name, color
  - Seconds: `{position: 12.5}`
  - Bar.beat.tick: `{bar: 7, beat: 2, tick: 45}` or `{bar: 7, beat: 2}` or just `{bar: 7}`
- Reset color to default: CAVEAT - may require delete+recreate (see Lua script implementation)
- prev/next navigate to ANY endpoint (markers, region bounds, time selection)
- **OLD LIMITATION REMOVED:** HTTP API only supported moving markers 1-10 (actions 40656-40665). WebSocket API has direct REAPER API access, so ALL markers can be moved regardless of ID.

### 5.8 Marker State (Events)

| Data | Frontend Type | WS Event Field | Status |
|------|---------------|----------------|--------|
| ID | `id: number` | `markers[].id` | ✅ |
| Position | `position: number` | `markers[].position` | ✅ |
| Name | `name: string` | `markers[].name` | ✅ |
| Color | `color?: number` | `markers[].color` | ✅ |

### 5.9 Region Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Get All | `regions()` | `REGION` | 🔄 event | ✅ |
| Add | - | - | `region/add` | ✅ |
| Update (move/resize/rename/color) | - | - | `region/update` | ✅ |
| Reset Color to Default | - | - | `region/resetColor` | ❌ |
| Delete | - | - | `region/delete` | ✅ |
| Go To | - | - | `region/goto` | ✅ |

**Notes:**

- `region/update` supports: start, end (seconds OR bar.beat.tick with flexible input), name, color
  - Seconds: `{start: 10.0, end: 20.0}`
  - Bar.beat.tick: `{startBar: 1, endBar: 5}` or full `{startBar, startBeat, startTick, endBar, endBeat, endTick}`
- Reset color: Same caveat as markers - may require delete+recreate

### 5.10 Region State (Events)

| Data | Frontend Type | WS Event Field | Status |
|------|---------------|----------------|--------|
| ID | `id: number` | `regions[].id` | ✅ |
| Start | `start: number` | `regions[].start` | ✅ |
| End | `end: number` | `regions[].end` | ✅ |
| Name | `name: string` | `regions[].name` | ✅ |
| Color | `color?: number` | `regions[].color` | ✅ |

### 5.11 Track Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Get Count | `trackCount()` | `NTRACK` | 🔄 event | ❌ |
| Get All | `allTracks()` | `TRACK` | 🔄 event | ❌ |
| Get Single | `track(idx)` | `TRACK/{idx}` | 🔄 event | ❌ |
| Get Range | `trackRange(s,e)` | `TRACK/{s}-{e}` | 🔄 event | ❌ |
| Set Volume | `setVolume(idx, val)` | `SET/TRACK/{idx}/VOL/{val}` | `track/setVolume` | ❌ |
| Set Volume (no gang) | `setVolume(idx, val, true)` | `SET/TRACK/{idx}/VOL/{val}g` | `track/setVolume` | ❌ |
| Set Pan | `setPan(idx, val)` | `SET/TRACK/{idx}/PAN/{val}` | `track/setPan` | ❌ |
| Set Pan (no gang) | `setPan(idx, val, true)` | `SET/TRACK/{idx}/PAN/{val}g` | `track/setPan` | ❌ |
| Set Width | `setWidth(idx, val)` | `SET/TRACK/{idx}/WIDTH/{val}` | `track/setWidth` | ❌ |
| Set Width (no gang) | `setWidth(idx, val, true)` | `SET/TRACK/{idx}/WIDTH/{val}g` | `track/setWidth` | ❌ |
| Set Mute | `setMute(idx, val)` | `SET/TRACK/{idx}/MUTE/{val}` | `track/setMute` | ❌ |
| Set Solo | `setSolo(idx, val)` | `SET/TRACK/{idx}/SOLO/{val}` | `track/setSolo` | ❌ |
| Set FX | `setFx(idx, val)` | `SET/TRACK/{idx}/FX/{val}` | `track/setFx` | ❌ |
| Set Record Arm | `setRecordArm(idx, val)` | `SET/TRACK/{idx}/RECARM/{val}` | `track/setRecArm` | ❌ |
| Set Record Monitor | `setRecordMonitor(idx, val)` | `SET/TRACK/{idx}/RECMON/{val}` | `track/setRecMon` | ❌ |
| Set Selection | `setSelection(idx, val)` | `SET/TRACK/{idx}/SEL/{val}` | `track/setSelection` | ❌ |

### 5.12 Track State (Events)

| Data | Frontend Type | WS Event Field | Status |
|------|---------------|----------------|--------|
| Index | `index: number` | `tracks[].index` | ❌ |
| Name | `name: string` | `tracks[].name` | ❌ |
| Flags | `flags: number` | `tracks[].flags` | ❌ |
| Volume | `volume: number` | `tracks[].volume` | ❌ |
| Pan | `pan: number` | `tracks[].pan` | ❌ |
| Peak L | `lastMeterPeak: number` | `tracks[].peakL` | ❌ |
| Peak R | `lastMeterPos: number` | `tracks[].peakR` | ❌ |
| Width | `width: number` | `tracks[].width` | ❌ |
| Pan Mode | `panMode: number` | `tracks[].panMode` | ❌ |
| Send Count | `sendCount: number` | `tracks[].sendCount` | ❌ |
| Receive Count | `receiveCount: number` | `tracks[].recvCount` | ❌ |
| HW Out Count | `hwOutCount: number` | `tracks[].hwOutCount` | ❌ |
| Color | `color: number` | `tracks[].color` | ❌ |

### 5.13 Send/Receive Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Get Send | `getSend(trk, snd)` | `GET/TRACK/{t}/SEND/{s}` | 🔄 event | ❌ |
| Set Send Vol | `setSendVolume(t,s,v)` | `SET/TRACK/{t}/SEND/{s}/VOL/{v}` | `send/setVolume` | ❌ |
| Set Send Pan | `setSendPan(t,s,v)` | `SET/TRACK/{t}/SEND/{s}/PAN/{v}` | `send/setPan` | ❌ |
| Set Send Mute | `setSendMute(t,s,v)` | `SET/TRACK/{t}/SEND/{s}/MUTE/{v}` | `send/setMute` | ❌ |

### 5.14 Item Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Select in Time Sel | `selectItemsInTimeSelection()` | `40718` | `item/selectInTimeSel` | ❌ |
| Unselect All | `unselectAllItems()` | `40289` | `item/unselectAll` | ❌ |
| Set Active Take | - | - | `item/setActiveTake` | ✅ |
| Move | - | - | `item/move` | ✅ |
| Set Color | - | - | `item/color` | ✅ |
| Set Lock | - | - | `item/lock` | ✅ |
| Set Notes | - | - | `item/notes` | ✅ |
| Delete | - | - | `item/delete` | ✅ |
| Go To | - | - | `item/goto` | ✅ |

### 5.15 Item State (Events)

| Data | WS Event Field | Status |
|------|----------------|--------|
| Track Index | `items[].trackIdx` | ✅ |
| Item Index | `items[].itemIdx` | ✅ |
| Position | `items[].position` | ✅ |
| Length | `items[].length` | ✅ |
| Color | `items[].color` | ✅ |
| Locked | `items[].locked` | ✅ |
| Active Take Idx | `items[].activeTakeIdx` | ✅ |
| Notes | `items[].notes` | ✅ |

### 5.16 Take Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Next Take | `nextTake()` | `42611` | `take/next` | ❌ |
| Previous Take | `previousTake()` | `42612` | `take/prev` | ❌ |
| Delete Active | - | - | `take/delete` | ✅ |
| Crop to Active | - | - | `take/cropToActive` | ✅ |

### 5.17 Take State (Events)

| Data | WS Event Field | Status |
|------|----------------|--------|
| Name | `items[].takes[].name` | ✅ |
| Is Active | `items[].takes[].isActive` | ✅ |

### 5.18 Extended State Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Get ExtState | `getExtState(sec, key)` | `GET/EXTSTATE/{s}/{k}` | `extstate/get` | ❌ |
| Set ExtState | `setExtState(s,k,v)` | `SET/EXTSTATE/{s}/{k}/{v}` | `extstate/set` | ❌ |
| Set ExtState (persist) | `setExtStatePersist(s,k,v)` | `SET/EXTSTATEPERSIST/{s}/{k}/{v}` | `extstate/setPersist` | ❌ |
| Get ProjExtState | `getProjExtState(sec, key)` | `GET/PROJEXTSTATE/{s}/{k}` | `projextstate/get` | ❌ |
| Set ProjExtState | `setProjExtState(s,k,v)` | `SET/PROJEXTSTATE/{s}/{k}/{v}` | `projextstate/set` | ❌ |

### 5.19 Undo Commands

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Add Undo Point | `setUndo(msg)` | `SET/UNDO/{msg}` | `undo/add` | ❌ |
| Begin Undo Block | `undoBegin()` | `SET/UNDO_BEGIN` | `undo/begin` | ❌ |
| End Undo Block | `undoEnd(msg)` | `SET/UNDO_END/{msg}` | `undo/end` | ❌ |

### 5.20 Command State (Generic Actions)

| Feature | Frontend Function | HTTP Command | WS Command | Status |
|---------|-------------------|--------------|------------|--------|
| Get Any State | `getCommandState(id)` | `GET/{id}` | `action/getState` | ❌ |
| Execute Action | `action(id)` | `{id}` | `action/execute` | ❌ |
| Get Track Property | `getTrackProperty(t, p)` | `GET/TRACK/{t}/{p}` | `track/getProperty` | ❌ |

### 5.21 SWS Extension Commands

| Feature | Constant | HTTP Command | WS Command | Status |
|---------|----------|--------------|------------|--------|
| Count-in Record | `SWSCommands.COUNT_IN_RECORD` | `_SWS_AWCOUNTRECTOG` | `sws/countInRecord` | ❌ |
| Count-in Playback | `SWSCommands.COUNT_IN_PLAYBACK` | `_SWS_AWCOUNTPLAYTOG` | `sws/countInPlayback` | ❌ |

### 5.22 Connection/Protocol

| Feature | WS Implementation | Status |
|---------|-------------------|--------|
| Token Auth | `?token=xxx` query param | ❌ |
| Hello Handshake | `hello` message with version | ❌ |
| Protocol Version Check | Close 4001/4002 on mismatch | ❌ |
| Snapshot on Connect | Full state dump | ✅ (no hello first) |
| Time Sync (playing) | Periodic position updates for interpolation | ❌ |

**Notes:**

- Time sync: Server sends position updates at 50-100ms intervals during playback
- Client interpolates between updates for smooth 60fps display
- Position displayed to 3 decimal places (e.g., 0:53.666)
- Bar/beat/tick display (e.g., 12.3.45)

---

## 6. IMPLEMENTATION SUMMARY

### Total Counts

| Category | Implemented | Missing | Total |
|----------|-------------|---------|-------|
| Transport Commands | 6 | 6 | 12 |
| Repeat Commands | 0 | 3 | 3 |
| Time Selection Commands | 0 | 7 | 7 |
| Metronome/Tempo Commands | 0 | 8 | 8 |
| Marker Commands | 5 | 3 | 8 |
| Region Commands | 5 | 1 | 6 |
| Track Commands | 0 | 12 | 12 |
| Track State (event) | 0 | 13 | 13 |
| Send Commands | 0 | 3 | 3 |
| Item Commands | 7 | 2 | 9 |
| Take Commands | 2 | 2 | 4 |
| ExtState Commands | 0 | 5 | 5 |
| Undo Commands | 0 | 3 | 3 |
| Action Commands | 0 | 3 | 3 |
| SWS Commands | 0 | 2 | 2 |
| Protocol Features | 1 | 4 | 5 |
| **TOTAL** | **26** | **77** | **103** |

### Commands to Add (by priority)

**High Priority (core functionality):**

1. Time Selection: `set`, `setBeats`, `setStart`, `setEnd`, `clear`, `goStart`, `goEnd`
2. Repeat: `set`, `toggle`
3. Transport: `stopSave`, `abort`, `seekStr`, `goStart`, `goEnd`
4. Markers: `prev`, `next`, `resetColor`
5. Regions: `resetColor`
6. Takes: `next`, `prev`
7. Items: `selectInTimeSel`, `unselectAll`

**Medium Priority (track control):**

8. Track commands: `setVolume`, `setPan`, `setWidth`, `setMute`, `setSolo`, `setFx`, `setRecArm`, `setRecMon`, `setSelection`
9. Track event with all properties + metering
10. Send commands: `setVolume`, `setPan`, `setMute`

**Medium Priority (metronome/tempo):**

11. Metronome: `toggle`, `getVolume`, `setVolume` (dB slider)
12. Tempo: `set` (2-960 BPM), `tap`
13. Project: `setTimeSignature` (numerator/denominator)

**Lower Priority (advanced features):**

14. ExtState: `get`, `set`, `setPersist`, `projGet`, `projSet`
15. Undo: `add`, `begin`, `end`
16. Actions: `getState`, `execute`
17. SWS: `countInRecord`, `countInPlayback`
18. Protocol: token auth, hello handshake, version check, time sync

### Transport Event Additions

- `positionBeats` (formatted bar.beat.ticks)
- `barOffset` (integer)
- `repeat` (boolean)

### New Events to Add

- `tracks` event with full track state + metering
- `commandState` event for metronome/count-in states

---

## 7. Files to Modify

### Extension

| File | Changes |
|------|---------|
| `extension/src/commands.zig` | Add ~45 new command handlers |
| `extension/src/transport.zig` | Add positionBeats, barOffset, repeat |
| `extension/src/tracks.zig` | NEW FILE: track state polling/events |
| `extension/src/protocol.zig` | Add new JSON builders for tracks |
| `extension/src/reaper.zig` | Add REAPER APIs for tracks, undo, tempo |
| `extension/src/main.zig` | Add track polling, auth validation |

### Spec

| File | Changes |
|------|---------|
| `docs/websocket-api-spec.yaml` | Update playState to int, add all commands/events |

### PLAN.md

| File | Changes |
|------|---------|
| `PLAN.md` | Add Phase 5a (extension completion) before client integration |
