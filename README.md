# Reamo

A modern web control surface for [REAPER](https://www.reaper.fm/), designed for songwriting workflows. Control transport, tracks, and more from your iPad or tablet while staying at your instrument.

## Quick Start (Non-Technical Users)

**Just want the control surface? No coding required.**

1. **Download** `reamo.html` from the [Releases page](../../releases)
2. **Copy** it to your REAPER web folder:
   - **macOS**: `~/Library/Application Support/REAPER/reaper_www_root/`
   - **Windows**: `%APPDATA%\REAPER\reaper_www_root\`
   - **Linux**: `~/.config/REAPER/reaper_www_root/`
3. **Enable REAPER's web server** (see setup below)
4. **Open** `http://YOUR-COMPUTER-IP:8888/reamo.html` on your tablet

That's it! Refresh the page whenever REAPER is running.

### REAPER Web Server Setup

1. Open **REAPER**
2. Go to **Options** > **Preferences** (or press `Cmd+,` / `Ctrl+,`)
3. Navigate to **Control/OSC/Web** in the left sidebar
4. Click **Add** and select **Web browser interface**
5. Configure:
   - **Port**: 8888 (default, or choose another)
   - **Access**: Set to your local network (e.g., `192.168.*.*`) or `*` for any
   - **Default web page**: Leave blank or set to `reamo.html`
6. Click **OK** to save
7. Find your computer's IP address (System Preferences > Network on macOS, or `ipconfig` on Windows)
8. On your tablet, open: `http://YOUR-IP:8888/reamo.html`

---

## Features

- **Transport Control** - Play, pause, stop, record with visual feedback
- **Track Management** - Volume faders, pan knobs, mute/solo/arm, real-time level metering
- **Timeline Visualization** - Interactive timeline with regions, markers, playhead, and time selection
- **Region Editing** - Drag, resize, and reorder regions directly on the timeline with ripple editing and full undo/redo support
- **Marker Management** - Navigate, add, move, delete, and reorder markers
- **Tempo Control** - Display BPM, tap tempo, set exact tempo
- **Auto-Punch Mode** - Time selection recording with visual indicators
- **Take Switching** - A/B compare takes without leaving your instrument
- **Touch-Optimized** - Gesture support for mobile/tablet control surfaces

## Why Reamo?

This project was built to solve a specific songwriting problem: **staying at the instrument**.

The typical home recording workflow kills creativity. You sit at the piano, get an idea, walk to the computer, set up a track, adjust levels, hit record, walk back, try to remember what you were playing... by then the moment's gone. Worse, you end up polishing 16 bars forever while the song goes nowhere.

**The Reamo workflow:**

1. **Pre-structure or start blank** - Set up a REAPER project with regions (intro, verse, chorus, bridge, outro) or start completely fresh
2. **Stay at your instrument** - Mount an iPad near your piano/guitar running Reamo
3. **Tap in the tempo** - No need to touch the computer, dial in or tap the BPM from your playing position
4. **Capture ideas in boxes** - Each region is a container for an idea. Record a rough verse, move to the chorus, try a bridge. Use auto-punch to nail specific sections
5. **Compare takes on the fly** - Not sure if that last take was better? Long-press the track, switch between takes to A/B compare without touching the computer
6. **End with a scaffold** - Instead of 16 over-produced bars, you have rough ideas across the whole song structure recorded to a click

The goal is **idea capture, not production**. Get the song down while you're in creative mode. The engineering can wait.

---

## For Developers

### Tech Stack

- **React 19** + **TypeScript 5.9**
- **Vite 7** with single-file output for REAPER compatibility
- **Zustand** for state management
- **Tailwind CSS 4** for styling
- **Lucide React** for icons

### Development

```bash
# Install dependencies
npm install

# Development server (hot reload)
npm run dev

# Production build (outputs single HTML file)
npm run build

# Build and deploy to REAPER www folder
npm run deploy
```

The production build creates a single `dist/index.html` file with all assets inlined, making it compatible with REAPER's built-in HTTP server.

### Architecture Overview

```txt
User Interaction -> UI Component -> useReaper().send(command)
                                         |
                            ReaperConnection queues command
                                         |
                            HTTP GET /_/[commands]
                                         |
                            REAPER HTTP Server
                                         |
                            Tab-delimited response
                                         |
                            ResponseParser -> ParsedResponse[]
                                         |
                            Zustand store update
                                         |
                            Components re-render
```

### Project Structure

```txt
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
│       ├── regionsSlice.ts      # Region list
│       └── regionEditSlice.ts   # Region editing state with undo/redo
│
├── components/                  # React UI components
│   ├── ReaperProvider.tsx       # Connection context provider
│   ├── ConnectionStatus.tsx     # Connection indicator
│   ├── TakeSwitcher.tsx         # Take switching controls
│   ├── Transport/               # TransportBar, TimeDisplay, buttons
│   ├── Track/                   # TrackStrip, Fader, PanKnob, LevelMeter
│   ├── Regions/                 # RegionNavigation, RegionDisplay
│   ├── Timeline/                # Timeline with editing, modals, drag hooks
│   ├── Markers/                 # MarkerNavigation
│   └── Actions/                 # ActionButton, TapTempoButton, etc.
│
├── hooks/                       # Custom React hooks
│   ├── useReaperConnection.ts   # Connection lifecycle management
│   ├── useTransport.ts          # Transport state & commands
│   ├── useTracks.ts             # All tracks access
│   ├── useTrack.ts              # Single track state & controls
│   ├── useTimeSelectionSync.ts  # Time selection sync with REAPER
│   ├── useDoubleTap.ts          # Double-tap gesture detection
│   └── useLongPress.ts          # Long-press gesture detection
│
├── utils/                       # Utility functions
│   ├── volume.ts                # dB/linear/fader conversions
│   ├── pan.ts                   # Pan value formatting
│   ├── color.ts                 # REAPER color conversion
│   └── time.ts                  # Time/beat formatting utilities
│
├── App.tsx                      # Main app component
├── main.tsx                     # React entry point
└── index.ts                     # Library exports
```

---

## API Reference

### Core Layer

#### ReaperConnection

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

#### CommandBuilder

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
```

### Hooks

#### useTransport

```typescript
const {
  playState, isPlaying, isPaused, isStopped, isRecording,
  positionSeconds, positionString, positionBeats,
  isRepeat, bpm, timeSignature,
  play, pause, stop, record, toggleRepeat, seekTo, prevMarker, nextMarker
} = useTransport();
```

#### useTrack

```typescript
const {
  track, exists, name, volumeDb, faderPosition,
  pan, panDisplay, isMuted, isSoloed, isRecordArmed,
  isSelected, color, textColor,
  toggleMute, toggleSolo, toggleRecordArm, setVolume, setPan
} = useTrack(trackIndex);
```

#### useTracks

```typescript
const {
  trackCount, tracks, getTrack, masterTrack, userTracks, selectedTracks
} = useTracks();
```

### Components

```tsx
// Wrap your app
<ReaperProvider autoStart={true}>
  <App />
</ReaperProvider>

// Transport
<TransportBar />
<TimeDisplay format="time" />
<PlayButton /> <StopButton /> <RecordButton />

// Tracks
<TrackStrip trackIndex={1} />
<Fader trackIndex={1} />
<PanKnob trackIndex={1} />
<LevelMeter trackIndex={1} />

// Timeline (supports view and edit modes)
<Timeline height={120} />
<RegionEditActionBar />  // Undo/redo, pending changes indicator

// Regions
<RegionNavigation />
<RegionDisplay />

// Actions
<TapTempoButton />
<MetronomeButton />
<TakeSwitcher />
```

---

## REAPER HTTP API Reference

### Endpoint Format

```txt
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

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT
