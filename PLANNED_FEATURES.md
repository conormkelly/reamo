# Planned Features

## Table of Contents (Priority Order)

1. [Toolbar](#toolbar) — User-configurable buttons for actions & MIDI *(killer feature)*
2. [View Switcher](#view-switcher) — Switch between Edit, Transport, and Mixer views *(quick win, frontend-only)*
3. [ID-Keyed Pending State](#id-keyed-pending-state-architectural-fix) — Fix index-based state corruption *(stability)*
4. [Items Mode](#items-mode) — View/manage recorded takes without leaving the instrument
5. [Tempo Marker Support](#tempo-marker-support) — Respect tempo map during playback *(easy fix)*
6. [FX Preset Switching](#fx-preset-switching) — Navigate REAPER-saved presets from tablet
7. [Extension Performance Optimizations](#extension-performance-optimizations) — Idle when no clients

---

## Toolbar

### Rationale

Power users want to trigger custom workflows from their tablet: ReaScripts, SWS actions, MIDI-learnable plugin controls. Rather than building a full OSC/MIDI control surface, we provide a **user-configurable toolbar** where each button can trigger a REAPER action or send MIDI.

This fits REAPER's ethos of customizability — REAPER calls these "toolbars" and users already create custom actions, assign shortcuts, and write scripts. We just give them a way to trigger these from the tablet.

**Key use cases:**
- Guitarist with Arturia Pigments: Configure MIDI CC 20/21 for preset prev/next (plugin's MIDI learn)
- Power user with scripts: One-tap to run favorite ReaScripts
- Vocalist: Quick access to punch-in, cycle toggle, metronome

### UI Placement

The Toolbar appears as a **collapsible section** (chevron accordion, like Timeline and Mixer) in the app layout:

```
1. Header (Metronome, Tap, TimeSignature, ConnectionStatus)
2. TimeDisplay
3. Transport section (TransportBar + Undo/Redo/Save)
4. RecordingActionsBar (conditional - only during recording)
5. Toolbar (collapsible) ← HERE
6. Timeline (collapsible)
7. Mixer (collapsible)
8. Footer
```

### UI Concept

```txt
┌─────────────────────────────────────────────────────────────┐
│ ▼ Toolbar                                        [Edit] [+] │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐    │
│   │guitar│  │piano│  │ ◀  │  │ ▶  │  │link │  │file │    │
│   │Clean│  │Keys │  │Prev │  │Next │  │Glue │  │Notes│    │
│   └─────┘  └─────┘  └─────┘  └─────┘  └─────┘  └─────┘    │
│                                                             │
│   Toggle buttons show active state (e.g., highlighted       │
│   background when FX bypass is ON)                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Edit mode:** Long-press or tap [Edit] to enter edit mode. Buttons become draggable/deletable. Tap [+] to add new button.

**Add/Edit modal:**
```txt
┌─────────────────────────────────────────────────────┐
│ Add Toolbar Button                          [×]     │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Label: [Prev Preset    ]                           │
│                                                     │
│  Icon:  [Search icons...              ]  [Clear]    │
│         ┌───────────────────────────────────────┐   │
│         │ ▶  ⏸  ⏹  ⏺  🔁  🎸  🎹  🎤  🥁  🔊 │   │
│         │ ◀  ▶  ⬆  ⬇  ➕  ➖  ✓  ✕  ⚡  💾 │   │
│         │ ...more icons (scrollable)...         │   │
│         └───────────────────────────────────────┘   │
│  Icon Color:    [■ #000000] [picker]                │
│                                                     │
│  Text Color:    [■ #FFFFFF] [picker]                │
│                                                     │
│  Background:    [■ #374151] [picker]                │
│                                                     │
│  Type:  ○ REAPER Action  ● MIDI CC  ○ MIDI PC      │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │ CC Number:  [20 ]                           │   │
│  │ Value:      [127]                           │   │
│  │ Channel:    [1  ]                           │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
├─────────────────────────────────────────────────────┤
│                           [Cancel]  [Save]          │
└─────────────────────────────────────────────────────┘
```

**Color inputs:** System color picker + hex code input (same pattern as marker/region edit modals).

---

### Action Types

```typescript
// Common fields for all toolbar actions
interface ToolbarActionBase {
  label: string;
  icon?: string;            // Lucide icon name, e.g., "guitar", "play", "mic" (optional)
  iconColor?: string;       // Hex color, default "#000000" (black)
  textColor?: string;       // Hex color, default "#FFFFFF" (white)
  backgroundColor?: string; // Hex color, default "#374151" (gray-700)
}

type ToolbarAction =
  | ToolbarActionBase & {
      type: 'reaper_action';
      commandId: number;
    }
  | ToolbarActionBase & {
      type: 'reaper_action_name';
      name: string;        // e.g., "_SWS_SAVESEL" or "_RS12345..."
    }
  | ToolbarActionBase & {
      type: 'midi_cc';
      cc: number;          // 0-127
      value: number;       // 0-127
      channel: number;     // 0-15 (displayed as 1-16)
    }
  | ToolbarActionBase & {
      type: 'midi_pc';
      program: number;     // 0-127
      channel: number;     // 0-15
    };
```

**Rendering logic:**
- If `icon` is set → show icon (with optional label below), apply `iconColor`
- If no `icon` → show label only (larger text)
- Apply `textColor` to label, `backgroundColor` to button
- For toggle actions: modify background/border when active (see Toggle State section)

---

### Icons

Icons use **Lucide React** with dynamic imports for code-splitting. The `lucide-react/dynamic` export provides:

| Export | Purpose |
|--------|---------|
| `iconNames` | Array of 1909 icon names (~30KB, strings only) |
| `DynamicIcon` | Component that lazy-loads icons by name |

**Icon picker implementation:**

```tsx
import { iconNames, DynamicIcon } from 'lucide-react/dynamic';

function IconPicker({ value, onChange }: { value: string; onChange: (name: string) => void }) {
  const [search, setSearch] = useState('');

  const filtered = iconNames.filter(name =>
    name.includes(search.toLowerCase())
  );

  return (
    <div>
      <input
        placeholder="Search icons..."
        value={search}
        onChange={e => setSearch(e.target.value)}
      />
      <div className="grid grid-cols-8 gap-1 max-h-48 overflow-y-auto">
        {filtered.slice(0, 50).map(name => (
          <button
            key={name}
            onClick={() => onChange(name)}
            className={name === value ? 'ring-2 ring-blue-500' : ''}
          >
            <DynamicIcon name={name} size={20} />
          </button>
        ))}
      </div>
    </div>
  );
}
```

**Rendering saved icons:**

```tsx
<DynamicIcon name={action.icon} size={24} />
```

**Audio-related icons available:** `guitar`, `piano`, `drum`, `mic`, `mic-2`, `headphones`, `speaker`, `volume`, `volume-2`, `play`, `pause`, `square` (stop), `circle` (record), `repeat`, `music`, `music-2`, `audio-lines`, `audio-waveform`, etc.

**Bundle impact:**
- `iconNames` array: ~30KB (just strings, loaded once)
- Each icon: ~1-2KB (loaded on-demand when rendered)

---

### REAPER API

**Action execution** (already implemented):
```c
Main_OnCommand(commandId, 0);                    // By numeric ID
int cmd = NamedCommandLookup("_SWS_SAVESEL");    // Lookup named command
Main_OnCommand(cmd, 0);                          // Execute
```

**MIDI injection** (new):
```c
// StuffMIDIMessage injects MIDI into REAPER's virtual keyboard
// Mode 0 = sends to armed/monitored tracks
void StuffMIDIMessage(int mode, int msg1, int msg2, int msg3);

// CC example: CC 20, value 127, channel 1
StuffMIDIMessage(0, 0xB0 | 0, 20, 127);

// Program Change example: Program 5, channel 1
StuffMIDIMessage(0, 0xC0 | 0, 5, 0);
```

**Important:** MIDI reaches plugins only on tracks that are:
- Record-armed, OR
- Input monitoring enabled

---

### Protocol

**Client → Server:**
```json
{"type": "command", "command": "midi/cc", "cc": 20, "value": 127, "channel": 0, "id": "1"}
{"type": "command", "command": "midi/pc", "program": 5, "channel": 0, "id": "1"}
```

**Server → Client:**
```json
{"type": "response", "id": "1", "success": true}
```

---

### Toggle State Subscription

Some REAPER actions are **toggles** (e.g., "Toggle FX bypass", "Toggle metronome") with on/off state. The backend provides a subscription-based system to track these states in real-time.

#### REAPER API

```c
int GetToggleCommandState(int command_id);
// Returns: -1 = not a toggle, 0 = off, 1 = on
```

This is a cheap call (~microseconds), safe to poll at 30ms.

#### Architecture

The backend maintains a **reference-counted subscription cache**:

1. Frontend extracts REAPER action commandIds from toolbar config
2. Frontend subscribes to those commandIds on connect
3. Backend tracks union of all client subscriptions
4. Backend polls subscribed commandIds each tick (~30ms), detects changes
5. Backend broadcasts sparse updates (only changed states) to all clients
6. On disconnect, client's subscriptions are cleaned up (ref count decremented)

**Key principles:**
- **Snapshot on subscribe**: Immediately send current state for all subscribed IDs (critical for trust)
- **Sparse delta updates**: Only send commandIds that changed, not all subscribed states
- **Auto-detect toggles**: Backend calls `GetToggleCommandState` — if `-1`, it's not a toggle
- **Backend is toolbar-agnostic**: It just tracks toggle states for whoever asks

#### Protocol

**Subscribe (snapshot response):**
```json
→ {"type": "command", "command": "actionToggleState/subscribe", "commandIds": [40001, 40078, 40230], "id": "1"}
← {"type": "response", "id": "1", "success": true, "states": {"40001": 1, "40078": 0, "40230": -1}}
```

The response includes `-1` for non-toggle actions so the client knows not to display toggle UI for those.

**Unsubscribe:**
```json
→ {"type": "command", "command": "actionToggleState/unsubscribe", "commandIds": [40001], "id": "2"}
← {"type": "response", "id": "2", "success": true}
```

**State change events (broadcast):**
```json
← {"type": "event", "event": "actionToggleState", "changes": {"40001": 0}}
```

#### Data Structures (Extension)

```zig
const MAX_COMMAND_IDS = 256;  // Per-client limit
const MAX_CLIENTS = 16;

const ToggleSubscriptions = struct {
    // For each commandId: reference count (number of subscribed clients)
    ref_counts: std.AutoHashMap(u32, u8),

    // For each commandId: previous state for change detection
    prev_states: std.AutoHashMap(u32, i8),  // -1, 0, or 1

    // Per-client subscription sets (for cleanup on disconnect)
    client_subscriptions: [MAX_CLIENTS]std.AutoHashMap(u32, void),
};
```

**Polling loop:**
```zig
fn pollToggleStates(self: *ToggleSubscriptions) void {
    var changes = std.AutoHashMap(u32, i8).init(allocator);
    defer changes.deinit();

    // Only poll commandIds with subscribers
    var iter = self.ref_counts.keyIterator();
    while (iter.next()) |cmd| {
        const new_state = reaper.getToggleCommandState(cmd.*);
        const prev = self.prev_states.get(cmd.*) orelse -2;
        if (new_state != prev) {
            self.prev_states.put(cmd.*, new_state);
            changes.put(cmd.*, new_state);
        }
    }

    // Broadcast changes to all clients
    if (changes.count() > 0) {
        self.broadcastChanges(changes);
    }
}
```

#### Frontend Data Flow

```
Toolbar config (localStorage)
    → extract REAPER action commandIds
    → send actionToggleState/subscribe on connect
                                    ↓
                    Zustand store ← actionToggleState events
                          ↓
                    toggleStates: Map<commandId, -1 | 0 | 1>
                          ↓
                    Toolbar buttons read from store
                    (highlight active toggles, ignore -1 values)
```

#### Limits

- **256 commandIds per client** — generous for any realistic toolbar, prevents resource exhaustion
- **16 concurrent clients** — matches existing WebSocket limits

---

### Storage

**MVP: Browser localStorage**

```typescript
const STORAGE_KEY = 'reamo_toolbar';

// Load
const actions: ToolbarAction[] = JSON.parse(
  localStorage.getItem(STORAGE_KEY) || '[]'
);

// Save
localStorage.setItem(STORAGE_KEY, JSON.stringify(actions));
```

**Pros:** Persists across sessions, no backend changes needed.
**Cons:** Per-device (won't sync between iPad and phone).

**Future: Project EXTSTATE**

Store in project for project-specific action sets:
```json
{"type": "command", "command": "extstate/projSet", "extname": "Reamo", "key": "quickActions", "value": "[...]"}
```

Could support: global defaults (localStorage) + project overrides (EXTSTATE).

---

### Implementation Checklist

#### Extension

**MIDI commands:**
- [ ] Add `midi/cc` command handler
- [ ] Add `midi/pc` command handler
- [ ] Import `StuffMIDIMessage` from REAPER API
- [ ] Validate CC/PC values (0-127), channel (0-15)

**Toggle state subscription:**
- [ ] Import `GetToggleCommandState` from REAPER API
- [ ] Add `ToggleSubscriptions` struct with ref-counted tracking
- [ ] Add `actionToggleState/subscribe` command handler (returns snapshot)
- [ ] Add `actionToggleState/unsubscribe` command handler
- [ ] Poll subscribed commandIds in timer callback
- [ ] Broadcast `actionToggleState` events on state changes
- [ ] Clean up subscriptions on client disconnect
- [ ] Enforce 256 commandIds per client limit

#### Frontend

**Components:**
- [ ] `Toolbar` — collapsible section with horizontal scrollable button bar
- [ ] `ToolbarButton` — individual action button with toggle state support
- [ ] `ToolbarEditor` — modal for add/edit with color pickers
- [ ] `IconPicker` — searchable Lucide icon grid (see [Icons](#icons) section)
- [ ] `ColorPickerInput` — hex input + system color picker (reuse from marker/region modals)

**State:**
- [ ] Load actions from localStorage on mount
- [ ] Save actions to localStorage on change
- [ ] Edit mode toggle
- [ ] Drag-to-reorder (nice-to-have)
- [ ] `toggleStates: Map<number, -1 | 0 | 1>` in Zustand store
- [ ] Subscribe to toggle states on connect (extract commandIds from toolbar config)
- [ ] Handle `actionToggleState` events to update store

**Commands:**
- [ ] Wire up action execution (already have `action/execute`)
- [ ] Wire up MIDI CC/PC commands (new)
- [ ] Wire up `actionToggleState/subscribe` on toolbar load
- [ ] Wire up `actionToggleState/unsubscribe` on toolbar change (removed actions)

---

### Example Configurations

**Guitarist controlling Arturia Pigments via MIDI learn:**
```json
[
  {"type": "midi_cc", "cc": 20, "value": 127, "channel": 0, "label": "Prev", "icon": "chevron-left"},
  {"type": "midi_cc", "cc": 21, "value": 127, "channel": 0, "label": "Next", "icon": "chevron-right"}
]
```

**Power user with SWS actions:**
```json
[
  {"type": "reaper_action_name", "name": "_SWS_SAVESEL", "label": "Save", "icon": "save"},
  {"type": "reaper_action_name", "name": "_SWS_RESTORESEL", "label": "Restore", "icon": "undo"},
  {"type": "reaper_action", "commandId": 40020, "label": "Glue", "icon": "link"}
]
```

**Color-coded presets (label-only, no icons):**
```json
[
  {"type": "midi_pc", "program": 0, "channel": 0, "label": "Clean", "backgroundColor": "#22c55e"},
  {"type": "midi_pc", "program": 1, "channel": 0, "label": "Crunch", "backgroundColor": "#eab308"},
  {"type": "midi_pc", "program": 2, "channel": 0, "label": "Lead", "backgroundColor": "#ef4444"}
]
```

**Toggle actions (auto-detected, UI reflects on/off state):**
```json
[
  {"type": "reaper_action", "commandId": 1013, "label": "Cycle", "icon": "repeat"},
  {"type": "reaper_action", "commandId": 40364, "label": "Click", "icon": "drum"},
  {"type": "reaper_action", "commandId": 96, "label": "T10 Bypass", "icon": "power"}
]
```
*These are toggle actions — the UI will show active/inactive state based on `actionToggleState` events.*

**Custom styled button:**
```json
[
  {
    "type": "reaper_action",
    "commandId": 40172,
    "label": "Marker",
    "icon": "map-pin",
    "iconColor": "#fbbf24",
    "textColor": "#fbbf24",
    "backgroundColor": "#1f2937"
  }
]
```

---

### Future Enhancements

- **Action search:** Type to search REAPER's action list by name
- **Import/export:** Share action sets as JSON
- **Project sync:** Store in project EXTSTATE for project-specific setups
- **Conditional visibility:** Show different actions based on transport state
- **Folders/pages:** Group actions into swipeable pages for larger collections

---

## FX Preset Switching

### Rationale

Guitarists and keyboard players want to switch between tones/patches without walking to the computer. While most modern plugins (Neural DSP, Kontakt, etc.) use internal preset browsers that bypass REAPER's API, **REAPER's own preset system works universally**.

**The workflow:**
1. User dials in a tone in their plugin
2. User saves it as a REAPER preset (click "+" in FX header)
3. REAPER stores complete plugin state in `.rpl` file
4. Reamo can browse and switch these presets

This trades factory preset discovery for universal compatibility. For guitarists with 20-50 curated tones, this is actually preferred — they don't need 500 factory presets, just their saved tones.

**For plugins with internal browsers:** Use the [Toolbar](#toolbar) with MIDI CC to control preset switching via the plugin's MIDI learn feature.

---

### REAPER API

```c
// Get current preset index and count
int TrackFX_GetPresetIndex(MediaTrack* track, int fx, int* numberOfPresetsOut);
// Returns: current index (0-based), or -1 on error
// numberOfPresetsOut: total preset count (factory + user)

// Set preset by index
bool TrackFX_SetPresetByIndex(MediaTrack* track, int fx, int presetIndex);
// Special values: -1 = default user preset, -2 = factory defaults

// Get current preset name
bool TrackFX_GetPreset(MediaTrack* track, int fx, char* presetname, int presetname_sz);
// Returns: true if parameters match loaded preset exactly

// Navigate presets relatively
bool TrackFX_NavigatePresets(MediaTrack* track, int fx, int presetmove);
// presetmove: +1 = next, -1 = previous
```

**Key limitation:** No API to enumerate preset names. Can only get count and current name. Must iterate (slow) to build full list.

---

### State Changes

Extend tracks event with FX info:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [{
      "idx": 1,
      "name": "Guitar",
      "fx": [{
        "name": "Neural DSP Archetype Gojira",
        "presetName": "My Clean Tone",
        "presetIndex": 3,
        "presetCount": 12,
        "modified": false
      }]
    }]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `fx[].name` | string | Plugin name |
| `fx[].presetName` | string | Current preset name |
| `fx[].presetIndex` | int | Current preset index (0-based) |
| `fx[].presetCount` | int | Total preset count |
| `fx[].modified` | bool | Parameters changed since preset load |

---

### Protocol

**Navigate presets:**
```json
{"type": "command", "command": "fx/presetNext", "trackIdx": 1, "fxIdx": 0, "id": "1"}
{"type": "command", "command": "fx/presetPrev", "trackIdx": 1, "fxIdx": 0, "id": "1"}
{"type": "command", "command": "fx/presetSet", "trackIdx": 1, "fxIdx": 0, "presetIdx": 5, "id": "1"}
```

---

### UI Concept

**Minimal (MVP):** Add to track long-press menu or dedicated FX panel.

```txt
┌─────────────────────────────────────────────────────┐
│ Guitar                                    [FX ▼]    │
├─────────────────────────────────────────────────────┤
│                                                     │
│              Neural DSP Archetype Gojira            │
│                                                     │
│    ┌──────┐    "My Clean Tone"      ┌──────┐       │
│    │  ◀   │        3 of 12          │  ▶   │       │
│    │ PREV │                         │ NEXT │       │
│    └──────┘                         └──────┘       │
│                                                     │
│               [Modified ●]                          │
└─────────────────────────────────────────────────────┘
```

**FX selector dropdown** when track has multiple plugins. Shows first FX by default.

---

### Implementation Checklist

#### Extension

**Prerequisites:**
- [ ] Add `TrackFX_GetCount` to get FX count per track
- [ ] Add `TrackFX_GetFXName` to get plugin names
- [ ] Add `TrackFX_GetPresetIndex` for preset state
- [ ] Add `TrackFX_GetPreset` for preset name + modified flag

**State polling:**
- [ ] Add `fx` array to track state
- [ ] Poll FX state on track change (not every 30ms — too expensive)
- [ ] Consider `CSURF_EXT_TRACKFX_PRESET_CHANGED` for notifications

**Commands:**
- [ ] Add `fx/presetNext` handler using `TrackFX_NavigatePresets(+1)`
- [ ] Add `fx/presetPrev` handler using `TrackFX_NavigatePresets(-1)`
- [ ] Add `fx/presetSet` handler using `TrackFX_SetPresetByIndex`

#### Frontend

- [ ] Add FX state to Track type
- [ ] Create FX preset UI component
- [ ] Integrate with track selection or dedicated panel
- [ ] Handle "no presets" case (show guidance to save REAPER presets)

---

### Gotchas

**Plugins with internal browsers:** Will show 0 or very few presets. Detect and show:
> "This plugin manages presets internally. Save your favorite sounds as REAPER presets to control them from Reamo, or use Quick Actions with MIDI CC."

**Undo points:** Each `TrackFX_SetPreset` creates an undo point. Consider debouncing for rapid clicking.

**Performance:** Don't poll FX state every 30ms. Poll on:
- Track selection change
- `CSURF_EXT_TRACKFX_PRESET_CHANGED` notification
- Manual refresh

---

## View Switcher

### Rationale

Different contexts call for different interfaces. When recording a verse, you want full timeline visibility with regions and markers. When performing or running down a song with the band, you want big transport controls visible from across the room. When mixing, you want as many faders on screen as possible.

Rather than forcing users to mount multiple devices (though that's still supported via WebSocket), a simple view switcher lets one device adapt to the current workflow.

**Key insight:** This is frontend-only. No protocol changes, no extension work. Just reorganizing existing components.

---

### Views

| View | Purpose | Components |
|------|---------|------------|
| **Edit** (default) | Songwriting workflow | Timeline + regions + markers + mixer + transport |
| **Transport** | Performer/big display | Large play/stop/record, BPM, bar.beat counter, minimal else |
| **Mixer** | Mixing focus | Full-width faders, more tracks visible, compact transport |

---

### UI Concept

**Access:** Hamburger menu or bottom nav bar.

```txt
┌─────────────────────────────────────────────────────┐
│ ☰ Reamo                              [Edit ▼]       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  (current view content)                             │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Dropdown options:**
- Edit View (timeline + mixer)
- Transport View (big controls)
- Mixer View (faders focus)

---

### Transport View

Large touch targets for stage/studio use. Visible from 10+ feet away.

```txt
┌─────────────────────────────────────────────────────┐
│                                                     │
│                    ♩ = 120 BPM                      │
│                                                     │
│                    17 . 3 . 2                       │
│                  (bar.beat.sub)                     │
│                                                     │
│     ┌───────┐    ┌───────┐    ┌───────┐           │
│     │       │    │       │    │       │           │
│     │  ⏮️   │    │  ⏯️   │    │  ⏹️   │           │
│     │       │    │       │    │       │           │
│     └───────┘    └───────┘    └───────┘           │
│                                                     │
│                   ┌───────┐                         │
│                   │  ⏺️   │                         │
│                   │RECORD │                         │
│                   └───────┘                         │
│                                                     │
│  [Cycle: OFF]  [Click: ON]  [Punch: OFF]           │
└─────────────────────────────────────────────────────┘
```

**Key elements:**
- Huge play/pause button (primary action)
- Big bar.beat display
- BPM display (tap to change)
- Record button with visual feedback
- Status indicators for cycle, click, punch

---

### Mixer View

Maximize fader real estate. More tracks, less timeline.

```txt
┌─────────────────────────────────────────────────────┐
│ ▶ 17.3.2    120 BPM    [⏺]           [Edit ▼]      │
├────┬────┬────┬────┬────┬────┬────┬────┬────┬────┤
│ Drm│ Bas│ Gtr│ Vox│ Syn│ Pad│ FX │ Bus│ ... │    │
│ ▓▓▓│ ▓░░│ ▓▓░│ ▓░░│ ░░░│ ▓▓▓│ ▓▓░│ ▓▓▓│     │    │
│ ║  │ ║  │ ║  │ ║  │ ║  │ ║  │ ║  │ ║  │     │    │
│ ║▓▓│ ║▓░│ ║▓▓│ ║▓░│ ║░░│ ║▓▓│ ║▓▓│ ║▓▓│     │    │
│ ║▓▓│ ║░░│ ║▓░│ ║▓░│ ║░░│ ║▓▓│ ║▓░│ ║▓▓│     │    │
│ M S│ M S│ M S│ M S│ M S│ M S│ M S│ M S│     │    │
└────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘
```

**Key elements:**
- Compact transport strip at top
- Horizontal scrolling for many tracks
- Taller faders (more precision)
- No timeline/regions (use Edit view for that)

---

### Storage

```typescript
const VIEW_STORAGE_KEY = 'reamo_current_view';

type View = 'edit' | 'transport' | 'mixer';

// Load on startup
const savedView = localStorage.getItem(VIEW_STORAGE_KEY) as View || 'edit';

// Save on change
localStorage.setItem(VIEW_STORAGE_KEY, currentView);
```

Per-device storage is appropriate here — each mounted device can have its own preferred view.

---

### Implementation Checklist

#### State

- [ ] Add `currentView: View` to app state (Zustand or context)
- [ ] Load saved view from localStorage on mount
- [ ] Save view to localStorage on change

#### Components

- [ ] `ViewSwitcher` — dropdown/menu for view selection
- [ ] `TransportView` — new component with big controls
- [ ] `MixerView` — new component (or existing mixer in expanded mode)
- [ ] Conditional rendering in `App.tsx` based on `currentView`

#### Transport View specifics

- [ ] Large bar.beat display with prominent font
- [ ] Big touch-friendly transport buttons
- [ ] BPM display (reuse existing tap-tempo logic)
- [ ] Toggle indicators for cycle, click, punch modes

#### Mixer View specifics

- [ ] Compact transport strip
- [ ] Horizontal scroll for tracks
- [ ] Taller faders
- [ ] Hide timeline/region components

---

### Future Enhancements

- **Custom views:** Let users pick which components appear in each view
- **Gesture switching:** Swipe left/right to change views
- **Auto-switch:** Automatically switch to Transport when recording starts
- **Per-project view:** Store preferred view in project EXTSTATE

---

## Items Mode

### Rationale

The current app shows regions (song structure) but not what's actually recorded in them. Users must go to the computer to see/manage takes. This breaks the "stay at instrument" workflow.

### UI Concept

**Level of Detail (LOD) approach:**

**Zoomed Out (Navigate/Regions mode):**
Items shown as aggregate blobs — visual reference only, read-only.

```txt
┌─────────────────────────────────────────┐
│ Verse 1          │ Chorus               │
│ ▓▓░░▓▓▓░░▓▓     │ ▓▓▓▓░░░▓▓           │
└─────────────────────────────────────────┘
```

**Zoomed In (Items mode):**
Double-tap region or zoom to time selection. Single track view with detailed item management.

```txt
┌─────────────────────────────────────────────────────┐
│ Track: Guitar ▼              [Time Selection]       │
├─────────────────────────────────────────────────────┤
│                                                     │
│    ┌─────────────┐              ┌─────────────┐    │
│    │     1/3     │              │     2/3     │    │
│    │ ▓▓▓▓▓▓▓▓▓▓▓ │              │ ▓▓▓▓▓▓▓▓▓▓▓ │    │
│    └─────────────┘              └─────────────┘    │
│         ▲                                          │
│     (selected)                                     │
├─────────────────────────────────────────────────────┤
│ Take 1 of 3  [◀][▶]  [Crop] [🗑] [Notes] [Color]   │
└─────────────────────────────────────────────────────┘
```

**Key UI decisions:**

- Show ONE track at a time (not all tracks)
- Track dropdown shows tracks with items in the time selection
- Items shown as single bars (active take color) with take count badge ("1/3")
- No visual stacking of takes (unlike REAPER's arrange view)
- ItemInfoBar for selected item: take switching, actions

**Architecture decision:** Backend sends ALL items (no server-side filtering). Frontend filters by time selection as needed. This enables LOD overview (colored bars showing "stuff here") and avoids round-trips when switching views. Time selection is obtained from the transport event, not the items event.

> See [ITEMS_MODE_FEATURE.md](ITEMS_MODE_FEATURE.md) for detailed implementation spec.

### Supported Item Actions

| Action | Purpose | REAPER API |
|--------|---------|------------|
| Switch take | Navigate takes | `SetMediaItemInfo_Value(item, "I_CURTAKE", index)` |
| Delete take | Remove bad take | `Main_OnCommand(40129, 0)` |
| Crop to active | "This is the keeper" | `Main_OnCommand(40131, 0)` |
| Move item | Nudge position | `SetMediaItemInfo_Value(item, "D_POSITION", pos)` |
| Set color | Visual organization | `SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)` |
| Lock | Protect from accidents | `SetMediaItemInfo_Value(item, "C_LOCK", 1)` |
| Add notes | "Good energy", etc. | `GetSetMediaItemInfo_String(item, "P_NOTES", ...)` |
| Delete item | Remove entirely | `DeleteTrackMediaItem(track, item)` |

### What This Is NOT

- No comping lanes
- No crossfades
- No waveform editing
- No split/glue
- No detailed MIDI editing

Just: **"See what I recorded, tidy it up, make quick keep/trash decisions, move on."**

---

## ID-Keyed Pending State (Architectural Fix)

### The Problem

Current `pendingChanges` is keyed by **array index**, but array indices shift when the server pushes region updates (add/delete/reorder). This causes:

1. User edits region at index 2 (id=5)
2. Server pushes update: region at index 0 deleted
3. Array re-indexes: index 2 now contains different region (id=7)
4. `pendingChanges[2]` visually overlays on wrong region
5. Save is correct (uses `originalIdx` = stable ID), but **display is wrong**

### The Solution

**Key pending changes by stable entity ID, not array index.** This is the established pattern used by Apollo Client (normalized cache), Replicache (key-based storage), and TanStack Query.

```typescript
// ❌ Current: index-based (breaks when indices shift)
pendingChanges: Record<number, PendingRegionChange>  // key = array index

// ✅ Fixed: ID-based (stable forever)
pendingChanges: Map<number, PendingRegionChange>     // key = region.id (markrgnidx)
```

For new regions (not yet in REAPER), continue using negative IDs as keys.

### Implementation Checklist

**Types (`regionEditSlice.types.ts`):**
- [ ] Change `PendingChangesRecord` from `Record<number, ...>` to `Map<number, ...>`
- [ ] Remove `_pendingKey` from `DisplayRegion` (no longer needed)
- [ ] Add `baseVersion?: number` to track server state when editing began

**Slice (`regionEditSlice.ts`):**
- [ ] Update `getDisplayRegions()` to look up by `region.id` instead of array index
- [ ] Update all ripple calculation functions to use IDs
- [ ] Update `selectedRegionIndices` to store IDs, not array indices

**Ripple operations (`regionEdit/rippleOperations.ts`):**
- [ ] All functions currently take `index` parameter → change to `id` parameter
- [ ] Update internal logic to work with ID-keyed maps

**Components:**
- [ ] `TimelineRegions.tsx`: Remove `_pendingKey` usage, look up by `region.id`
- [ ] `RegionInfoBar.tsx`: Same
- [ ] `Timeline.tsx`: Update `selectedPendingKeys` computation
- [ ] `useRegionDrag.ts`: Update to use IDs

**Tests:**
- [ ] Update all region edit tests to use ID-based assertions
- [ ] Add test: server update during pending changes doesn't corrupt display

### Conflict Detection (Future Enhancement)

For the multi-device scenario (edit on iPad, changes on computer, save from iPad):

**Option 1: Optimistic Locking (Recommended for MVP)**
- Track `baseVersion` when editing begins
- On save, include expected version
- Server rejects if version changed → prompt user to refresh

**Option 2: Field-level Last-Write-Wins**
- Each field carries timestamp
- Newest value wins per field
- Use Hybrid Logical Clocks to avoid clock skew

For single-user DAW where conflicts are rare, Option 1 is sufficient.

### Why Not OT/CRDTs?

Full Operational Transformation or CRDTs add 15-500KB of library code and complexity. The core insight from CRDT research applies without the overhead: **stable IDs eliminate index-shifting problems entirely**. Once every entity has an immutable ID and all operations reference that ID, no transformation is needed.

---

## Tempo Marker Support

### The Problem

The current implementation uses `GetProjectTimeSignature2()` to fetch BPM and time signature, which **only returns project-level defaults**. This ignores tempo markers entirely.

```zig
// Current (BROKEN for tempo markers):
api.getProjectTimeSignature2(null, &bpm, &num, &denom);
// Returns: project default tempo (e.g., 120 BPM, 4/4)
// Ignores: any tempo markers in the project
```

### Correct API

`TimeMap_GetTimeSigAtTime()` returns **both** BPM and time signature at any position, fully respecting the tempo map including linear ramps:

```c
void TimeMap_GetTimeSigAtTime(
    ReaProject* proj,           // NULL for active project
    double time,                // position in seconds
    int* timesig_numOut,        // beats per measure (e.g., 4)
    int* timesig_denomOut,      // note value per beat (e.g., 4)
    double* tempoOut            // BPM at this position
);
```

**Key findings:**
- Single call returns both tempo AND time signature (no need for `TimeMap2_GetDividedBpmAtTime`)
- Handles tempo ramps (linear interpolation) automatically
- Works even with zero tempo markers (returns project defaults)
- At exact marker boundary, returns NEW values (post-marker)

### Gotchas

**Zero time sig values mean "inherit":** When a tempo marker only changes BPM (not time sig), the API returns 0 for timesig_num/denom. Always handle this:

```zig
if (timesig_num == 0) timesig_num = 4;  // Default to 4/4
if (timesig_denom == 0) timesig_denom = 4;
```

**`positionBeats` already works:** Our `TimeMap2_timeToBeats()` call already respects tempo markers - no changes needed there.

### Performance Optimization (Optional)

For projects with sparse tempo changes, cache the next change time to reduce API calls:

```c
static double s_nextChangeTime = -1;
// Only re-query if we've crossed a marker boundary
if (s_nextChangeTime < 0 || currentPos >= s_nextChangeTime) {
    TimeMap_GetTimeSigAtTime(NULL, currentPos, ...);
    s_nextChangeTime = TimeMap2_GetNextChangeTime(NULL, currentPos);
}
```

For tempo ramps, per-frame queries are still needed during interpolation.

### Implementation Checklist

**Extension (`transport.zig`):**
- [ ] Add REAPER API binding for `TimeMap_GetTimeSigAtTime`
- [ ] Replace `getProjectTimeSignature2()` with `TimeMap_GetTimeSigAtTime()`
- [ ] Pass current play position (or edit cursor when stopped)
- [ ] Handle zero timesig values (default to 4/4)

**Frontend:**
- [ ] No changes required - transport event structure unchanged

**Testing:**
- [ ] Create test project with multiple tempo markers
- [ ] Verify BPM updates when cursor crosses tempo marker during playback
- [ ] Verify time signature updates when crossing time sig marker
- [ ] Test tempo ramps (linear interpolation between markers)
- [ ] Test project with no tempo markers (should use defaults)

### Future: Tempo Map Visualization

For displaying the full tempo map in UI:

| Function | Purpose |
|----------|---------|
| `CountTempoTimeSigMarkers(proj)` | Count markers |
| `GetTempoTimeSigMarker(proj, idx, ...)` | Read marker details |
| `FindTempoTimeSigMarker(proj, time)` | Find marker at position |
| `TimeMap2_GetNextChangeTime(proj, time)` | Find next tempo change (-1 if none)

---

## Extension Performance Optimizations

### Idle When No Clients Connected

**The Problem:**
The extension currently polls REAPER state every 30ms regardless of whether any WebSocket clients are connected. This wastes CPU cycles when the frontend isn't running.

**Solution:**
Skip the polling loop when `clientCount == 0`. Only resume polling when a client connects.

**Implementation:**
```zig
// In the 30ms timer callback:
if (server.clientCount() == 0) return; // Early exit, no work to do

// ... existing polling logic ...
```

**Considerations:**
- First client connection may see a slight delay as state is gathered
- Could optionally do a single immediate poll on client connect to minimize latency
- Track `wasIdle` state to log when transitioning between idle/active

## Project Notes Support

Project notes are useful for session-level metadata: "Client: Acme Records", "Reference tempo: 128 BPM before we slowed it down", "TODO: re-record verse 2 vocals", etc. Currently requires going to the computer (`File > Project Notes...`). Should be accessible from the WebUI.

---

### REAPER API

```c
void GetSetProjectNotes(
    ReaProject* proj,      // NULL for active project
    bool set,              // false = get, true = set
    char* notesNeedBig,    // buffer for notes
    int notesNeedBig_sz    // buffer size
);
```

**Key characteristics:**

- Returns `void` — no way to query required size
- No documented max length (practically unbounded, stored as text in RPP)
- Notes may contain newlines (`\n`, `\r\n`, or `\r` depending on platform/history)
- Empty project notes = empty string (not null)

---

### Buffer Strategy

Since the API doesn't report truncation, use iterative resizing. The heuristic: if `strlen(result) >= bufferSize - 1`, the content was likely truncated.

```zig
fn getProjectNotes(allocator: Allocator) ![:0]u8 {
    var size: usize = 4096; // Start reasonable

    while (size <= 1024 * 1024) { // Cap at 1MB
        const buf = try allocator.allocSentinel(u8, size - 1, 0);
        errdefer allocator.free(buf);

        @memset(buf, 0);
        api.GetSetProjectNotes(null, false, buf.ptr, @intCast(size));

        const len = std.mem.indexOfScalar(u8, buf, 0) orelse size - 1;

        // If we didn't fill the buffer, we got everything
        if (len < size - 1) {
            // Optionally shrink to actual size
            if (allocator.resize(buf, len + 1)) |resized| {
                return resized[0..len :0];
            }
            return buf[0..len :0];
        }

        // Likely truncated — double and retry
        allocator.free(buf);
        size *= 2;
    }

    return error.NotesTooLarge;
}

fn setProjectNotes(notes: [:0]const u8) void {
    // Cast away const - REAPER doesn't modify when set=true, but signature isn't const
    const ptr: [*]u8 = @constCast(notes.ptr);
    api.GetSetProjectNotes(null, true, ptr, @intCast(notes.len + 1));
}
```

---

### Protocol Design

**Decision: On-demand, not polled.**

Unlike transport (continuous) or regions (polled for external changes), project notes:

- Change infrequently
- Can be large
- Don't need real-time sync

Use request/response pattern instead of continuous polling.

#### Messages

**Client → Server: Request notes**

```json
{
  "type": "getProjectNotes"
}
```

**Server → Client: Notes response**

```json
{
  "type": "projectNotes",
  "notes": "Session notes here...\nLine 2\nLine 3"
}
```

**Client → Server: Set notes**

```json
{
  "type": "setProjectNotes",
  "notes": "Updated notes content"
}
```

**Server → Client: Confirmation**

```json
{
  "type": "projectNotesSet",
  "success": true
}
```

Optionally, after successful set, server can echo back the saved notes (re-fetched from REAPER) to confirm round-trip integrity.

---

### UI Concept

**Access:** Button in transport bar or settings/menu area: `[📝]` or `[Notes]`

**Modal/Panel:**

```txt
┌─────────────────────────────────────────────────────┐
│ Project Notes                              [×]      │
├─────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────────────┐ │
│ │ Client: Acme Records                            │ │
│ │ Session date: 2024-01-15                        │ │
│ │                                                 │ │
│ │ TODO:                                           │ │
│ │ - Re-record verse 2 vocals                      │ │
│ │ - Fix timing on bridge guitar                   │ │
│ │                                                 │ │
│ │                                                 │ │
│ └─────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────┤
│                           [Cancel]  [Save]          │
└─────────────────────────────────────────────────────┘
```

**Behavior:**

- Opens modal or slide-out panel
- Fetches current notes on open (shows loading state)
- Textarea for editing (auto-resize or fixed with scroll)
- Cancel = discard local changes, close
- Save = send to server, wait for confirmation, close
- Dirty indicator if local changes exist (prompt to confirm before closing)

---

### Implementation Checklist

#### Extension

- [ ] Add REAPER API import: `GetSetProjectNotes`
- [ ] Implement get function with iterative buffer resize strategy
- [ ] Implement set function
- [ ] Add WebSocket message handler for `getProjectNotes` request
- [ ] Add WebSocket message handler for `setProjectNotes` request
- [ ] Send `projectNotes` response with fetched content
- [ ] Send `projectNotesSet` confirmation after successful write

#### Shared Types

```typescript
// Server → Client
interface ProjectNotesEvent {
  type: 'projectNotes';
  notes: string;
}

interface ProjectNotesSetEvent {
  type: 'projectNotesSet';
  success: boolean;
  error?: string;
}

// Client → Server
interface GetProjectNotesRequest {
  type: 'getProjectNotes';
}

interface SetProjectNotesRequest {
  type: 'setProjectNotes';
  notes: string;
}
```

#### Frontend State

**Required state fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `serverNotes` | `string \| null` | Last value fetched from server (`null` = never fetched) |
| `localNotes` | `string \| null` | Current editor content (`null` = editor closed) |
| `isLoading` | `boolean` | Fetch request in progress |
| `isSaving` | `boolean` | Save request in progress |
| `error` | `string \| null` | Last error message |

**Derived state:**

| Selector | Logic | Purpose |
|----------|-------|---------|
| `isDirty` | `localNotes !== null && localNotes !== serverNotes` | Unsaved changes exist |

#### Frontend Functionality

**Required behaviors:**

- Send `getProjectNotes` request and track loading state
- Receive `projectNotes` message, store server value, initialize local editor if open
- Track local edits in state (separate from server value)
- Send `setProjectNotes` request with local content, track saving state
- Receive `projectNotesSet` confirmation, sync local/server state, clear saving
- Discard local changes (reset editor to server value or close)
- Handle and display errors

#### UI Components

- [ ] Trigger button/icon in toolbar or menu
- [ ] Modal or panel container with open/close handling
- [ ] Textarea with controlled state binding
- [ ] Loading indicator during fetch
- [ ] Saving indicator during save (disable inputs)
- [ ] Dirty state indicator
- [ ] Confirmation prompt when closing with unsaved changes
- [ ] Error display

#### WebSocket Integration

- [ ] Handle outgoing `getProjectNotes` request
- [ ] Handle outgoing `setProjectNotes` request
- [ ] Handle incoming `projectNotes` message
- [ ] Handle incoming `projectNotesSet` message

---

### Gotchas & Edge Cases

#### Newline Normalization

REAPER may store `\r\n` (Windows) or `\r` (old Mac). Normalize to `\n` on receive for consistent textarea behavior:

```typescript
// On receive
const normalized = notes.replace(/\r\n?/g, '\n');
```

REAPER is tolerant of mixed newlines, so conversion on save is optional.

#### Empty vs Null

| State | Meaning | UI |
|-------|---------|-----|
| `serverNotes === null` | Never fetched | Show loading or fetch prompt |
| `serverNotes === ""` | Fetched, project has no notes | Show empty textarea |
| `localNotes === null` | Editor not open | N/A |
| `localNotes === ""` | User cleared all content | Empty textarea, dirty if server had content |

#### Large Notes

If someone pastes a very large amount of text:

- **Frontend:** Consider warning if content exceeds ~100KB before save
- **Extension:** Cap at 1MB, return error if exceeded
- **WebSocket:** Large messages may need consideration depending on server config

#### Concurrent Edits

If notes are open in WebUI and someone edits directly in REAPER:

**Simple approach (acceptable for single-user DAW):** Last-write-wins.

**Better UX:** Track the server value when editor was opened. On save, compare current server value — if changed, warn user:

> "Notes were modified elsewhere. Overwrite?"

Options: Overwrite / Discard my changes / Cancel

---

### Future Enhancements

- **Markdown preview:** Toggle between edit mode and rendered view
- **Auto-save draft:** LocalStorage backup of unsaved changes (survives browser refresh)
- **Timestamps:** Display "Last modified: 2 hours ago" if REAPER exposes this (it doesn't natively, but could track in extension)
- **Search:** Ctrl+F / Cmd+F within notes (browser native may suffice for textarea)
- **Character/word count:** Footer showing content length
