# Reactper

A modern React + TypeScript web interface for controlling [REAPER](https://www.reaper.fm/) digital audio workstation. Provides real-time transport controls, track management, timeline visualization, and marker/region navigation via HTTP polling.

## Features

- **Transport Control** - Play, pause, stop, record with visual feedback
- **Track Management** - Volume faders, pan knobs, mute/solo/arm, real-time level metering
- **Timeline Visualization** - Interactive timeline with regions, markers, playhead, and time selection
- **Marker Management** - Navigate, add, move, delete, and reorder markers
- **Tempo Control** - Display BPM, tap tempo, set exact tempo
- **Auto-Punch Mode** - Time selection recording with visual indicators
- **Touch-Optimized** - Gesture support for mobile/tablet control surfaces

## Tech Stack

- **React 19** + **TypeScript 5.9**
- **Vite 7** with single-file output for REAPER compatibility
- **Zustand** for state management
- **Tailwind CSS 4** for styling
- **Lucide React** for icons

## Quick Start

```bash
# Install dependencies
npm install

# Development server
npm run dev

# Production build (outputs single HTML file)
npm run build
```

The production build creates a single `dist/index.html` file that can be served by REAPER's built-in HTTP server.

## Architecture Overview

```
User Interaction → UI Component → useReaper().send(command)
                                         ↓
                            ReaperConnection queues command
                                         ↓
                            HTTP GET /_/[commands]
                                         ↓
                            REAPER HTTP Server
                                         ↓
                            Tab-delimited response
                                         ↓
                            ResponseParser → ParsedResponse[]
                                         ↓
                            Zustand store update
                                         ↓
                            Components re-render
```

## Project Structure

```
src/
├── core/                        # REAPER communication layer
│   ├── ReaperConnection.ts      # HTTP polling client with backoff
│   ├── CommandBuilder.ts        # Type-safe REAPER command construction
│   ├── ResponseParser.ts        # Tab-delimited response parsing
│   └── types.ts                 # Protocol types & constants
│
├── store/                       # Zustand state management
│   ├── index.ts                 # Combined store with response handler
│   └── slices/
│       ├── connectionSlice.ts   # Connection status & errors
│       ├── transportSlice.ts    # Playback, position, time selection
│       ├── tracksSlice.ts       # Track state by index
│       ├── markersSlice.ts      # Marker list
│       └── regionsSlice.ts      # Region list
│
├── components/                  # React UI components
│   ├── ReaperProvider.tsx       # Connection context provider
│   ├── ConnectionStatus.tsx     # Connection indicator
│   ├── Transport/               # TransportBar, TimeDisplay, buttons
│   ├── Track/                   # TrackStrip, Fader, PanKnob, LevelMeter
│   ├── Timeline/                # Timeline with regions/markers/playhead
│   ├── Markers/                 # MarkerNav, MarkerEditModal
│   └── Actions/                 # ActionButton, TapTempoButton, etc.
│
├── hooks/                       # Custom React hooks
│   ├── useReaperConnection.ts   # Connection lifecycle management
│   ├── useTransport.ts          # Transport state & commands
│   ├── useTracks.ts             # All tracks access
│   ├── useTrack.ts              # Single track state & controls
│   ├── useTimeSelectionSync.ts  # Time selection detection
│   └── useDoubleTap.ts          # Double-tap gesture detection
│
├── utils/                       # Utility functions
│   ├── volume.ts                # dB/linear/fader conversions
│   ├── pan.ts                   # Pan value formatting
│   └── color.ts                 # REAPER color conversion
│
├── App.tsx                      # Main app component
├── main.tsx                     # React entry point
└── index.ts                     # Library exports
```

---

## Core Layer

### ReaperConnection

HTTP polling client that communicates with REAPER's built-in web server.

```typescript
import { ReaperConnection } from './core/ReaperConnection';

const connection = new ReaperConnection({
  baseUrl: '',  // Same origin as REAPER server
  onResponse: (responses) => { /* handle parsed responses */ },
  onConnectionChange: (connected, errorCount) => { /* update UI */ }
});

// One-time command (queued for next poll cycle)
connection.send('SET/POS/10.5');

// Recurring poll (sent every interval)
connection.poll('TRANSPORT;BEATPOS', 30);  // Every 30ms

connection.start();
```

**Features:**

- Combines pending + recurring commands into single requests
- Exponential backoff on errors (100ms → 3200ms)
- Automatic reconnection
- Timeout handling (default 3000ms)

### CommandBuilder

Type-safe functions for constructing REAPER HTTP commands.

```typescript
import * as commands from './core/CommandBuilder';

// GET commands
commands.transport()              // 'TRANSPORT'
commands.track(0)                 // 'TRACK/0'
commands.markers()                // 'MARKER_LIST'

// SET commands
commands.setVolume(1, 0.5)        // 'SET/TRACK/1/VOL/0.5'
commands.setPan(1, -0.5)          // 'SET/TRACK/1/PAN/-0.5'
commands.setPosition(10.5)        // 'SET/POS/10.5'
commands.setTempo(120)            // 'SET/TEMPO/120'

// Action commands (REAPER action IDs)
commands.play()                   // '1007'
commands.stop()                   // '40667'
commands.record()                 // '1013'
commands.toggleMetronome()        // '40364'
commands.nextMarker()             // '40173'

// Combine multiple commands
commands.join(
  commands.setVolume(1, 0.5),
  commands.track(1),
  commands.transport()
)  // 'SET/TRACK/1/VOL/0.5;TRACK/1;TRANSPORT'
```

### ResponseParser

Parses REAPER's tab-delimited responses into typed objects.

```typescript
import { parseResponse, ParsedResponse } from './core/ResponseParser';

const responses: ParsedResponse[] = parseResponse(rawText);

responses.forEach(response => {
  switch (response.type) {
    case 'TRANSPORT':
      console.log(response.data.playState, response.data.positionSeconds);
      break;
    case 'TRACK':
      console.log(response.data.name, response.data.volume);
      break;
    case 'MARKER':
      console.log(response.data.name, response.data.position);
      break;
  }
});
```

**Supported response types:**

- `TRANSPORT` - Playback state, position, repeat
- `BEATPOS` - Beat position, BPM, time signature
- `NTRACK` - Track count
- `TRACK` - Full track state (volume, pan, flags, meters)
- `MARKER` / `MARKER_LIST` - Marker data
- `REGION` / `REGION_LIST` - Region data
- `CMDSTATE` - Toggle states (metronome, etc.)
- `GET/REPEAT`, `GET/TEMPO` - Settings queries

---

## State Management

Zustand store with slices for different data domains.

### Store Structure

```typescript
interface ReaperStore {
  // Connection
  connected: boolean;
  errorCount: number;
  lastError: string | null;

  // Transport
  playState: PlayState;           // 0=stopped, 1=playing, 2=paused, 5=recording
  positionSeconds: number;
  positionString: string;          // "0:10.500"
  positionBeats: string;           // "1.1.00"
  isRepeat: boolean;
  isMetronome: boolean;
  isAutoPunch: boolean;
  bpm: number | null;
  timeSignature: string;           // "4/4"
  timeSelection: { startBeats: number; endBeats: number } | null;

  // Tracks
  trackCount: number;
  tracks: Record<number, Track>;   // { 0: Master, 1: Track1, ... }

  // Markers & Regions
  markers: Marker[];
  regions: Region[];
}
```

### Using the Store

```typescript
import { useReaperStore } from './store';

// Select specific state
const playState = useReaperStore(state => state.playState);
const tracks = useReaperStore(state => state.tracks);

// Or use provided hooks (recommended)
const { isPlaying, positionString } = useTransport();
const { track, volumeDb, toggleMute } = useTrack(1);
```

---

## Hooks

### useReaper

Access the connection context.

```typescript
function MyComponent() {
  const { connected, send, connection } = useReaper();

  const handlePlay = () => {
    send(commands.play());
  };
}
```

### useTransport

Transport state and command builders.

```typescript
function TransportControls() {
  const { send } = useReaper();
  const {
    playState,
    isPlaying,
    isPaused,
    isStopped,
    isRecording,
    positionSeconds,
    positionString,      // "0:10.500"
    positionBeats,       // "1.1.00"
    isRepeat,
    bpm,
    timeSignature,

    // Command builders (return strings)
    play,
    pause,
    stop,
    record,
    toggleRepeat,
    seekTo,              // seekTo(seconds)
    prevMarker,
    nextMarker
  } = useTransport();

  return (
    <button onClick={() => send(isPlaying ? pause() : play())}>
      {isPlaying ? 'Pause' : 'Play'}
    </button>
  );
}
```

### useTrack

Single track state and controls.

```typescript
function TrackControl({ index }: { index: number }) {
  const { send } = useReaper();
  const {
    track,               // Full track object
    exists,              // Track exists?
    name,
    volumeDb,            // "-6.0 dB"
    faderPosition,       // 0-1 (for fader UI)
    pan,                 // -1 to 1
    panDisplay,          // "50%L", "center", "50%R"
    isMuted,
    isSoloed,
    isRecordArmed,
    isSelected,
    hasFx,
    recordMonitorState,  // 0=off, 1=on, 2=auto
    color,               // CSS hex color or null
    textColor,           // Contrasting text color

    // Command builders
    toggleMute,
    toggleSolo,
    toggleRecordArm,
    cycleRecordMonitor,
    setVolume,           // setVolume(linearValue)
    setVolumeRelative,   // setVolumeRelative(dbChange)
    setFaderPosition,    // setFaderPosition(0-1)
    setPan               // setPan(-1 to 1)
  } = useTrack(index);

  return (
    <button onClick={() => send(toggleMute())}>
      {isMuted ? 'Unmute' : 'Mute'}
    </button>
  );
}
```

### useTracks

Access all tracks.

```typescript
function TrackList() {
  const {
    trackCount,
    tracks,        // Sorted array of all tracks
    getTrack,      // getTrack(index) => Track | undefined
    masterTrack,   // Track 0
    userTracks     // Tracks 1+
  } = useTracks();

  return (
    <div>
      {userTracks.map(track => (
        <TrackStrip key={track.index} trackIndex={track.index} />
      ))}
    </div>
  );
}
```

### useTimeSelectionSync

Detects REAPER's current time selection on mount.

```typescript
function App() {
  const { isSyncing } = useTimeSelectionSync();

  if (isSyncing) {
    return <div>Syncing time selection...</div>;
  }

  return <MainUI />;
}
```

---

## Components

### ReaperProvider

Wrap your app to establish the REAPER connection.

```tsx
<ReaperProvider
  baseUrl=""              // Default: same origin
  autoStart={true}        // Auto-connect on mount
  transportInterval={30}  // Transport poll rate (ms)
  trackInterval={200}     // Track poll rate (ms)
>
  <App />
</ReaperProvider>
```

### Transport Components

```tsx
// Full transport bar with all controls
<TransportBar />

// Time display
<TimeDisplay format="time" />      // "0:10.500"
<TimeDisplay format="beats" />     // "1.1.00"
<TimeDisplay format="both" />      // Both formats

// Individual buttons
<PlayButton />
<StopButton />
<RecordButton />
<MetronomeButton />
<RepeatButton />
```

### Track Components

```tsx
// Full track channel strip
<TrackStrip trackIndex={0} />  // Master
<TrackStrip trackIndex={1} />  // Track 1

// Individual controls
<Fader trackIndex={1} />
<PanKnob trackIndex={1} />
<LevelMeter trackIndex={1} />
<MuteButton trackIndex={1} />
<SoloButton trackIndex={1} />
<RecordArmButton trackIndex={1} />
<MonitorButton trackIndex={1} />
```

### Timeline

Interactive timeline with regions, markers, and playhead.

```tsx
<Timeline
  height={120}           // Height in pixels
  showRegions={true}     // Show region blocks
  showMarkers={true}     // Show marker pills
  showPlayhead={true}    // Show draggable playhead
  showSelection={true}   // Show time selection highlight
/>
```

**Interactions:**

- **Tap** - Navigate to position or nearest marker
- **Hold** - Create time selection
- **Drag playhead** - Seek (vertical drag out cancels)
- **Hold marker** - Open edit modal (markers 1-10 can be moved)

### Action Buttons

```tsx
// Generic action button
<ActionButton
  action={40029}           // REAPER action ID
  variant="primary"        // default | primary | danger | ghost
  size="md"               // sm | md | lg
>
  Undo
</ActionButton>

// Pre-configured buttons
<UndoButton />
<RedoButton />
<SaveButton />
<AddMarkerButton />
<PrevMarkerButton />
<NextMarkerButton />
<TapTempoButton />        // Shows BPM, tap for tempo, hold for exact input
```

---

## Utilities

### Volume Conversion

REAPER uses linear scale: 0 = -∞ dB, 1 = 0 dB (unity), 4 = +12 dB

```typescript
import { volumeToDb, dbToVolume, faderToVolume, volumeToFader } from './utils/volume';

// Linear <-> dB
volumeToDb(1)           // 0
volumeToDb(0.5)         // -6.02
dbToVolume(-6)          // ~0.5

// Fader position (0-1) uses power curve for natural feel
faderToVolume(0.5)      // Uses position^4 * 4
volumeToFader(1)        // Returns fader position for unity
```

### Pan Formatting

```typescript
import { panToString, isCentered } from './utils/pan';

panToString(-0.5)       // "50%L"
panToString(0)          // "center"
panToString(0.5)        // "50%R"
isCentered(0.01)        // true (within threshold)
```

### Color Conversion

REAPER uses 0xaarrggbb format.

```typescript
import { reaperColorToHex, getContrastColor } from './utils/color';

reaperColorToHex(0xff0000ff)  // "#0000ff" (blue)
getContrastColor(0xff000000)  // "white" (for dark background)
```

---

## Key Types

### Track

```typescript
interface Track {
  index: number;
  name: string;
  flags: number;          // Bitfield (see TrackFlags)
  volume: number;         // Linear: 0-4
  pan: number;            // -1 to 1
  lastMeterPeak: number;  // dB * 10
  lastMeterPos: number;   // dB * 10
  width: number;          // Stereo width
  panMode: number;
  sendCount: number;
  receiveCount: number;
  hwOutCount: number;
  color: number;          // 0xaarrggbb, 0 = default
}

// Track flag constants
const TrackFlags = {
  FOLDER: 1,
  SELECTED: 2,
  HAS_FX: 4,
  MUTED: 8,
  SOLOED: 16,
  SOLO_IN_PLACE: 32,
  RECORD_ARMED: 64,
  RECORD_MONITOR_ON: 128,
  RECORD_MONITOR_AUTO: 256,
  TCP_HIDDEN: 512,
  MCP_HIDDEN: 1024
};

// Check flags with bitwise AND
if (track.flags & TrackFlags.MUTED) { /* muted */ }
```

### Marker & Region

```typescript
interface Marker {
  id: number;
  name: string;
  position: number;  // Seconds
  color?: number;    // 0xaarrggbb
}

interface Region {
  id: number;
  name: string;
  start: number;     // Seconds
  end: number;       // Seconds
  color?: number;    // 0xaarrggbb
}
```

### Transport State

```typescript
type PlayState = 0 | 1 | 2 | 5 | 6;
// 0 = stopped
// 1 = playing
// 2 = paused
// 5 = recording
// 6 = record paused

interface TransportState {
  playState: PlayState;
  positionSeconds: number;
  isRepeat: boolean;
  positionString: string;   // "MM:SS.ms"
  positionBeats: string;    // "Bar.Beat.Ticks"
}
```

---

## REAPER HTTP API Reference

### Endpoint Format

```
GET /_/[command1];[command2];[command3]
```

### Common Commands

| Command | Description |
|---------|-------------|
| `TRANSPORT` | Get playback state, position |
| `BEATPOS` | Get beat position, BPM, time signature |
| `NTRACK` | Get track count |
| `TRACK/n` | Get track n state (0 = master) |
| `MARKER_LIST` | Get all markers |
| `REGION_LIST` | Get all regions |
| `SET/POS/n` | Seek to n seconds |
| `SET/TRACK/n/VOL/v` | Set track volume (linear) |
| `SET/TRACK/n/PAN/p` | Set track pan (-1 to 1) |
| `SET/TEMPO/bpm` | Set tempo |
| `[action_id]` | Trigger REAPER action |

### Common Action IDs

| ID | Action |
|----|--------|
| 1007 | Play |
| 1008 | Pause |
| 1013 | Record |
| 40667 | Stop |
| 40364 | Toggle Metronome |
| 1068 | Toggle Repeat |
| 40076 | Toggle Auto-Punch |
| 40172 | Previous Marker |
| 40173 | Next Marker |
| 40029 | Undo |
| 40030 | Redo |
| 40026 | Save Project |

---

## Example: Custom Control Surface

```tsx
import {
  ReaperProvider,
  TransportBar,
  TimeDisplay,
  TrackStrip,
  Timeline,
  TapTempoButton,
  useTracks
} from './index';

function ControlSurface() {
  const { masterTrack, userTracks } = useTracks();

  return (
    <ReaperProvider autoStart={true}>
      <div className="min-h-screen bg-gray-950 text-white p-4">
        {/* Header */}
        <div className="flex items-center justify-between mb-4">
          <TimeDisplay format="both" />
          <TapTempoButton />
        </div>

        {/* Transport */}
        <TransportBar />

        {/* Timeline */}
        <Timeline height={100} />

        {/* Mixer */}
        <div className="flex gap-2 overflow-x-auto mt-4">
          {masterTrack && <TrackStrip trackIndex={0} />}
          {userTracks.map(track => (
            <TrackStrip key={track.index} trackIndex={track.index} />
          ))}
        </div>
      </div>
    </ReaperProvider>
  );
}
```

---

## Configuration

### Vite

The build uses `vite-plugin-singlefile` to output a single HTML file with all assets inlined, making it compatible with REAPER's HTTP server.

### TypeScript

Path alias `@/*` maps to `src/*`:

```typescript
import { useTrack } from '@/hooks/useTrack';
```

### Tailwind

Dark-themed design system using gray-950/900/800 palette. Customize in `tailwind.config.js`.

---

## Development

```bash
# Start dev server
npm run dev

# Type check
npm run typecheck

# Lint
npm run lint

# Build for production
npm run build

# Preview production build
npm run preview
```

---

## Changelog

### Latest

- **Time Selection Sync** - Auto-detect REAPER's current time selection on startup via cursor position probing
- **Marker Edit Modal** - Long-press markers to open edit dialog with move, delete, and reorder options
- **Record Mode Indicator** - Red border on record button distinguishes normal vs auto-punch mode

### Timeline & Navigation

- **Interactive Timeline** - Visual representation of project with regions, markers, and playhead
- **Draggable Playhead** - Grab handle for seeking with preview line and cancel-by-drag-out gesture
- **Region Labels** - Top bar displays region names with color-coded bars
- **Marker Pills** - Bottom bar shows numbered markers aligned with timeline positions
- **Time Selection** - Hold on timeline to create selection, stored in beats (survives tempo changes)
- **Selection Indicator** - Yellow highlight bar showing current time selection
- **Marker Navigation** - Previous/next marker buttons for quick navigation
- **Clear Selection** - Button to clear time selection and loop points

### Transport Controls

- **TransportBar** - Unified icon-only transport with play, pause, stop, record, loop
- **Long-Press Record** - Hold to toggle between normal and auto-punch (time selection) mode
- **Auto-Punch Polling** - UI syncs with REAPER's auto-punch state

### Tempo & Metronome

- **Tap Tempo Button** - Shows current BPM, tap to sync tempo
- **Manual BPM Input** - Long-press tap tempo to open dialog for exact BPM (2-960)
- **Metronome Toggle** - Button with active state indicator
- **Metronome Volume** - Long-press metronome for volume adjustment dialog
- **Tempo-Aware Selection** - Time selection stored in beats, converts to seconds for display

### Track Controls

- **Track Strip** - Full channel strip with fader, pan, mute, solo, arm, monitor
- **Level Metering** - Real-time peak and RMS meters with clip indicators
- **Fader** - Vertical volume control with power curve, double-tap to reset
- **Pan Knob** - Horizontal pan control, double-tap to center
- **Monitor Button** - Cycles through Off/On/Auto states
- **Track Filter** - Search tracks by name
- **Track Colors** - Custom track colors with contrast-aware text

### Region & Marker Management

- **Region Display** - Visual blocks with semi-transparent backgrounds
- **Region Navigation** - Jump to regions by boundary detection
- **Marker Management** - Add, move (1-10), delete, reorder markers
- **Color Support** - Full REAPER color format support (0xaarrggbb)

### Core Infrastructure

- **HTTP Polling** - Efficient polling with command batching
- **Exponential Backoff** - Auto-reconnect with increasing delays on error
- **Zustand Store** - Centralized state with typed slices
- **Response Parser** - Robust tab-delimited response parsing
- **Command Builder** - Type-safe REAPER command construction

### Initial Release

- Basic transport controls (play, pause, stop, record)
- Track volume and pan control
- Mute, solo, record arm toggles
- Connection status indicator
- Single-file Vite build for REAPER compatibility

## License

MIT
